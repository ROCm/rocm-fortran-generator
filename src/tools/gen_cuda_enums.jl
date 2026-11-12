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

# rocm-fortran/tools/gen_cuda_enums.jl
# Regenerate the USE_CUDA_NAMES enum overrides (src/<lib>/metadata/<lib>_enums_cuda.txt)
# from the CUDA headers, so every enumerator carries its CUDA value when the
# bindings call cu* entry points directly.
#
# For each enumerator of the generated hip* enums modules it finds the CUDA
# counterpart and reads its value with Clang:
#   - HIP runtime: the hip -> cuda/CU names that HIP's own NVIDIA backend uses
#     (hipother/hipnv nvidia_hip_runtime_api.h: its `#define hipX cudaX` lines and
#     the `case hipX: ... cudaY` arms of its switches), then hip -> cuda and
#     HIP_ -> CUDA_, or HIP_ -> CU_ for the driver API enums;
#   - math libraries: the prefix swap (HIPBLAS_ -> CUBLAS_, ...) plus RENAMES.
# An enumerator with no CUDA counterpart takes the CUDA value of the enumerator it
# aliases in HIP (same HIP value), keeps its HIP value when that value is free
# in the CUDA enum, and otherwise gets the first negative value below the enum's
# smallest, so no two enumerators of an enum share a value under USE_CUDA_NAMES (a
# duplicate breaks `select case`, and a status could be mistaken for a CUDA one).
# Negative, not above the largest: that could be a valid OR of flags (cublasMath_t)
# or a code a later CUDA adds.
# Only enumerators whose CUDA-mode value differs from the HIP one are written.
#
# Opt-in: it needs a CUDA toolkit's headers, the
# generator itself does not.
#
# Usage (from the rocm-fortran repo root, after a regeneration):
#   julia --project=src src/tools/gen_cuda_enums.jl <hipfort/lib/hipfort> \
#         [--cuda /usr/local/cuda/include] [--hipnv <nvidia_hip_runtime_api.h>]
# then regenerate again so the .F90 pick the new values up.

using Clang
using Clang.Generators: get_default_args

const SRC = abspath(joinpath(@__DIR__, ".."))

# Enums modules of each library that has a USE_CUDA_NAMES branch (hipFFT's Xt enums
# share hipfft_enums_cuda.txt).
const ENUM_FILES = ["hip" => "hipfort_enums.F90", "hipblas" => "hipfort_hipblas_enums.F90",
                    "hipsolver" => "hipfort_hipsolver_enums.F90",
                    "hipsparse" => "hipfort_hipsparse_enums.F90",
                    "hipfft" => ["hipfort_hipfft_enums.F90", "hipfort_hipfftxt_enums.F90"],
                    "hiprand" => "hipfort_hiprand_enums.F90"]

const PREFIXES = Dict(
  "hipblas"   => ["HIPBLAS_" => "CUBLAS_"],
  "hipsolver" => ["HIPSOLVERRF_" => "CUSOLVERRF_", "HIPSOLVERDN_" => "CUSOLVERDN_",
                  "HIPSOLVER_" => "CUSOLVER_", "HIPSOLVER_" => "CUBLAS_"],
  "hipsparse" => ["HIPSPARSE_" => "CUSPARSE_"],
  "hipfft"    => ["HIPFFT_" => "CUFFT_"],
  "hiprand"   => ["HIPRAND_" => "CURAND_"],
  "hip"       => ["HIP_" => "CUDA_", "HIP_" => "CU_", "hip" => "cuda"],
)

# Counterparts whose name is not a prefix swap.
const RENAMES = Dict(
  "HIPBLAS_MAJOR_VERSION" => "MAJOR_VERSION", "HIPBLAS_MINOR_VERSION" => "MINOR_VERSION",
  "HIPBLAS_PATCH_LEVEL" => "PATCH_LEVEL",
  "HIPFFT_MAJOR_VERSION" => "MAJOR_VERSION", "HIPFFT_MINOR_VERSION" => "MINOR_VERSION",
  "HIPFFT_PATCH_LEVEL" => "PATCH_LEVEL",
  "HIPSPARSE_FORMAT_SLICED_ELL" => "CUSPARSE_FORMAT_SLICED_ELLPACK",
  "HIPSPARSE_ORDER_COLUMN" => "CUSPARSE_ORDER_COL",
  "HIPSPARSE_MV_ALG_DEFAULT" => "CUSPARSE_SPMV_ALG_DEFAULT",
  "HIPSPARSE_COOMV_ALG" => "CUSPARSE_SPMV_COO_ALG1",
  "HIPSPARSE_CSRMV_ALG1" => "CUSPARSE_SPMV_CSR_ALG1",
  "HIPSPARSE_CSRMV_ALG2" => "CUSPARSE_SPMV_CSR_ALG2",
  "HIPSPARSE_MM_ALG_DEFAULT" => "CUSPARSE_SPMM_ALG_DEFAULT",
  "HIPSPARSE_COOMM_ALG1" => "CUSPARSE_SPMM_COO_ALG1",
  "HIPSPARSE_COOMM_ALG2" => "CUSPARSE_SPMM_COO_ALG2",
  "HIPSPARSE_COOMM_ALG3" => "CUSPARSE_SPMM_COO_ALG3",
  "HIPSPARSE_CSRMM_ALG1" => "CUSPARSE_SPMM_CSR_ALG1",
  # cuSPARSE spells these without the S.
  "HIPSPARSE_SPGEMM_CSR_ALG_DETERMINISTIC" => "CUSPARSE_SPGEMM_CSR_ALG_DETERMINITIC",
  "HIPSPARSE_SPGEMM_CSR_ALG_NONDETERMINISTIC" => "CUSPARSE_SPGEMM_CSR_ALG_NONDETERMINITIC",
  # cuFuncGetAttribute's spelling; hipnv has no #define for it.
  "HIP_FUNC_ATTRIBUTE_CLUSTER_DIM_MUST_BE_SET" => "CU_FUNC_ATTRIBUTE_CLUSTER_SIZE_MUST_BE_SET",
  # hipnv sends it through the default: arm of its switch to CU_MEMORYTYPE_UNIFIED.
  # hipMemoryTypeArray goes to CU_MEMORYTYPE_ARRAY = 3 = cudaMemoryTypeManaged: the
  # driver memcpy structs and the runtime pointer attributes number it differently.
  "hipMemoryTypeUnified" => "CU_MEMORYTYPE_UNIFIED",
)

const CUDA_HEADERS = ["cuda.h", "cuda_runtime_api.h", "library_types.h", "cublas_api.h",
                      "cusolverDn.h", "cusolverSp.h", "cusolverRf.h", "cusparse.h",
                      "cufft.h", "cufftXt.h", "curand.h"]

function cuda_enum_values(cudainc::String)
  hdr = joinpath(mktempdir(), "cuda_enums.h")
  write(hdr, join(("#include <$(h)>" for h in CUDA_HEADERS), "\n") * "\n")
  args = vcat(get_default_args(), ["-x", "c", "-I$(cudainc)"])
  tu = Clang.parse_header(Clang.Index(), hdr, args, Clang.CXTranslationUnit_None)
  vals = Dict{String,Int64}()
  enum_of = Dict{String,Int}()          # enumerator -> index of its enum in `members`
  members = Vector{Vector{Int64}}()     # every value of each CUDA enum
  walk(c) = for ch in Clang.children(c)
    k = Clang.kind(ch)
    if k == Clang.CXCursor_EnumDecl
      push!(members, Int64[])
      for e in Clang.children(ch)
        Clang.kind(e) == Clang.CXCursor_EnumConstantDecl || continue
        n = Clang.spelling(e); v = Clang.value(e)
        vals[n] = v; enum_of[n] = length(members); push!(members[end], v)
      end
    elseif k in (Clang.CXCursor_TypedefDecl, Clang.CXCursor_StructDecl, Clang.CXCursor_LinkageSpec)
      walk(ch)
    end
  end
  walk(Clang.getTranslationUnitCursor(tu))
  isempty(vals) && error("no enumerator found under $(cudainc)")
  return vals, enum_of, members
end

function cuda_version(cudainc::String)
  m = match(r"#define\s+CUDA_VERSION\s+(\d+)", read(joinpath(cudainc, "cuda.h"), String))
  m === nothing && return "unknown"
  v = parse(Int, m.captures[1])
  return "$(v ÷ 1000).$((v % 1000) ÷ 10)"
end

# hip -> cuda/CU enumerator names from HIP's NVIDIA backend. A candidate is kept
# only if it is a CUDA enumerator, so function names in the same lines are ignored.
function hipnv_names(path::String, cudavals::Dict{String,Int64})
  names = Dict{String,String}()
  pending = String[]
  cudatok = r"\b(cuda[A-Z]\w*|CU_[A-Z0-9_]+|CUDA_[A-Z0-9_]+)\b"
  # Join backslash continuations: a long #define puts its CUDA name on the next line.
  for ln in split(replace(read(path, String), r"\\\n\s*" => " "), '\n')
    m = match(r"^\s*#define\s+(hip\w+|HIP\w+)\s+(cuda\w+|CU\w+|CUDA\w+)\s*$", ln)
    if m !== nothing
      m.captures[2] in keys(cudavals) && get!(names, m.captures[1], m.captures[2])
      continue
    end
    c = match(r"^\s*case\s+(hip\w+|HIP\w+)\s*:", ln)
    if c !== nothing
      push!(pending, c.captures[1])
      rest = ln[c.offset + length(c.match):end]
      isempty(strip(rest)) && continue
      ln = rest
    end
    isempty(pending) && continue
    for t in eachmatch(cudatok, ln)
      if t.captures[1] in keys(cudavals)
        for h in pending; get!(names, h, t.captures[1]); end
        break
      end
    end
    empty!(pending)
  end
  return names
end

# Enumerators of each `enum, bind(c)` block, HIP branch only, in order.
function hip_enums(path::String)
  blocks = Vector{Vector{Pair{String,Int64}}}()
  cur = nothing; skip = false
  for ln in eachline(path)
    s = strip(ln)
    if s == "#ifdef USE_CUDA_NAMES"; skip = true; continue; end
    if s == "#else"; skip = false; continue; end
    s == "#endif" && (skip = false; continue)
    skip && continue
    if startswith(s, "enum, bind(c)")
      cur = Pair{String,Int64}[]
    elseif s == "end enum"
      cur === nothing || push!(blocks, cur); cur = nothing
    elseif cur !== nothing
      m = match(r"^enumerator\s*::\s*(\w+)\s*=\s*(-?\d+)", s)
      m === nothing || push!(cur, m.captures[1] => parse(Int64, m.captures[2]))
    end
  end
  return blocks
end

function counterpart(lib, nm, cudavals, hipnv)
  haskey(RENAMES, nm) && return get(RENAMES, nm, nothing)
  lib == "hip" && haskey(hipnv, nm) && return hipnv[nm]
  for (from, to) in PREFIXES[lib]
    startswith(nm, from) || continue
    c = to * nm[length(from)+1:end]
    haskey(cudavals, c) && return c
  end
  return nothing
end

function cuda_overrides(lib, blocks, cudavals, enum_of, members, hipnv)
  out = Pair{String,Int64}[]
  nmapped = 0; nalias = 0; nmoved = 0
  for blk in blocks
    cu = Dict{String,Int64}()
    # Values taken by the CUDA enum(s) this one maps onto, including the CUDA
    # enumerators HIP has no name for (e.g. CUBLAS_STATUS_LICENSE_ERROR).
    taken = Set{Int64}()
    for (nm, _) in blk
      c = counterpart(lib, nm, cudavals, hipnv)
      c === nothing && continue
      cu[nm] = cudavals[c]; nmapped += 1
      union!(taken, members[enum_of[c]])
    end
    # An unmapped enumerator aliasing a mapped one in HIP follows it.
    for (nm, v) in blk
      haskey(cu, nm) && continue
      twin = findfirst(p -> p.second == v && haskey(cu, p.first), blk)
      twin === nothing || (cu[nm] = cu[blk[twin].first]; nalias += 1)
    end
    used = union(taken, values(cu))
    for (nm, v) in blk
      haskey(cu, nm) && continue
      if v in used
        cu[nm] = min(minimum(used), 0) - 1; nmoved += 1
      else
        cu[nm] = v
      end
      push!(used, cu[nm])
    end
    for (nm, v) in blk
      cu[nm] == v || push!(out, nm => cu[nm])
    end
  end
  return out, (nmapped, nalias, nmoved)
end

function main()
  layout = ""; cudainc = "/usr/local/cuda/include"
  hipnv = joinpath(homedir(), "rocm-systems", "projects", "hipother", "hipnv", "include",
                   "hip", "nvidia_detail", "nvidia_hip_runtime_api.h")
  i = 1
  while i <= length(ARGS)
    a = ARGS[i]
    if a == "--cuda";      cudainc = ARGS[i+1]; i += 2
    elseif a == "--hipnv"; hipnv   = ARGS[i+1]; i += 2
    else layout = a; i += 1
    end
  end
  isdir(layout) || error("usage: gen_cuda_enums.jl <hipfort/lib/hipfort> [--cuda <include>] [--hipnv <header>]")
  isfile(hipnv) || error("HIP NVIDIA backend header not found: $(hipnv) (pass --hipnv)")

  cudavals, enum_of, members = cuda_enum_values(cudainc)
  ver = cuda_version(cudainc)
  names = hipnv_names(hipnv, cudavals)
  println("CUDA $(ver): $(length(cudavals)) enumerators | hipnv: $(length(names)) hip -> cuda names\n")

  for (lib, files) in ENUM_FILES
    paths = [joinpath(layout, f) for f in (files isa String ? [files] : files)]
    missing_paths = filter(!isfile, paths)
    isempty(missing_paths) || (@warn "missing $(join(missing_paths, ", "))"; continue)
    over, (nmapped, nalias, nmoved) = cuda_overrides(lib, reduce(vcat, hip_enums.(paths)), cudavals, enum_of, members, names)
    dest = joinpath(SRC, lib, "metadata", "$(lib)_enums_cuda.txt")
    open(dest, "w") do io
      println(io, "# USE_CUDA_NAMES values of the enumerators that differ from HIP, from the CUDA $(ver) headers.")
      println(io, "# Regenerate with src/tools/gen_cuda_enums.jl; it explains how a counterpart is chosen.")
      for (nm, v) in sort(over; by = first); println(io, "$(nm) $(v)"); end
    end
    println("  $(rpad(lib, 10)) mapped=$(nmapped) alias=$(nalias) renumbered=$(nmoved) -> $(length(over)) overrides")
  end
  println("\nRegenerate (generate_all.jl) so the .F90 pick the overrides up.")
end

if abspath(PROGRAM_FILE) == @__FILE__
  main()
end
