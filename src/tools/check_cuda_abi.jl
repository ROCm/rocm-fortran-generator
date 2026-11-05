#!/usr/bin/env julia
###############################################################################
# Copyright (C) 2026 Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#
###############################################################################

# rocm-fortran/tools/check_cuda_abi.jl
# Check that what the USE_CUDA_NAMES bindings pass to CUDA is what CUDA expects.
# This compares the hip and cu prototypes and the struct layouts, so a cu*
# namesake with other arguments, or a struct CUDA lays out differently, does not
# go unnoticed.
#
# For every `#ifdef USE_CUDA_NAMES` bind pair of the generated layout:
#   - prototypes, from the HIP and CUDA headers through Clang: argument count and,
#     for each argument and the result, its ABI class (integer/float and size,
#     pointer, struct); for a pointer, the pointee as well (an int* where hip has a
#     size_t* is a short write). A pointer and an 8-byte integer by value pass the
#     same way, and an opaque or void pointee matches any pointer.
#   - layouts: each struct met on both sides of a pair (by value, as pointee, and
#     through their fields) is compared as hipfort declares it under
#     USE_CUDA_NAMES (hipfort_types compiled with gfortran, so the <Type>.cuda.finc
#     overrides count) against the CUDA struct: size and member offsets.
# Differences listed in ACCEPTED are reported but do not fail the check.
#
# Opt-in like gen_cuda_enums.jl: it needs a CUDA toolkit's headers and gfortran.
#
# Usage (from the rocm-fortran repo root, after a regeneration):
#   julia --project=src src/tools/check_cuda_abi.jl <hipfort/lib/hipfort> \
#         [--cuda /usr/local/cuda/include] [--rocm /opt/rocm/include]

using Clang
const LC = Clang.LibClang

const HIP_HEADERS = ["hip/hip_runtime_api.h", "hipblas/hipblas.h", "hipsolver/hipsolver.h",
                     "hipsparse/hipsparse.h", "hipfft/hipfftXt.h", "hiprand/hiprand.h"]
const CUDA_HEADERS = ["cuda.h", "cuda_runtime_api.h", "cuda_profiler_api.h", "cublas_api.h",
                      "cusolverDn.h", "cusolverSp.h", "cusolverRf.h", "cusparse.h", "cufft.h",
                      "cufftXt.h", "curand.h"]

# Known differences that are harmless, each with the reason. Keys are the hip
# routine (prototype findings) or the Fortran type (layout findings).
const ACCEPTED = Dict{String,String}(
  "hipStreamWaitValue32" => "trailing mask; CUDA ignores it, as HIP's own NVIDIA backend does",
  "hipStreamWaitValue64" => "trailing mask; CUDA ignores it, as HIP's own NVIDIA backend does",
  "hipsparseSpSM_solve" => "trailing externalBuffer; cuSPARSE does not take it",
  "hipLaunchCooperativeKernel" => "sharedMemBytes: unsigned int to size_t, zero-extended in the register",
  "hipLaunchCooperativeKernel_spt" => "sharedMemBytes: unsigned int to size_t, zero-extended in the register",
  "hipMemPoolProps" => "reserved(56) covers CUDA's usage + reserved(54): same bytes once zeroed",
)

# Type-level differences that are harmless wherever they appear.
const ACCEPTED_TYPES = Dict{String,String}(
  "hipfftHandle" => "8 bytes, cufftHandle an int: cuFFT fills and reads the low half",
)
# A 16-bit float struct (__half, __nv_bfloat16) and hipBLAS's 16-bit integer stand-in.
half_pair(a, b) = Set([a, b]) == Set([(:record, 2), (:int, 2)])
accepted_type(t) = any(k -> occursin(Regex("\\b$(k)\\b"), Clang.spelling(t)), keys(ACCEPTED_TYPES))

# ---- prototypes --------------------------------------------------------------

function parse_tu(headers, inc, defs)
  hdr = joinpath(mktempdir(), "tu.cpp")
  write(hdr, join(("#include <$(h)>" for h in headers), "\n") * "\n")
  # The host toolchain's headers, not Clang.jl's default sysroot (an old glibc
  # that clashes with /usr/include, and no libstdc++ for hipfftXt.h).
  jll = Clang.LibClang.Clang_unified_jll.artifact_dir
  res = joinpath(jll, "lib", "clang", only(readdir(joinpath(jll, "lib", "clang"))))
  args = vcat(["-x", "c++", "-ferror-limit=0", "-resource-dir", res, "-I$(inc)"], defs)
  tu = Clang.parse_header(Clang.Index(), hdr, args, Clang.CXTranslationUnit_None)
  nerr = count(d -> LC.clang_getDiagnosticSeverity(d) >= LC.CXDiagnostic_Error,
               (LC.clang_getDiagnostic(tu.ptr, i) for i in 0:LC.clang_getNumDiagnostics(tu.ptr)-1))
  nerr == 0 || error("$(nerr) error(s) parsing $(headers) under $(inc)")
  return tu
end

function functions(tu)
  fs = Dict{String,Any}()
  walk(c) = for ch in Clang.children(c)
    k = Clang.kind(ch)
    if k == Clang.CXCursor_FunctionDecl
      get!(fs, Clang.spelling(ch), ch)
    elseif k in (Clang.CXCursor_LinkageSpec, Clang.CXCursor_Namespace)
      walk(ch)
    end
  end
  walk(Clang.getTranslationUnitCursor(tu))
  return fs
end

canon(t) = Clang.getCanonicalType(t)
sizeof_t(t) = LC.clang_Type_getSizeOf(t.type)

const FLOATS = (Clang.CXType_Float, Clang.CXType_Double, Clang.CXType_LongDouble,
                Clang.CXType_Half, Clang.CXType_Float16, Clang.CXType_BFloat16)

# ABI class of a canonical type: (:int|:float|:ptr|:fnptr|:void|:record|:opaque, size)
function abi(t)
  t = canon(t); k = Clang.kind(t)
  k == Clang.CXType_Void && return (:void, 0)
  k in (Clang.CXType_Pointer, Clang.CXType_LValueReference) &&
    return Clang.kind(canon(Clang.getPointeeType(t))) == Clang.CXType_FunctionProto ? (:fnptr, 8) : (:ptr, 8)
  k in ARRAYS && return (:ptr, 8)     # a parameter declared T[] is a T*
  k == Clang.CXType_Record && return sizeof_t(t) < 0 ? (:opaque, 0) : (:record, sizeof_t(t))
  k == Clang.CXType_Enum && return (:int, 4)
  k in FLOATS && return (:float, sizeof_t(t))
  return (:int, sizeof_t(t))
end
const ARRAYS = (Clang.CXType_IncompleteArray, Clang.CXType_ConstantArray, Clang.CXType_VariableArray)
pointee(t) = (c = canon(t); Clang.kind(c) in ARRAYS ? Clang.getElementType(c) : Clang.getPointeeType(c))
recname(t) = Clang.spelling(Clang.getTypeDeclaration(canon(t)))

# Same register/stack slot: identical class, or pointer vs 8-byte integer.
same_slot(a, b) = a == b || (Set([a[1], b[1]]) == Set([:ptr, :int]) && a[2] == b[2] == 8) ||
                  (a[1] in (:ptr, :fnptr) && b[1] in (:ptr, :fnptr))

function cmp_arg!(issues, structs, where, h, c)
  ah, ac = abi(h), abi(c)
  if ah[1] == :record && ac[1] == :record
    push!(structs, (h, c, where)); ah[2] == ac[2] || push!(issues, "$(where): struct by value, $(ah[2]) vs $(ac[2]) bytes")
    return
  end
  if !same_slot(ah, ac)
    accepted_type(h) && return
    push!(issues, "$(where): $(Clang.spelling(h)) [$(ah[1])$(8ah[2])] vs $(Clang.spelling(c)) [$(ac[1])$(8ac[2])]")
    return
  end
  (ah[1] == :ptr && ac[1] == :ptr) || return
  ph, pc = abi(pointee(h)), abi(pointee(c))
  any(p -> p[1] in (:void, :opaque, :fnptr), (ph, pc)) && return
  if ph[1] == :record && pc[1] == :record
    push!(structs, (pointee(h), pointee(c), where)); return
  end
  ph == pc || (Set([ph[1], pc[1]]) == Set([:ptr, :int]) && ph[2] == pc[2]) || half_pair(ph, pc) ||
    accepted_type(Clang.getPointeeType(h)) ||
    push!(issues, "$(where): pointee $(Clang.spelling(pointee(h))) [$(ph[1])$(8ph[2])] vs $(Clang.spelling(pointee(c))) [$(pc[1])$(8pc[2])]")
end

# ---- layouts -----------------------------------------------------------------

# Top-level members of a C record: (name, byte offset, type).
function c_fields(t)
  decl = Clang.getTypeDeclaration(canon(t))
  out = Tuple{String,Int,Any}[]
  for ch in Clang.children(decl)
    k = Clang.kind(ch)
    if k == Clang.CXCursor_FieldDecl
      push!(out, (Clang.spelling(ch), LC.clang_Cursor_getOffsetOfField(ch.cursor) ÷ 8, Clang.getCursorType(ch)))
    elseif k in (Clang.CXCursor_StructDecl, Clang.CXCursor_UnionDecl) &&
           LC.clang_Cursor_isAnonymousRecordDecl(ch.cursor) != 0
      # an anonymous struct/union member has no FieldDecl: place it at its first field
      f = findfirst(x -> Clang.kind(x) == Clang.CXCursor_FieldDecl, Clang.children(ch))
      f === nothing && continue
      first = Clang.spelling(Clang.children(ch)[f])
      push!(out, ("", LC.clang_Type_getOffsetOf(canon(t).type, first) ÷ 8, Clang.getCursorType(ch)))
    end
  end
  return out
end

# hipfort_types as compiled under USE_CUDA_NAMES: type => (size, [(member, offset)]).
function fortran_layouts(layout)
  src = joinpath(layout, "hipfort_types.F90")
  pre = read(`cpp -P -traditional-cpp -DUSE_CUDA_NAMES $(src)`, String)
  pre = join((split(l, '!'; limit=2)[1] for l in split(pre, '\n')), "\n")
  pre = replace(pre, r"&\s*\n\s*&?" => " ")
  types = Dict{String,Vector{String}}(); order = String[]; cur = nothing
  for ln in split(pre, '\n')
    s = strip(ln)
    m = match(r"^type\s*,\s*bind\(c\)\s*::\s*(\w+)"i, s)
    if m !== nothing; cur = String(m.captures[1]); types[cur] = String[]; push!(order, cur); continue; end
    if cur !== nothing && occursin(r"^end\s*type"i, s); cur = nothing; continue; end
    if cur !== nothing && occursin("::", s)
      rhs = replace(split(s, "::"; limit=2)[2], r"=.*$" => "")
      depth = 0; tok = IOBuffer()
      for ch in rhs * ","
        ch == '(' && (depth += 1); ch == ')' && (depth -= 1)
        if ch == ',' && depth == 0
          n = match(r"^\s*(\w+)", String(take!(tok))); n === nothing || push!(types[cur], n.captures[1])
        else
          write(tok, ch)
        end
      end
    end
  end
  dir = mktempdir()
  prog = ["program lay", "use iso_c_binding", "use hipfort_types", "implicit none", "integer(8) :: b"]
  for t in order; push!(prog, "type($(t)),target :: v_$(t)"); end
  for t in order
    push!(prog, "b=loc(v_$(t)); print '(A,1X,A,1X,I0)', 'T', '$(t)', c_sizeof(v_$(t))")
    for c in types[t]
      push!(prog, "print '(A,1X,A,1X,I0)', 'C', '$(c)', loc(v_$(t)%$(c))-b")
    end
  end
  push!(prog, "end program")
  write(joinpath(dir, "lay.F90"), join(prog, "\n") * "\n")
  run(`gfortran -cpp -DUSE_CUDA_NAMES -ffree-line-length-none -c $(src) -J $(dir) -o $(dir)/types.o`)
  run(`gfortran -ffree-line-length-none -I $(dir) $(dir)/lay.F90 $(dir)/types.o -o $(dir)/lay`)
  res = Dict{String,Tuple{Int,Vector{Tuple{String,Int}}}}(); cur = ""
  for ln in eachline(`$(dir)/lay`)
    f = split(ln)
    if f[1] == "T"; cur = String(f[2]); res[cur] = (parse(Int, f[3]), Tuple{String,Int}[])
    else push!(res[cur][2], (String(f[2]), parse(Int, f[3])))
    end
  end
  return res
end

fortran_name(hip_record) = replace(hip_record, "R0600" => "")

function check_layouts(structs, flay)
  issues = Dict{String,Vector{String}}(); seen = Set{Tuple{String,String}}()
  queue = Tuple{Any,Any,String}[(h, c, w) for (h, c, w) in structs]
  while !isempty(queue)
    h, c, where = popfirst!(queue)
    key = (recname(h), recname(c)); key in seen && continue; push!(seen, key)
    hf, cf = c_fields(h), c_fields(c)
    # follow members present on both sides by name: nested records and pointees
    cbyname = Dict(n => t for (n, _, t) in cf)
    for (n, _, t) in hf
      haskey(cbyname, n) || continue
      a, b = abi(t), abi(cbyname[n])
      a[1] == b[1] == :record && push!(queue, (t, cbyname[n], "$(key[1]).$(n)"))
      if a[1] == b[1] == :ptr && abi(pointee(t))[1] == abi(pointee(cbyname[n]))[1] == :record
        push!(queue, (pointee(t), pointee(cbyname[n]), "$(key[1]).$(n)"))
      end
    end
    fname = fortran_name(key[1])
    haskey(flay, fname) || continue          # no Fortran type: passed as type(c_ptr)
    fsize, fmem = flay[fname]
    csize = sizeof_t(canon(c))
    probs = String[]
    fsize == csize || push!(probs, "size $(fsize) vs $(csize)")
    coffs = [o for (_, o, _) in cf]; foffs = [o for (_, o) in fmem]
    foffs == coffs || push!(probs, "member offsets $(foffs) vs $(coffs)")
    cby = Dict(lowercase(n) => o for (n, o, _) in cf)
    for (n, o) in fmem
      co = get(cby, lowercase(n), o)
      co == o || push!(probs, "$(n) at $(o) vs $(co)")
    end
    isempty(probs) || (issues["$(fname) vs $(key[2]) (via $(where))"] = probs)
  end
  return issues
end

# ---- driver ------------------------------------------------------------------

function bind_pairs(layout)
  pairs = Dict{String,String}()
  for f in filter(x -> endswith(x, ".F90"), readdir(layout; join=true))
    ls = readlines(f); i = 1
    while i <= length(ls)
      if strip(ls[i]) == "#ifdef USE_CUDA_NAMES"
        cu = hp = nothing; j = i + 1
        while j <= length(ls) && strip(ls[j]) != "#else"
          m = match(r"bind\(c, *name=\"(\w+)\"\)", ls[j]); m === nothing || (cu = m.captures[1]); j += 1
        end
        k = j + 1
        while k <= length(ls) && strip(ls[k]) != "#endif"
          m = match(r"bind\(c, *name=\"(\w+)\"\)", ls[k]); m === nothing || (hp = m.captures[1]); k += 1
        end
        (cu === nothing || hp === nothing) || (pairs[hp] = cu)
        i = k
      end
      i += 1
    end
  end
  return pairs
end

# Differences each candidate (hip, cu) pair would bring, for vetting new map
# entries: hip => issues, empty when
# the pair is safe to bind. ACCEPTED entries count as safe.
function candidate_issues(cands, layout; cudainc = "/usr/local/cuda/include",
                          rocminc = "/opt/rocm/include")
  hiptu = parse_tu(HIP_HEADERS, rocminc, ["-D__HIP_PLATFORM_AMD__"])
  cutu  = parse_tu(CUDA_HEADERS, cudainc, ["-D__CUDA_API_VERSION_INTERNAL"])
  hip, cu = functions(hiptu), functions(cutu)
  flay = fortran_layouts(layout)
  out = Dict{String,Vector{String}}()
  for (h, c) in cands
    if !(haskey(hip, h) && haskey(cu, c)); out[h] = ["no prototype for $(h) or $(c)"]; continue; end
    hc, cc = hip[h], cu[c]
    issues = String[]; structs = Tuple{Any,Any,String}[]
    nh, nc = Clang.getNumArguments(hc), Clang.getNumArguments(cc)
    nh == nc || push!(issues, "$(nh) arguments vs $(nc)")
    for k in 0:min(nh, nc)-1
      cmp_arg!(issues, structs, "arg $(k+1)",
               Clang.getCursorType(Clang.getArgument(hc, k)), Clang.getCursorType(Clang.getArgument(cc, k)))
    end
    cmp_arg!(issues, structs, "result", Clang.getCursorResultType(hc), Clang.getCursorResultType(cc))
    for (k, _) in check_layouts(structs, flay)
      haskey(ACCEPTED, split(k)[1]) || push!(issues, "layout of $(k)")
    end
    out[h] = haskey(ACCEPTED, h) ? String[] : issues
  end
  GC.@preserve hiptu cutu nothing
  return out
end

function main()
  layout = ""; cudainc = "/usr/local/cuda/include"; rocminc = "/opt/rocm/include"
  i = 1
  while i <= length(ARGS)
    a = ARGS[i]
    if a == "--cuda";     cudainc = ARGS[i+1]; i += 2
    elseif a == "--rocm"; rocminc = ARGS[i+1]; i += 2
    else layout = a; i += 1
    end
  end
  isdir(layout) || error("usage: check_cuda_abi.jl <hipfort/lib/hipfort> [--cuda <include>] [--rocm <include>]")

  pairs = bind_pairs(layout)
  # The cursors point into the translation units: keep both alive until the end.
  hiptu = parse_tu(HIP_HEADERS, rocminc, ["-D__HIP_PLATFORM_AMD__"])
  # versioned prototypes (cuX_v2, ...) are only declared without the redirect macros
  cutu  = parse_tu(CUDA_HEADERS, cudainc, ["-D__CUDA_API_VERSION_INTERNAL"])
  hip, cu = functions(hiptu), functions(cutu)

  failed = 0; accepted = 0; missing = String[]
  structs = Tuple{Any,Any,String}[]
  for (h, c) in sort(collect(pairs))
    (haskey(hip, h) && haskey(cu, c)) || (push!(missing, "$(h) -> $(c)"); continue)
    hc, cc = hip[h], cu[c]
    issues = String[]
    nh, nc = Clang.getNumArguments(hc), Clang.getNumArguments(cc)
    nh == nc || push!(issues, "$(nh) arguments vs $(nc)")
    for k in 0:min(nh, nc)-1
      cmp_arg!(issues, structs, "$(h) arg $(k+1)",
               Clang.getCursorType(Clang.getArgument(hc, k)), Clang.getCursorType(Clang.getArgument(cc, k)))
    end
    cmp_arg!(issues, structs, "$(h) result", Clang.getCursorResultType(hc), Clang.getCursorResultType(cc))
    isempty(issues) && continue
    tag = haskey(ACCEPTED, h) ? (accepted += 1; "accepted") : (failed += 1; "MISMATCH")
    println("[$(tag)] $(h) -> $(c)")
    for s in issues; println("    ", s); end
    haskey(ACCEPTED, h) && println("    (", ACCEPTED[h], ")")
  end

  for (k, probs) in sort(collect(check_layouts(structs, fortran_layouts(layout))))
    fname = split(k)[1]
    tag = haskey(ACCEPTED, fname) ? (accepted += 1; "accepted") : (failed += 1; "LAYOUT")
    println("[$(tag)] $(k)")
    for p in probs; println("    ", p); end
    haskey(ACCEPTED, fname) && println("    (", ACCEPTED[fname], ")")
  end

  GC.@preserve hiptu cutu nothing
  isempty(missing) || println("\nno prototype for $(length(missing)) pair(s): ", join(missing, ", "))
  println("\n$(length(pairs)) bind pairs: $(failed) mismatch(es), $(accepted) accepted difference(s)")
  failed > 0 && exit(1)
end

if abspath(PROGRAM_FILE) == @__FILE__
  main()
end
