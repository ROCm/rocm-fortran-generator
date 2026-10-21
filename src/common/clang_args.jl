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

using TOML

"""
    find_headers(cfg, base_dir) → Vector{String}

The header a library parses, from the [headers] section of its TOML config:

  - `subdir` (default: the library name): the directory it lives in;
  - `file` (default: `<subdir>.h`): the header itself. Only one is parsed, since
    only the first translation unit is walked.

The header is looked up as `<base_dir>/<subdir>/<file>` (an installed ROCm, or a
project whose headers are nested), then as `<base_dir>/<file>` (a project of the
monorepo whose headers are flat, such as rocBLAS's `library/include/rocblas.h`).
"""
function find_headers(cfg::Dict, base_dir::String) :: Vector{String}
  hsec   = get(cfg, "headers", Dict())
  subdir = get(hsec, "subdir", cfg["general"]["name"])
  file   = get(hsec, "file", subdir * ".h")
  for h in (joinpath(base_dir, subdir, file), joinpath(base_dir, file))
    isfile(h) && return [h]
  end
  error("Header $(file) not found in $(joinpath(base_dir, subdir)) nor in $(base_dir)\n" *
        "Install ROCm or pass the include directory as argument.")
end

# Feature guards (`#ifdef <LIB>_WITH_<FEATURE>`) are `#cmakedefine`s baked into a
# header at build time. Reproduce the release defaults from source: collect the
# `#cmakedefine` macros of the `*.h.in` templates and -D those whose CMake
# `option(... ON|OFF)` defaults to ON (following `set(WITH_X ${ENABLE_X})`).
function auto_feature_defines(base_dir::String) :: Vector{String}
  # Both templates: rocSPARSE splits its guards between -version.h.in and -config.h.in.
  templates = String[]
  for d in (base_dir, joinpath(base_dir, ".."), joinpath(base_dir, "..", ".."))
    isdir(d) || continue
    for f in readdir(d; join = true)
      (endswith(f, "-version.h.in") || endswith(f, "-config.h.in")) && push!(templates, f)
    end
    isempty(templates) || break
  end
  isempty(templates) && return String[]
  macros = String[]
  for vin in templates, ln in eachline(vin)
    m = match(r"^\s*#cmakedefine\s+(\w+)", ln)
    m === nothing || push!(macros, m.captures[1])
  end
  unique!(macros)
  isempty(macros) && return String[]
  cmake = ""
  for rel in ("CMakeLists.txt", joinpath("..", "CMakeLists.txt"), joinpath("..", "..", "CMakeLists.txt"))
    p = joinpath(base_dir, rel)
    isfile(p) && (cmake *= "\n" * read(p, String))
  end
  setmap = Dict{String,String}()
  for m in eachmatch(r"set\(\s*(\w+)\s+\$\{(\w+)\}\s*\)", cmake)
    setmap[m.captures[1]] = m.captures[2]
  end
  optmap = Dict{String,Bool}()
  for m in eachmatch(r"option\(\s*(\w+)\s+\"[^\"]*\"\s+(ON|OFF)", cmake)
    optmap[m.captures[1]] = (m.captures[2] == "ON")
  end
  defs = String[]
  for M in macros
    # Candidate CMake variables, in priority order: `set(M ${VAR})`, M itself,
    # the ENABLE_ sibling, then the BUILD_ variants (rocSPARSE).
    cands = String[]
    haskey(setmap, M) && push!(cands, setmap[M])
    push!(cands, M)
    push!(cands, replace(M, "_WITH_" => "_ENABLE_"))
    sm = match(r"_WITH_(.+)$", M)
    if sm !== nothing
      push!(cands, "BUILD_WITH_" * sm.captures[1])
      push!(cands, "BUILD_" * sm.captures[1])
    end
    resolved = false
    for V in cands
      if haskey(optmap, V)
        optmap[V] && push!(defs, M)
        resolved = true
        break
      end
    end
    resolved || @warn "auto_feature_defines: unresolved feature flag $M (no matching CMake option); left undefined, check manually"
  end
  isempty(defs) || @info "auto_feature_defines: enabled " * join(defs, ", ")
  return defs
end

# A source checkout lacks the headers its build generates; synthesize those the
# parsed headers include but no include dir holds, into a scratch dir searched
# after the source dirs:
#   - `*[-_]version.h`, `*-config.h` and ROCTx's `version.h`, from their `.h.in`
#     template and the checkout's CMake (project/set/rocm_setup_version/math, and
#     a VERSION file read by `file(READ)`); a `#define` left with an unresolved
#     `@VAR@` (git hashes, build host) is dropped, `#cmakedefine` flags come from
#     auto_feature_defines;
#   - `hip/hip_version.h`, from the HIP VERSION file, as clr/hipamd writes it
#     (less __HIP_HAS_GET_PCH, a build setting no header reads);
#   - `<base>-export.h`, CMake's generate_export_header output, as empty macros.
# Each lands at its included path and bare. Returns the scratch dir, or nothing
# when nothing is missing (built tree, installed ROCm).
function synth_generated_headers(headers::Vector{String}, dirs::Vector{String}) :: Union{String,Nothing}
  dirs = [abspath(d) for d in dirs if isdir(d)]
  absent = missing_includes(headers, dirs)
  isempty(absent) && return nothing
  out = mktempdir(; prefix = "rocm-fortran-generator-headers-")
  written = false
  for (inc, from) in absent
    isfile(joinpath(out, inc)) && continue   # already written bare
    text = generated_header(inc, from, dirs)
    text === nothing && continue
    for dst in unique([joinpath(out, inc), joinpath(out, basename(inc))])
      mkpath(dirname(dst)); write(dst, text)
    end
    written = true
  end
  return written ? out : nothing
end

# (include spelling, including dir) of every #include reachable from `headers`
# that no include dir resolves, following the resolved ones. Preprocessor
# conditions are ignored: an include never reached costs only an unused file.
function missing_includes(headers::Vector{String}, dirs::Vector{String})
  absent = Dict{String,String}()
  seen = Set{String}()
  todo = [abspath(h) for h in headers]
  while !isempty(todo)
    f = pop!(todo)
    (f in seen || !isfile(f)) && continue
    push!(seen, f)
    for m in eachmatch(r"^[ \t]*#[ \t]*include[ \t]*[<\"]([^>\"]+)[>\"]"m, read(f, String))
      inc = m.captures[1]
      hits = filter(isfile, [joinpath(d, inc) for d in [dirname(f); dirs]])
      isempty(hits) ? get!(absent, inc, dirname(f)) : push!(todo, normpath(first(hits)))
    end
  end
  return absent
end

function generated_header(inc::String, from::String, dirs::Vector{String}) :: Union{String,Nothing}
  if inc == "hip/hip_version.h"
    for d in dirs
      v = normpath(joinpath(d, "..", "VERSION"))
      isfile(joinpath(d, "hip", "hip_runtime_api.h")) && isfile(v) && return hip_version_header(v)
    end
    return nothing
  end
  t = template_of(inc, from, dirs)
  t === nothing || return substitute_template(t, dirs)
  endswith(inc, "-export.h") && return export_stub(basename(inc)[1:end-length("-export.h")])
  return nothing
end

# The `.h.in` next to where `inc` would be; failing that, a version/config
# template of the same name anywhere in the include dirs (a flat source layout
# whose headers include it as `<lib>/<name>`, its install path).
function template_of(inc::String, from::String, dirs::Vector{String}) :: Union{String,Nothing}
  for d in [from; dirs]
    t = joinpath(d, inc * ".in")
    isfile(t) && return t
  end
  occursin(r"([-_]version|-config)\.h$", inc) || return nothing
  for d in dirs, (root, _, files) in walkdir(d), f in files
    f == basename(inc) * ".in" && return joinpath(root, f)
  end
  return nothing
end

function substitute_template(t::String, dirs::Vector{String}) :: String
  # The CMake of the template's project: from the include dir holding it up two
  # levels, outermost first, as CMake reads them (project() is in the top-level file).
  t = realpath(t)
  roots = filter(d -> startswith(t, d * "/"), realpath.(dirs))
  base = isempty(roots) ? dirname(t) : first(roots)
  cmake, version = "", ""
  for rel in (joinpath("..", ".."), "..", ".")
    q = joinpath(base, rel, "CMakeLists.txt")
    isfile(q) && (cmake *= read(q, String) * "\n")
    v = joinpath(base, rel, "VERSION")
    isfile(v) && isempty(version) && (version = strip(first(eachline(v))))
  end
  vars = cmake_version_vars(cmake, version)
  subst(s) = replace(s, r"@(\w+)@" => m -> get(vars, m[2:end-1], m))
  text = join((ln for ln in eachline(t)
               if !(occursin(r"^\s*#\s*define\b", ln) && occursin(r"@\w+@|\$\{\w+\}", subst(ln)))),
              "\n")
  text = subst(text) * "\n"
  # `#cmakedefine` is an invalid directive to Clang; the flags come from -D.
  text = replace(text, r"^([ \t]*#[ \t]*cmakedefine(01)?\b.*)$"m => s"/* \1 */")
  @info "generated header: $(basename(t)[1:end-3]) from $(basename(t)) + CMake ($(join(sort([k for k in keys(vars) if endswith(k, "_VERSION_MAJOR") || endswith(k, "_VERSION_NUMBER")]), ", ")))"
  return text
end

# The VERSION file lists `#HIP_VERSION_MAJOR` then its value on the next line, etc.
function hip_version_header(version_file::String) :: String
  lines = strip.(readlines(version_file))
  function val(k)
    i = findfirst(==("#HIP_VERSION_$k"), lines)
    (i === nothing || i == length(lines)) && error("no #HIP_VERSION_$k value in $(version_file)")
    return lines[i + 1]
  end
  @info "generated header: hip/hip_version.h from $(version_file)"
  return """
    #ifndef HIP_VERSION_H
    #define HIP_VERSION_H
    #define HIP_VERSION_MAJOR $(val("MAJOR"))
    #define HIP_VERSION_MINOR $(val("MINOR"))
    #define HIP_VERSION_PATCH $(val("PATCH"))
    #define HIP_VERSION_GITHASH ""
    #define HIP_VERSION_BUILD_ID 0
    #define HIP_VERSION_BUILD_NAME ""
    #define HIP_VERSION    (HIP_VERSION_MAJOR * 10000000 + HIP_VERSION_MINOR * 100000 + HIP_VERSION_PATCH)
    #endif
    """
end

function export_stub(stem::AbstractString) :: String
  base = uppercase(replace(stem, r"\W" => "_"))
  @info "generated header: $(stem)-export.h (empty export macros)"
  return join(("#ifndef $(base)$(s)\n#define $(base)$(s)\n#endif\n"
               for s in ("_EXPORT", "_NO_EXPORT", "_DEPRECATED",
                         "_DEPRECATED_EXPORT", "_DEPRECATED_NO_EXPORT")))
end

# Variables set by project/set/rocm_setup_version/math in a CMakeLists.txt, and by
# `file(READ .../VERSION VAR)` given the project's VERSION file contents, which
# also stand in for a project() VERSION computed by string(REGEX). Unknown or
# computed values are left out.
function cmake_version_vars(cmake::AbstractString, version::AbstractString = "") :: Dict{String,String}
  vars = Dict{String,String}()
  expand(v) = begin
    for _ in 1:8
      w = replace(v, r"\$\{(\w+)\}" => m -> get(vars, m[3:end-1], m))
      w == v && break
      v = w
    end
    v
  end
  setver!(prefix, v) = begin
    m = match(r"^(\d+)\.(\d+)\.(\d+)", v)
    m === nothing && return
    for (k, x) in zip(("MAJOR", "MINOR", "PATCH"), m.captures)
      vars["$(prefix)_VERSION_$(k)"] = x
    end
  end
  pname = ""
  for m in eachmatch(r"^[ \t]*(project|set|rocm_setup_version|math|file)[ \t]*\(([^)]*)\)"mi, cmake)
    cmd = lowercase(m.captures[1]); body = strip(m.captures[2])
    toks = [String(strip(x.match, '"')) for x in eachmatch(r"\"[^\"]*\"|[^\s\"]+", body)]
    isempty(toks) && continue
    if cmd == "project"
      pname = toks[1]; vars["PROJECT_NAME"] = pname
      i = findfirst(==("VERSION"), toks)
      if i !== nothing && i < length(toks)
        v = expand(toks[i+1])
        occursin(r"^\d+\.\d+\.\d+", v) || isempty(version) || (v = version)
        vars["PROJECT_VERSION"] = v
        setver!("PROJECT", v); setver!(pname, v)
      end
    elseif cmd == "file"
      length(toks) >= 3 && uppercase(toks[1]) == "READ" && endswith(toks[2], "/VERSION") &&
        !isempty(version) && (vars[toks[3]] = version)
    elseif cmd == "set"
      length(toks) >= 2 && !occursin(r"^(CACHE|PARENT_SCOPE)$", toks[2]) &&
        (vars[toks[1]] = expand(toks[2]))
    elseif cmd == "rocm_setup_version"
      i = findfirst(==("VERSION"), toks)
      (i === nothing || i == length(toks) || isempty(pname)) && continue
      v = expand(toks[i+1])
      # Templates also spell the prefix in lower case (rocrand_VERSION_NUMBER
      # under project(rocRAND)).
      setver!(pname, v); setver!(lowercase(pname), v)
    elseif cmd == "math" && length(toks) >= 3 && uppercase(toks[1]) == "EXPR"
      e = expand(toks[3])
      occursin(r"^[\d\s+*()-]+$", e) || continue
      val = try
        string(Base.eval(Meta.parse(e)))
      catch
        nothing
      end
      val === nothing || (vars[toks[2]] = val)
    end
  end
  return vars
end

# The HIP runtime headers of the rocm-systems checkout in ROCM_SYSTEMS (source
# mode): hip/ holds the API, clr/hipamd/ the hip/amd_detail/ headers it includes.
function hip_source_includes() :: Vector{String}
  sys = get(ENV, "ROCM_SYSTEMS", "")
  isempty(sys) && return String[]
  return [joinpath(abspath(sys), "projects", "hip", "include"),
          joinpath(abspath(sys), "projects", "clr", "hipamd", "include")]
end

function make_clang_args(cfg::Dict, base_dir::String) :: Vector{String}
  args = get_default_args()
  push!(args, "-I$(base_dir)")

  # Source mode: the math libraries include the HIP runtime headers.
  for d in hip_source_includes()
    d == abspath(base_dir) || push!(args, "-I$(d)")
  end

  for extra in get(get(cfg, "clang", Dict()), "extra_include_dirs", String[])
    extra_abs = isabspath(extra) ? extra : joinpath(base_dir, extra)
    isdir(extra_abs) && push!(args, "-I$(extra_abs)")
  end

  for def in get(get(cfg, "clang", Dict()), "defines", String[])
    push!(args, "-D$(def)")
  end

  for M in auto_feature_defines(base_dir)
    push!(args, "-D$(M)")
  end

  for a in get(get(cfg, "clang", Dict()), "extra_args", String[])
    push!(args, a)
  end

  push!(args, "-D__HIP_PLATFORM_AMD__=1")

  libname = cfg["general"]["name"]
  push!(args, "-D$(uppercase(libname))_EXPORT=")
  push!(args, "-DROCBLAS_EXPORT=")
  push!(args, "-DROCSOLVER_EXPORT=")

  # C23, for the `[[deprecated]]` enumerator attributes of newer headers (rocSPARSE):
  # libclang 16 (Julia 1.11) rejects them in its default C mode.
  push!(args, "-x", "c", "-std=gnu2x")
  return args
end

"""
    parse_checked(headers, args) → (ctx, tu)

Parse `headers` with `args`, after synthesizing the build-generated headers they
include and the include dirs lack. Exactly one header is allowed: only the first
translation unit is walked. Any Clang error is fatal, so that a missing header
fails the library instead of yielding a partial module.

`ROCM_FORTRAN_HIP_INCLUDE`, set by generate_all.jl when the math libraries come
from a rocm-libraries checkout alone, is the installed include dir their HIP
headers come from. It also holds older math library headers, so only its hip/
subdirectory is exposed, searched last and hidden from the synthesis: a math
library header the checkout lacks fails the parse instead of being read from the
installed tree.
"""
function parse_checked(headers::Vector{String}, args::Vector{String})
  gen = synth_generated_headers(headers, [a[3:end] for a in args if startswith(a, "-I")])
  gen === nothing || push!(args, "-I$(gen)")
  hip = get(ENV, "ROCM_FORTRAN_HIP_INCLUDE", "")
  isempty(hip) || push!(args, "-I$(hip_only_include(hip))")
  ctx = create_context(headers, args)
  @assert length(ctx.trans_units) == 1
  tu = ctx.trans_units[1]
  check_diagnostics(tu)
  return ctx, tu
end

# A scratch include dir whose only entry is a link to `installed`/hip.
function hip_only_include(installed)
  dir = mktempdir()
  symlink(joinpath(abspath(installed), "hip"), joinpath(dir, "hip"))
  return dir
end

function check_diagnostics(tu)
  L = Clang.LibClang
  errors = String[]
  for i in 0:Int(L.clang_getNumDiagnostics(tu.ptr))-1
    d = L.clang_getDiagnostic(tu.ptr, i)
    if L.clang_getDiagnosticSeverity(d) >= L.CXDiagnostic_Error
      s = L.clang_formatDiagnostic(d, L.clang_defaultDiagnosticDisplayOptions())
      push!(errors, unsafe_string(L.clang_getCString(s)))
      L.clang_disposeString(s)
    end
    L.clang_disposeDiagnostic(d)
  end
  isempty(errors) && return
  foreach(e -> @error(e), errors)
  error("$(length(errors)) Clang error(s) parsing the headers")
end

# [library] alias_function_macros: for `#define roctxMark(m) roctxMarkA(m)`, emit
# the documented name roctxMark bound to the ABI symbol roctxMarkA.
function alias_function_macros!(funcs, cfg::Dict, ctx, tu, root, own_headers)
  get(cfg["library"], "alias_function_macros", false) || return funcs
  fwd = GC.@preserve ctx tu collect_forwarding_macros(root; own=own_headers)
  funcs = apply_bind_renames!(funcs, fwd)
  isempty(fwd) || @info "Renamed $(length(fwd)) function(s) to their forwarding-macro name" fwd
  return funcs
end

"""
    run_library_generator(dir; headers, include_dir, argshook, funcfilter, gen_kwargs...)

Parse one library's headers and emit its Fortran module: everything a
`src/<lib>/generator.jl` does that is not genuinely per library.

`dir` is the library's own source directory (`@__DIR__` at the call site); its
name selects both the config (`<dir>/<lib>.toml`) and the default output
directory. The caller's `ARGS` win: `ARGS[1]` is the include dir, `ARGS[2]`
the output dir.

All hooks are optional:

  `headers`     `include_dir -> Vector{String}`, the header probe. It owns its
                error messages and its "Parsing: …" log line, because the probe
                is the one step no two libraries spell the same way. Omit it to
                discover the headers from the TOML's [headers] section instead.
  `include_dir` where to look when the caller passed no `ARGS[1]`.
  `argshook`    `(args, include_dir, headers)`, extra Clang flags.
  `funcfilter`  `funcs -> funcs`, applied after the count is logged, so the log
                still reports what the header declares.

Everything else is forwarded to `gen_files`.
"""
function run_library_generator(dir::AbstractString;
                               headers    = nothing,
                               include_dir::AbstractString = "/opt/rocm/include",
                               argshook   = nothing,
                               funcfilter = nothing,
                               gen_kwargs...)
  reset_generator_state!()
  lib = basename(dir)
  cfg = TOML.parsefile(joinpath(dir, "$(lib).toml"))

  include_dir = abspath(length(ARGS) >= 1 ? ARGS[1] : include_dir)
  output_dir  = length(ARGS) >= 2 ? ARGS[2] : joinpath(dir, "output")
  mkpath(output_dir)

  hdrs = if headers === nothing
    found = find_headers(cfg, include_dir)
    @info "Parsing: $(only(found))"
    found
  else
    headers(include_dir)
  end

  args = make_clang_args(cfg, include_dir)
  argshook === nothing || argshook(args, include_dir, hdrs)

  ctx, tu = parse_checked(hdrs, args)
  root = Clang.getTranslationUnitCursor(tu)

  prefix = cfg["library"]["prefix"]
  # An empty TOML array parses as Vector{Any}, which the typed keywords reject.
  strlist(x) = collect(String, x)
  handles = strlist(get(cfg["library"], "opaque_handles", String[]))

  funcs = GC.@preserve ctx tu collect_funcs(root, prefix)
  @info "Found $(length(funcs)) $(prefix)* functions"
  funcfilter === nothing || (funcs = funcfilter(funcs))

  own_headers = strlist(get(cfg["library"], "own_headers", [cfg["general"]["name"]]))
  # reexport_enums: sibling libraries whose enums and constants are `use`d from the
  # sibling's module rather than duplicated (rocSOLVER takes rocBLAS's), so only
  # this library's own are emitted.
  reexport = strlist(get(cfg["library"], "reexport_enums", String[]))
  enum_own = isempty(reexport) ? own_headers : [cfg["general"]["name"]]
  enums = GC.@preserve ctx tu collect_enums(root; own=enum_own)
  @info "Found $(length(enums)) enums"

  macros = GC.@preserve ctx tu collect_macros(root; own=enum_own)
  @info "Found $(length(macros)) #define constants"

  # Each sibling constant, mapped to the module defining it, for the `use` lines.
  sibling_enum_mod = Dict{String,String}()
  sibling_enums = EnumInfo[]
  for sib in reexport
    sib_enums  = GC.@preserve ctx tu collect_enums(root; own=[sib])
    sib_macros = GC.@preserve ctx tu collect_macros(root; own=[sib])
    append!(sibling_enums, sib_enums)
    for e in sib_enums, c in e.constants; sibling_enum_mod[first(c)] = sib; end
    for mm in sib_macros; sibling_enum_mod[first(mm)] = sib; end
  end

  aliases = GC.@preserve ctx tu collect_name_aliases(root; own=own_headers)

  # keep: HIP vector types dropped by default but needed here (rocRAND's uint4).
  structs = GC.@preserve ctx tu collect_structs(root; skip=handles, own=own_headers,
                                                keep=strlist(get(cfg["library"], "keep_structs", String[])))
  @info "Found $(length(structs)) derived types"

  funcs = alias_function_macros!(funcs, cfg, ctx, tu, root, own_headers)

  gen_files(output_dir, cfg, funcs, enums, structs; macros=macros, aliases=aliases,
            sibling_enum_mod=sibling_enum_mod, sibling_enums=sibling_enums, gen_kwargs...)
end

# BLAS Set/Get Vector/Matrix families: drop them from the bind(C) path and emit
# their generics instead, from one list so the two cannot disagree.
function blas_aux_hooks(naming::Symbol, status::String)
  return (extra_procs    = blas_aux_procs(naming),
          extra_wrappers = io -> emit_blas_aux_impls(io, naming, status))
end
