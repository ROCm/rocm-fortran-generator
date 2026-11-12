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

# src/tools/gen_symbol_tests.jl
#
# Generate one exhaustive "symbol" test per ROCm/HIP library. For every routine
# that exposes a C binding (`bind(C)`) this emits a Fortran program that
# references *every* such routine through its specific (`_`-suffixed) name.
#
# The goal is NOT to check numerical results, only to prove that:
#   * each bind(C) interface COMPILES (argument count and types line up), and
#   * each C symbol LINKS from Fortran against the installed ROCm library.
#
# Every call is guarded by `if (never) ...`, where `never` is derived from the
# runtime argument count so the compiler cannot fold it away: the program links
# against all symbols but never executes a call — this avoids the segfaults that
# would otherwise be unavoidable when calling e.g. rocblas_dgemm with null
# pointers. Scratch arguments are declared with the exact Fortran type/kind of
# each dummy of the bind(C) specific. Because we call the specific directly (not
# the generic) there is no overload resolution to get wrong; the typed scratch
# simply makes the specific's own interface compile.
#
# Two source layouts are supported, selected by ROCM_FORTRAN_LAYOUT (the variable
# the generator itself reads; LAYOUT is still accepted as a fallback spelling):
#
#   packaged (default) — the tree this repository generates: one module per
#                  library, named after the library, under
#                  fortran/rocm-{systems,libraries}/<lib>/<lib>.F90; tests are
#                  written to tests/symbols/test_<lib>.f90.
#
#   legacy         — the single-file hipfort layout: the interfaces live inline
#                  in <HIPFORT>/lib/hipfort/hipfort_<lib>.F90; tests are written
#                  to <HIPFORT>/test/f2003/<lib>/test_<lib>.F03 (preprocessed, with
#                  ROCm-only routines guarded by #ifndef USE_CUDA_NAMES so the same
#                  source also builds on the CUDA/NVIDIA backend).
#
# The default differs from the generator's (legacy) on purpose: this tool exists
# to keep tests/symbols/ in step with the tree this repository commits.
#
# Usage (from the repo root):
#   julia src/tools/gen_symbol_tests.jl                     # packaged, all libs
#   julia src/tools/gen_symbol_tests.jl rocblas hipfft      # packaged, a subset
#   ROCM_FORTRAN_LAYOUT=legacy HIPFORT=/path/to/hipfort \
#     julia src/tools/gen_symbol_tests.jl                   # legacy layout
#
# Build/link the packaged output with tests/build_symbols.sh; the legacy
# output is wired into hipfort's CTest behind -DHIPFORT_EXTENDED_TESTS=ON.

const REPO        = normpath(joinpath(@__DIR__, "..", ".."))

# The license banner, shared with the main generator. This is the only piece of
# src/common this script pulls in: license.jl has no dependencies of its own.
include(joinpath(@__DIR__, "..", "common", "license.jl"))

# ROCM_FORTRAN_LAYOUT is what config.jl and generate_all.jl read, so one variable
# drives the whole pipeline; LAYOUT is kept as a fallback for existing commands.
# The default is `packaged`, NOT the generator's `legacy`: the tests this tool
# writes by default are the ones committed under tests/symbols/.
const LAYOUT = let l = lowercase(get(ENV, "ROCM_FORTRAN_LAYOUT", get(ENV, "LAYOUT", "packaged")))
  l == "hipfort" ? "legacy" : l                      # accept the old spelling
end
const FORTRAN_DIR = get(ENV, "FORTRAN_DIR", joinpath(REPO, "fortran"))
const OUT_DIR     = get(ENV, "OUT_DIR", joinpath(REPO, "tests", "symbols"))
const HIPFORT     = get(ENV, "HIPFORT", joinpath(REPO, "hipfort"))

# The libraries a symbol test is generated for, in packaged-layout order. In the
# packaged layout the module is named after the library, so the test key and the
# module name coincide and this one list serves as the test keys, the module
# names and the recognizer for sibling `use` lines.
const LIBS = ["rocblas", "hipblas", "rocsolver", "hipsolver", "rocsparse",
  "hipsparse", "rocfft", "hipfft", "hipfftxt", "hipfftw", "rocrand", "hiprand", "hip", "roctx"]

# hipfort layout: the same libraries (each has a hipfort::<lib> CMake target,
# roctx included), with the HIP runtime first. "hip" is the runtime core (module
# `hipfort`, file hipfort.F90 -- see run_hipfort's special case); the
# hand-written functional tests in test/f2003/hip/ only cover a fraction of its
# bind(C) surface, so the exhaustive symbol test complements them (and audits the
# cuda*/cu* driver remaps under USE_CUDA_NAMES).
const HIPFORT_LIBS = ["hip"; filter(!=("hip"), LIBS)]

# The HIP runtime is split across several modules: hipfort.F90 holds the bulk,
# but the data-management routines (hipMalloc/hipMemcpy/hipHostRegister/...) live
# in sibling modules. Parse them all for the "hip" key so test_hip covers the
# whole runtime bind(C) surface, not just hipfort.F90.
const HIP_RUNTIME_MODULES = ["hipfort", "hipfort_hipmalloc", "hipfort_hipmemcpy",
  "hipfort_hiphostregister", "hipfort_auxiliary"]

# Routines DECLARED by the headers the bindings were generated from, but NOT
# EXPORTED by the runtime the tests link against. The binding itself is fine — an
# unreferenced bind(C) interface needs no symbol — but a symbol test exists
# precisely to reference every one of them, so it fails to link.
#
# This is a build-image skew, not a binding bug: ROCm 10.0.0 ships as several
# builds, and the HIP runtime used by CI (libamdhip64.so.7.13) predates the
# headers used here (7.15). Populate from the linker's "undefined symbol" list;
# empty the file once the generating and linking images agree.
#
# One C symbol per line, '#' comments ignored.
const SYMBOL_TEST_SKIP = let f = joinpath(@__DIR__, "symbol_test_skip.txt")
  isfile(f) ? Set(filter(s -> !isempty(s) && !startswith(s, "#"),
                         strip.(readlines(f)))) : Set{String}()
end

# ---------------------------------------------------------------------------
# Fortran source tokenizing
# ---------------------------------------------------------------------------

"Remove a trailing Fortran comment, respecting single/double quoted strings."
function strip_comment(line::AbstractString)
  io = IOBuffer(); quote_ch = '\0'
  for ch in line
    if quote_ch != '\0'
      write(io, ch); ch == quote_ch && (quote_ch = '\0')
    elseif ch == '\'' || ch == '"'
      quote_ch = ch; write(io, ch)
    elseif ch == '!'
      break
    else
      write(io, ch)
    end
  end
  return String(take!(io))
end

# The interfaces are guarded by `#ifdef/#ifndef USE_CUDA_NAMES`: some routines
# only exist on the ROCm backend (inside `#ifndef USE_CUDA_NAMES`), a few only on
# the CUDA backend, and the rest exist on both (either unguarded, or a renamed
# `#ifdef/#else` pair that merely picks the C symbol name). To generate one test
# source that compiles on both backends we must know, per routine, in which
# USE_CUDA_NAMES branch it lives. We ignore every other macro
# (USE_ASSUMED_SHAPE / USE_ASSUMED_RANK): those only add
# non-bind(C) overloads, which the parser skips anyway.

"Effective USE_CUDA_NAMES state for a directive stack: `:roc` (only when the macro
is undefined), `:cuda` (only when defined), `:both`, or `:dead` (unreachable)."
function cuda_state(stack::Vector{Symbol})
  has_roc = :roc in stack; has_cuda = :cuda in stack
  return has_roc && has_cuda ? :dead : has_roc ? :roc : has_cuda ? :cuda : :both
end

"Update the conditional stack for one `#...` directive. USE_CUDA_NAMES pushes a
`:roc`/`:cuda` frame; any other conditional pushes a transparent `:ignore` frame
so its `#else`/`#endif` cannot corrupt the USE_CUDA_NAMES tracking."
function update_stack!(stack::Vector{Symbol}, directive::AbstractString)
  d = lowercase(strip(directive))
  if occursin(r"^#\s*ifdef\s+use_cuda_names\b", d)
    push!(stack, :cuda)
  elseif occursin(r"^#\s*ifndef\s+use_cuda_names\b", d)
    push!(stack, :roc)
  elseif occursin(r"^#\s*if(n?def)?\b", d)          # any other #if/#ifdef/#ifndef
    push!(stack, :ignore)
  elseif occursin(r"^#\s*elif\b", d)
    isempty(stack) || (stack[end] = :ignore)
  elseif occursin(r"^#\s*else\b", d)
    if !isempty(stack)
      top = stack[end]
      stack[end] = top === :cuda ? :roc : top === :roc ? :cuda : :ignore
    end
  elseif occursin(r"^#\s*endif\b", d)
    isempty(stack) || pop!(stack)
  end
  # #define / #include / #undef: no effect on the conditional stack.
  return stack
end

"Split into logical lines paired with their USE_CUDA_NAMES state: comments
stripped, preprocessor directives consumed (to track the state) but not emitted,
and `&` continuations joined."
function logical_lines(text::AbstractString)
  out = Tuple{String,Symbol}[]; buf = ""; buf_state = :both; stack = Symbol[]
  for raw in split(text, '\n')
    line = strip_comment(raw)
    if startswith(lstrip(line), "#")             # C preprocessor directive
      update_stack!(stack, lstrip(line)); continue
    end
    if !isempty(buf)
      buf = buf * " " * replace(line, r"^\s*&" => "")
    else
      buf = line; buf_state = cuda_state(stack)
    end
    if occursin(r"&\s*$", buf)
      buf = replace(buf, r"&\s*$" => "")
    else
      push!(out, (buf, buf_state)); buf = ""
    end
  end
  isempty(buf) || push!(out, (buf, buf_state))
  return out
end

"Index of the ')' matching the '(' at `open_idx` (1-based)."
function matched_paren(s::AbstractString, open_idx::Int)
  depth = 0
  for i in open_idx:lastindex(s)
    c = s[i]
    c == '(' && (depth += 1)
    c == ')' && (depth -= 1; depth == 0 && return i)
  end
  return 0
end

"Split on commas that are not nested inside parentheses."
function split_top_commas(s::AbstractString)
  parts = String[]; depth = 0; cur = IOBuffer()
  for c in s
    if c == '('
      depth += 1; write(cur, c)
    elseif c == ')'
      depth -= 1; write(cur, c)
    elseif c == ',' && depth == 0
      push!(parts, String(take!(cur)))
    else
      write(cur, c)
    end
  end
  s2 = String(take!(cur)); isempty(strip(s2)) || push!(parts, s2)
  return [strip(p) for p in parts if !isempty(strip(p))]
end

const TYPE_RE   = r"^\s*(type|integer|real|complex|character|logical)\b"i
const HEADER_RE = r"^\s*(function|subroutine)\s+([A-Za-z_]\w*)\s*\("i
const RESULT_RE = r"\bresult\s*\(\s*([A-Za-z_]\w*)\s*\)"i

"Normalized base type spec left of `::`, e.g. `type(c_ptr)`, `real(c_float)`."
function parse_base_type(left::AbstractString)
  m = match(TYPE_RE, left)
  m === nothing && return nothing
  kw = lowercase(m.captures[1])
  rest = left[nextind(left, m.offset + length(m.match) - 1):end]
  j = findfirst(!isspace, rest)
  if j !== nothing && rest[j] == '('
    close = matched_paren(rest, j)
    if close != 0
      grp = replace(rest[j:close], r"\s+" => "")
      return kw * grp
    end
  end
  return kw
end

"List of (name, is_array) entities right of `::`."
function parse_entities(right::AbstractString)
  out = Tuple{String,Bool}[]
  for ent in split_top_commas(right)
    e = strip(split(ent, '=')[1])
    m = match(r"^([A-Za-z_]\w*)", e)
    m === nothing && continue
    push!(out, (m.captures[1], occursin('(', e)))
  end
  return out
end

"Every hipfort_* module `use`d anywhere in a source file (enums/types are often
shared, e.g. rocSOLVER reuses rocBLAS enums, the hip* libs reuse hipfort_enums)."
function collect_hipfort_uses(path::AbstractString)
  mods = Tuple{String,Symbol}[]; seen = Set{String}(); stack = Symbol[]
  for raw in eachline(path)
    s = lstrip(strip_comment(raw))
    if startswith(s, "#")                       # track USE_CUDA_NAMES nesting
      update_stack!(stack, s); continue
    end
    m = match(r"^\s*use\s+(hipfort_\w+)"i, s)
    m === nothing && continue
    mod = m.captures[1]
    mod in seen && continue
    # e.g. hipfort_cuda_errors is `use`d only under #ifdef USE_CUDA_NAMES; record
    # the guard so the emitted test does not `use` a module absent on a backend.
    push!(seen, mod); push!(mods, (mod, cuda_state(stack)))
  end
  return mods
end

mutable struct Proc
  kind    :: String                 # "function" | "subroutine"
  name    :: String                 # specific (own) name
  generic :: Union{String,Nothing}  # generic interface name, or nothing (bare)
  args    :: Vector{String}
  argtypes:: Dict{String,Tuple{String,Bool}}
  rettype :: Union{String,Nothing}
  retarr  :: Bool
  guard   :: Symbol                 # USE_CUDA_NAMES branch: :both | :roc | :cuda | :dead
end

"Parse every bind(C) routine from a file containing `interface` blocks."
function parse_interfaces(path::AbstractString)
  lines = logical_lines(read(path, String))
  procs = Proc[]
  in_iface = false; generic = nothing; iface_guard = :both
  cur = nothing; retname = ""
  for (line, state) in lines
    low = lowercase(strip(line))
    if !in_iface
      m = match(r"^\s*interface\b(.*)$"i, line)
      if m !== nothing && !startswith(low, "end")
        nm = strip(m.captures[1])
        generic = occursin(r"^[A-Za-z_]\w*$", nm) ? nm : nothing
        in_iface = true
        # The generic name sits on the `interface` line, so its guard state is
        # the one that governs the routine. A renamed `#ifdef/#else` pair lives
        # *inside* the interface and only picks the C symbol name -> :both here.
        iface_guard = state
      end
      continue
    end
    if occursin(r"^\s*end\s+interface\b"i, line)
      in_iface = false; generic = nothing; cur = nothing
      continue
    end
    if cur === nothing
      hm = match(HEADER_RE, line)
      if hm !== nothing && occursin(r"bind\(c"i, line)
        op = findnext('(', line, hm.offset)
        cp = matched_paren(line, op)
        arglist = cp != 0 ? line[nextind(line, op):prevind(line, cp)] : ""
        args = split_top_commas(arglist)
        cur = Proc(lowercase(hm.captures[1]), hm.captures[2], generic,
                   args, Dict{String,Tuple{String,Bool}}(), nothing, false,
                   iface_guard)
        rm = match(RESULT_RE, line)
        retname = lowercase(rm !== nothing ? rm.captures[1] : hm.captures[2])
      end
      continue
    end
    if occursin(r"^\s*end\s+(function|subroutine)\b"i, line)
      push!(procs, cur); cur = nothing; retname = ""
      continue
    end
    if occursin("::", line) && match(TYPE_RE, line) !== nothing
      left, right = split(line, "::", limit = 2)
      base = parse_base_type(left)
      base === nothing && continue
      argset = Set(lowercase.(cur.args))
      for (ent, isarr) in parse_entities(right)
        key = lowercase(ent)
        if key == retname
          cur.rettype = base; cur.retarr = isarr
        end
        if key in argset
          cur.argtypes[key] = (base, isarr)
        end
      end
    end
  end
  return procs
end

# ---------------------------------------------------------------------------
# Emission
# ---------------------------------------------------------------------------

"Wrap a single Fortran statement over continuation lines (< 132 columns)."
function wrap_fortran(stmt::AbstractString; indent = "    ", limit = 120)
  length(indent) + length(stmt) <= limit && return [indent * stmt]
  out = String[]; cur = indent; toks = split(stmt, ", ")
  for (i, tok) in enumerate(toks)
    piece = i == length(toks) ? tok : tok * ", "
    if length(cur) + length(piece) + 2 > limit && !isempty(strip(cur))
      push!(out, cur * "&"); cur = indent * "  " * piece
    else
      cur *= piece
    end
  end
  push!(out, cur)
  return out
end

"Build the Fortran test program text for one library. When `guard_cuda` is set,
routines that exist on only one backend are wrapped in the matching
`#ifdef/#ifndef USE_CUDA_NAMES` so the single source compiles on both backends
(the output must then be a preprocessed source, e.g. .F03, and CUDA builds must
compile it with -DUSE_CUDA_NAMES like the library itself)."
function build_program(key::String, uses::Vector{Tuple{String,Symbol}},
                       procs::Vector{Proc}; guard_cuda::Bool = false)
  # Reference the bind(C) *specific* (the `_`-suffixed procedure), never the
  # generic. The modules export no `private`, so the specific is accessible, and
  # calling it directly is unambiguous: it can never resolve to a Fortran
  # array/pointer (USE_ASSUMED_SHAPE) or assumed-rank/-shape
  # (USE_ASSUMED_RANK) overload, whichever way the library was built.
  # The specific body is the C binding itself, so this is the most direct proof
  # that the C symbol links.
  seen = Set{String}(); callable = Tuple{String,Proc}[]
  for p in procs
    cn = p.name
    cn in seen && continue
    push!(seen, cn); push!(callable, (cn, p))
  end

  scratch = Dict{String,String}(); decls = String[]
  function scratch_var(base::String, isarr::Bool)
    k = base * (isarr ? "|A" : "|S")
    haskey(scratch, k) && return scratch[k]
    v = "v$(length(scratch))"; scratch[k] = v
    push!(decls, isarr ? "  $base :: $v(1)" : "  $base :: $v")
    return v
  end

  # Each entry: (guard, wrapped-call-lines). Guard is forced to :both when we are
  # not emitting USE_CUDA_NAMES guards (the packaged layout is ROCm-only).
  callblocks = Tuple{Symbol,Vector{String}}[]; nref = 0; nroc = 0; skipped = String[]
  for (cn, p) in callable
    guard = guard_cuda ? p.guard : :both
    guard === :dead && (push!(skipped, cn); continue)   # unreachable branch
    # The skip file lists C SYMBOLS (hipGreenCtxCreate); `cn` is the Fortran
    # specific, which carries a trailing underscore (hipGreenCtxCreate_). Compare
    # both spellings so either form in the file works.
    (cn in SYMBOL_TEST_SKIP || rstrip(cn, '_') in SYMBOL_TEST_SKIP) &&
      (push!(skipped, cn); continue)   # absent from the runtime we link
    actuals = String[]; ok = true
    for a in p.args
      info = get(p.argtypes, lowercase(a), nothing)
      info === nothing && (ok = false; break)
      push!(actuals, scratch_var(info[1], info[2]))
    end
    if !ok
      push!(skipped, cn); continue
    end
    al = join(actuals, ", ")
    lines = if p.kind == "function"
      p.rettype === nothing && (push!(skipped, cn); continue)
      rv = scratch_var(p.rettype, p.retarr)
      wrap_fortran("if (never) $rv = $cn($al)")
    else
      wrap_fortran("if (never) call $cn($al)")
    end
    push!(callblocks, (guard, lines)); nref += 1
    guard === :roc && (nroc += 1)
  end

  # Emit the calls, coalescing adjacent runs of the same guard into a single
  # #ifndef/#ifdef ... #endif block. Directives are flush-left for the preprocessor.
  calls = String[]; curguard = :both
  open_guard(g)  = g === :roc ? "#ifndef USE_CUDA_NAMES" : "#ifdef USE_CUDA_NAMES"
  for (g, lines) in callblocks
    if g != curguard
      curguard === :both || push!(calls, "#endif")
      g === :both || push!(calls, open_guard(g))
      curguard = g
    end
    append!(calls, lines)
  end
  curguard === :both || push!(calls, "#endif")

  io = IOBuffer()
  emit_license_header(io; years = "2020-2026")
  println(io, "program test_$key")
  println(io, "  use iso_c_binding")
  for (u, g) in uses
    gg = guard_cuda ? g : :both
    gg === :roc  && println(io, "#ifndef USE_CUDA_NAMES")
    gg === :cuda && println(io, "#ifdef USE_CUDA_NAMES")
    println(io, "  use $u")
    gg === :both || println(io, "#endif")
  end
  println(io, "  implicit none")
  println(io, "  logical :: never")
  for d in decls; println(io, d); end
  println(io)
  println(io, "  ! Always .false., but not foldable by the compiler, so every guarded")
  println(io, "  ! call is compiled and linked yet never run (no null-pointer segfaults).")
  println(io, "  never = command_argument_count() > 1000000")
  println(io)
  for c in calls; println(io, c); end
  println(io)
  println(io, "  write(*,\"(a)\") \"-- test_$key (bind(C) symbols): PASSED (compile+link only)!\"")
  println(io, "end program test_$key")
  return String(take!(io)), nref, skipped
end

report(key, out, nref, skipped) = println(
  rpad("  $key", 12), "-> ", relpath(out, REPO), "  ($nref routines)",
  isempty(skipped) ? "" : "  skipped $(length(skipped)): $(join(first(skipped, 6), ", "))")

# ---------------------------------------------------------------------------
# Drivers
# ---------------------------------------------------------------------------

# Locate a packaged module under FORTRAN_DIR. The packaged tree holds one
# directory per library (fortran/<repo>/<lib>/), so search those subtrees rather
# than assuming a flat directory. Returns "" when not found.
#
# Only the two repo subtrees are searched, deliberately: a leftover file sitting
# flat in FORTRAN_DIR from an older generation must not win. That happened, and
# the symbol tests were silently built from months-old interfaces.
function find_module(name::String)
  for repo in ("rocm-systems", "rocm-libraries")
    sub = joinpath(FORTRAN_DIR, repo)
    isdir(sub) || continue
    for (root, _dirs, files) in walkdir(sub)
      name in files && return joinpath(root, name)
    end
  end
  return ""
end

function run_packaged(want)
  total = 0
  for key in LIBS
    want === nothing || key in want || continue
    path = find_module("$(key).F90")
    isempty(path) && (path = find_module("$(key).f90"))
    isempty(path) && (@warn("module not found — skipping", key, FORTRAN_DIR); continue)
    # A packaged module is self-contained, so the only `use` the test needs is the
    # module itself -- plus any sibling it narrowly uses (rocsolver -> rocblas),
    # whose kinds the scratch declarations reference.
    uses = [(key, :both)]
    for (m, g) in collect_packaged_uses(path)
      m == key || push!(uses, (m, g))
    end
    text, nref, skipped = build_program(key, uses, parse_interfaces(path))
    mkpath(OUT_DIR)
    out = joinpath(OUT_DIR, "test_$key.f90")
    write(out, text); report(key, out, nref, skipped); total += nref
  end
  return total
end

"Sibling packaged modules `use`d by a file (they are named after the libraries,
so the hipfort_* regex in collect_hipfort_uses cannot see them)."
function collect_packaged_uses(path::AbstractString)
  known = Set(LIBS)
  out = Tuple{String,Symbol}[]; seen = Set{String}(); stack = Symbol[]
  for raw in eachline(path)
    s = lstrip(strip_comment(raw))
    if startswith(s, "#"); update_stack!(stack, s); continue; end
    m = match(r"^\s*use\s+(\w+)"i, s)
    m === nothing && continue
    mod = lowercase(m.captures[1])
    (mod in known && !(mod in seen)) || continue
    push!(seen, mod); push!(out, (mod, cuda_state(stack)))
  end
  return out
end

# Locate <base>.[fF]90 in the per-library split directories.
function find_in_split(roots::Vector{String}, base::String)
  for root in roots, (dir, _d, files) in walkdir(root), e in ("F90", "f90")
    "$base.$e" in files && return joinpath(dir, "$base.$e")
  end
  return ""
end

function run_hipfort(want)
  libdir = joinpath(HIPFORT, "lib", "hipfort")
  # The split layout replaces the flat lib/hipfort/ with one directory per library
  # under lib/rocm-systems/ and lib/rocm-libraries/. Fall back to it so the symbol
  # tests can be regenerated against either shape of the checkout.
  splitroots = [joinpath(HIPFORT, "lib", r) for r in ("rocm-systems", "rocm-libraries")]
  splitroots = [r for r in splitroots if isdir(r)]
  (isdir(libdir) || !isempty(splitroots)) ||
    error("no hipfort bindings under $(joinpath(HIPFORT, "lib")) (set HIPFORT=...)")
  total = 0
  # Resolve a module base name (no extension) to its source file (.F90 or .f90).
  modpath(base) = let f90 = joinpath(libdir, "$base.F90"),
                      f   = joinpath(libdir, "$base.f90")
    isfile(f90) ? f90 : (isfile(f) ? f : find_in_split(splitroots, base))
  end
  # Packaged layout: one module per library, named after the library with no
  # hipfort_ prefix, with the enums/types/handles/Check folded in. Probe for it
  # rather than adding a mode flag, so the same command regenerates either shape.
  packaged = !isempty(splitroots) && !isempty(find_in_split(splitroots, "hipblas"))
  for key in HIPFORT_LIBS
    want === nothing || key in want || continue
    # "hip" spans several runtime modules (see HIP_RUNTIME_MODULES); every other
    # library is the single module `hipfort_<key>` (roctx ships as lowercase .f90).
    # In the packaged layout every library, HIP included, is one module `<key>`.
    bases = packaged ? [key] :
            key == "hip" ? HIP_RUNTIME_MODULES : ["hipfort_$key"]
    # Merge procs across all source files; dedup uses, widening a module's guard
    # to :both if it is `use`d unguarded in one file but under #ifdef in another.
    procs = Proc[]; order = String[]; gmap = Dict{String,Symbol}(); found = false
    add_use(m, g) = haskey(gmap, m) ? (gmap[m] == g || (gmap[m] = :both)) :
                                      (push!(order, m); gmap[m] = g)
    for base in bases
      path = modpath(base)
      isempty(path) && (@warn("hipfort module not found — skipping", key, base); continue)
      found = true
      # Both the interface bodies and the `use` list come from the module file:
      # every layout carries its interfaces inline.
      append!(procs, parse_interfaces(path))
      add_use(base, :both)                       # the module itself
      for (m, g) in collect_hipfort_uses(path); add_use(m, g); end
      # e.g. `module rocsolver` narrowly `use`s rocblas for the shared status kind;
      # the test declares scratch of that kind, so it needs the sibling too.
      packaged && for (m, g) in collect_packaged_uses(path); add_use(m, g); end
    end
    found || continue
    uses = Tuple{String,Symbol}[(m, gmap[m]) for m in order]
    text, nref, skipped = build_program(key, uses, procs; guard_cuda = true)
    outdir = joinpath(HIPFORT, "test", "f2003", key); mkpath(outdir)
    # .F03 (uppercase) so the build preprocesses the USE_CUDA_NAMES guards.
    out = joinpath(outdir, "test_$key.F03")
    write(out, text); report(key, out, nref, skipped); total += nref
  end
  return total
end

function main()
  want = isempty(ARGS) ? nothing : Set(ARGS)
  LAYOUT in ("legacy", "packaged") ||
    error("LAYOUT must be legacy or packaged, got \"$(LAYOUT)\"")
  total = LAYOUT == "legacy" ? run_hipfort(want) : run_packaged(want)
  println("Total routines referenced ($(LAYOUT) layout): $total")
end

main()
