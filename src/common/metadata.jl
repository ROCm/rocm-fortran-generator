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

# Loaders and appliers of the per-library metadata files (<lib>.argkinds and
# friends), and LibMeta.

const EMPTY_STRSET = Set{String}()

"""
The per-library metadata the emitters consume, built once by gen_files
(assemble.jl) from the metadata files, the TOML and the parsed headers.
Function-keyed entries map a C function name to argument names.
"""
Base.@kwdef struct LibMeta
  "Highest rank_N array overload to generate per function (<lib>.native)."
  native::Dict{String,Int} = Dict{String,Int}()
  "Functions that also get a 2-D `_full_rank` overload (<lib>.native `full`)."
  fullrank::Set{String} = Set{String}()
  "The .argkinds scalar pointer arguments, reclassified from buffer to scalar."
  scalar_ptrs::Dict{String,Set{String}} = Dict{String,Set{String}}()
  "The pointer-mode subset of `scalar_ptrs` (<lib>.ptrmode)."
  ptrmode::Dict{String,Set{String}} = Dict{String,Set{String}}()
  "Typed pointers kept as an opaque c_ptr in the array overloads (<lib>.cptrargs)."
  cptr_args::Dict{String,Set{String}} = Dict{String,Set{String}}()
  "Kernel-written .argkinds scalars, which get no _typed form (<lib>.devonly)."
  devonly::Dict{String,Set{String}} = Dict{String,Set{String}}()
  "`[library] string_args`: `const char*` inputs get a character form in _typed."
  string_args::Bool = false
  "This library's own enum-constant and #define names: their kinds need no extra `use`."
  own_consts::Set{String} = Set{String}()
  "Foreign enum constant => sibling module that defines it (rocSOLVER uses rocBLAS kinds)."
  sibling_enum_mod::Dict{String,String} = Dict{String,String}()
  "Fortran routine name => C symbol for `bind(C, name=...)`, when they differ."
  bind_names::Dict{String,String} = Dict{String,String}()
  "Generic => module procedures a library emits itself, (per-rank, assumed-rank)
  (the BLAS Set/Get typed overloads); listed in the generic beside its own."
  extra_procs::Dict{String,Tuple{Vector{String},Vector{String}}} =
    Dict{String,Tuple{Vector{String},Vector{String}}}()
end

# Load a `<function> <arg> ...` metadata file (.argkinds and friends): function =>
# set of argument names. In .argkinds these are the scalar pointer arguments, which
# C cannot distinguish from buffers (`const double* alpha` vs `double* x`).
function load_argkinds(path::String) :: Dict{String,Set{String}}
  d = Dict{String,Set{String}}()
  isfile(path) || return d
  dup = String[]
  for ln in eachline(path)
    s = strip(ln)
    (isempty(s) || startswith(s, "#")) && continue
    parts = split(s)
    fn = String(parts[1])
    # A function may appear on several lines: merge, never overwrite.
    haskey(d, fn) ? push!(dup, fn) : (d[fn] = Set{String}())
    # Store names in their emitted spelling (safe_argname, idempotent), since every
    # consumer compares against a.name; both `value` and `myValue` are accepted.
    union!(d[fn], (safe_argname(p) for p in parts[2:end]))
  end
  isempty(dup) ||
    @info "  $(basename(path)): merged $(length(dup)) repeated function key(s)" sort!(unique(dup))
  return d
end

# -1 means no array overloads.
# An ILP64 (_64) or _v2 variant inherits its base function's entry in every
# per-function metadata file, so the base name is curated once for all of them.
variant_base(name) = replace(name, r"(_v2)?(_64)?$" => "")
meta_get(d, name, default) = get(d, name, get(d, variant_base(name), default))

native_maxrank(f::FuncInfo, meta::LibMeta) = meta_get(meta.native, f.name, -1)
wants_fullrank(f::FuncInfo, meta::LibMeta) =
  (f.name in meta.fullrank || variant_base(f.name) in meta.fullrank) && func_has_buffer(f, meta)

# <lib>.native: "name" (maxrank 1), "name <maxrank>" or "name full" per line.
# Returns (maxrank by name, full-rank names).
function load_native_funcs(path::String) :: Tuple{Dict{String,Int},Set{String}}
  d = Dict{String,Int}(); full = Set{String}()
  isfile(path) || return (d, full)
  for ln in readlines(path)
    t = strip(ln); (isempty(t) || startswith(t, "#")) && continue
    parts = split(t)
    if length(parts) >= 2 && parts[2] == "full"
      d[parts[1]] = 1; push!(full, String(parts[1]))
    else
      d[parts[1]] = length(parts) >= 2 ? parse(Int, parts[2]) : 1
    end
  end
  return (d, full)
end

# Argument-passing overrides the C headers cannot express, same `<function> <arg>
# ...` format as .argkinds; `*` as the function applies to every function.
#   <lib>.byvalue     force `, value`: HIP's `void** extra` passed by reference
#                     sends the address of a NULL variable, never NULL, and HIP
#                     rejects the launch (kernelParams, same C type, is by reference).
#   <lib>.funptrargs  type(c_funptr), value for function pointers declared void*.
#   <lib>.optional    nullable by-reference scalar (c_null_ptr by reference is not
#                     NULL; OPTIONAL in bind(C) needs F2018 18.3.6): bind(C) takes
#                     type(c_ptr),value, the module procedures take it OPTIONAL
#                     (see wants_opt).
#   <lib>.arrayargs   pointer to an emitted derived type is an array, `type(T) :: x(*)`.
function apply_arg_overrides(funcs::Vector{FuncInfo}, libdir::String,
                             libname::String) :: Vector{FuncInfo}
  byval  = load_argkinds(joinpath(libdir, "$(libname).byvalue"))
  funptr = load_argkinds(joinpath(libdir, "$(libname).funptrargs"))
  opt    = load_argkinds(joinpath(libdir, "$(libname).optional"))
  arrs   = load_argkinds(joinpath(libdir, "$(libname).arrayargs"))
  all(isempty, (byval, funptr, opt, arrs)) && return funcs
  names(d, f) = union(get(d, f.name, Set{String}()), get(d, "*", Set{String}()))
  out = FuncInfo[]
  rejected = String[]
  for f in funcs
    v, p, o, r = names(byval, f), names(funptr, f), names(opt, f), names(arrs, f)
    all(isempty, (v, p, o, r)) && (push!(out, f); continue)
    function override(a)
      a.name in p && return ArgInfo(a.name, "type(c_funptr)", ", value", a.is_string)
      a.name in v && return ArgInfo(a.name, a.ftype, ", value", a.is_string)
      if a.name in r
        startswith(a.ftype, "type(") && a.suffix == "" &&
          return ArgInfo(a.name, a.ftype, "(*)", a.is_string)
        push!(rejected, "$(f.name) $(a.name) (.arrayargs: not a derived-type pointer)")
      end
      if a.name in o
        a.suffix == "" && return ArgInfo(a.name, a.ftype, ", optional", a.is_string)
        push!(rejected, "$(f.name) $(a.name) (.optional: not a by-reference scalar)")
      end
      return a
    end
    push!(out, FuncInfo(f.name, f.ret_ftype, f.is_void, ArgInfo[override(a) for a in f.args]))
  end
  isempty(rejected) || @warn "$(libname): $(length(rejected)) argument override(s) ignored:" rejected
  return out
end

# Scalar pointer arguments (<lib>.argkinds) stay type(c_ptr),value in the bind(C)
# specific, so device pointer mode and NULL remain expressible, and get their
# natural Fortran type in a _typed module procedure of the same generic.
# <lib>.ptrmode names the subset governed by <lib>_set_pointer_mode; a routine
# that mixes them with host-only scalars also gets a _devptr form. <lib>.devonly
# names kernel-written scalars (hipSOLVER's devInfo), which get no _typed form.
# _typed must be a module procedure: two bind(C) specifics sharing one binding
# label are forbidden by F2018 19.2.

# Turn the .argkinds scalar pointer arguments from `x(*)` into scalars (suffix "").
# Also returns, per function, the arguments so reclassified (LibMeta.scalar_ptrs,
# so the generic can also offer the type(c_ptr) form for device pointer mode) and
# their pointer-mode subset (LibMeta.ptrmode).
function apply_argkinds(funcs::Vector{FuncInfo}, path::String)
  scalars = load_argkinds(path)
  ptrmode_file = load_argkinds(replace(path, r"\.argkinds$" => ".ptrmode"))
  scalar_ptrs = Dict{String,Set{String}}()
  ptrmode_ptrs = Dict{String,Set{String}}()
  isempty(scalars) && return (funcs, scalar_ptrs, ptrmode_ptrs)
  scalars_for(n) = meta_get(scalars, n, nothing)
  ptrmode_for(n) = meta_get(ptrmode_file, n, Set{String}())
  out = FuncInfo[]
  uncovered = String[]
  for f in funcs
    sset = scalars_for(f.name)
    if sset === nothing
      # Flag only unambiguous scalar names; c/s/tau depend on the routine.
      any(a -> a.suffix == "(*)" && occursin(r"^(alpha|beta|alphai|betai)$"i, a.name), f.args) &&
        push!(uncovered, f.name)
      push!(out, f); continue
    end
    changed = Set{String}(a.name for a in f.args if a.suffix == "(*)" && a.name in sset)
    isempty(changed) || (scalar_ptrs[f.name] = changed)
    pm = intersect(changed, ptrmode_for(f.name))
    isempty(pm) || (ptrmode_ptrs[f.name] = pm)
    newargs = ArgInfo[a.suffix == "(*)" && a.name in sset ?
                      ArgInfo(a.name, a.ftype, "", a.is_string) : a for a in f.args]
    push!(out, FuncInfo(f.name, f.ret_ftype, f.is_void, newargs))
  end
  isempty(uncovered) ||
    @info "argkinds: $(length(uncovered)) function(s) with scalar-looking args not in metadata (curate $(basename(path))):" uncovered
  return (out, scalar_ptrs, ptrmode_ptrs)
end

# Struct pointers map to `type(<name>)` by reference; those whose struct is not
# emitted (opaque, skipped) revert to `type(c_ptr), value`, and a typedef of an
# emitted struct (RECORD_ALIASES) takes the emitted name. A struct passed or
# returned BY VALUE cannot revert: a pointer in its place breaks the ABI, so the
# generation fails and the struct must be emitted (keep_structs) or the function
# skipped.
function revert_unknown_structs(funcs::Vector{FuncInfo}, structs) :: Vector{FuncInfo}
  keep = Set{String}(["c_ptr", "c_funptr"])
  for s in structs; push!(keep, s.name); end
  function resolve(ft)
    m = match(r"^type\((\w+)\)$", ft)
    (m === nothing || m.captures[1] in keep) && return ft
    a = get(RECORD_ALIASES[], m.captures[1], "")
    return a in keep ? "type($(a))" : nothing
  end
  byvalue = String[]
  for f in funcs
    for a in f.args
      a.suffix == ", value" && resolve(a.ftype) === nothing && push!(byvalue, "$(f.name)($(a.name))")
    end
    startswith(f.ret_ftype, "type(") && resolve(f.ret_ftype) === nothing && push!(byvalue, "$(f.name) (result)")
  end
  isempty(byvalue) ||
    error("struct passed or returned by value but not emitted, so no Fortran type matches its ABI " *
          "(emit it with keep_structs, or skip the function): " * join(byvalue, ", "))
  out = FuncInfo[]
  for f in funcs
    newargs = ArgInfo[(ft = resolve(a.ftype);
                       ft === nothing ? ArgInfo(a.name, "type(c_ptr)", ", value", a.is_string) :
                                        ArgInfo(a.name, ft, a.suffix, a.is_string))
                      for a in f.args]
    rft = something(resolve(f.ret_ftype), "type(c_ptr)")
    push!(out, FuncInfo(f.name, rft, f.is_void, newargs))
  end
  return out
end

# The per-function metadata files that name arguments, and .native, which does not.
const ARG_METADATA = ("argkinds", "ptrmode", "devonly", "cptrargs",
                      "optional", "byvalue", "funptrargs", "arrayargs")

"""
    check_metadata_names(funcs, libdir, libname)

Warn about every metadata entry that matches nothing, which would otherwise be
ignored silently: a function key no declared function has (a typo, or an API
removed), and an argument name the function does not have. A key is valid when
only its _64/_v2 variant is declared, and `*` (every function) is valid in the
override files. Run on the functions as parsed, before any metadata applies.
"""
function check_metadata_names(funcs::Vector{FuncInfo}, libdir::String, libname::String)
  args_of = Dict{String,Set{String}}()
  for f in funcs
    for n in (f.name, variant_base(f.name))
      union!(get!(args_of, n, Set{String}()), (a.name for a in f.args))
    end
  end
  for ext in (ARG_METADATA..., "native")
    path = joinpath(libdir, "$(libname).$(ext)")
    isfile(path) || continue
    stale_keys, stale_args = String[], String[]
    for (i, ln) in enumerate(eachline(path))
      s = strip(ln)
      (isempty(s) || startswith(s, "#")) && continue
      parts = split(s)
      key = String(parts[1])
      key == "*" && ext in ("optional", "byvalue", "funptrargs", "arrayargs") && continue
      if !haskey(args_of, key)
        push!(stale_keys, "$(key) (line $(i))")
      elseif ext != "native"
        for a in parts[2:end]
          safe_argname(String(a)) in args_of[key] || push!(stale_args, "$(key) $(a) (line $(i))")
        end
      end
    end
    isempty(stale_keys) ||
      @warn "$(libname).$(ext): $(length(stale_keys)) key(s) match no declared function (a typo, a removed API, or one newer than these headers):" stale_keys
    isempty(stale_args) ||
      @warn "$(libname).$(ext): $(length(stale_args)) argument name(s) the function does not have:" stale_args
  end
end
