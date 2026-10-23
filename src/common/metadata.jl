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

# Loader and appliers of the per-library metadata file (metadata/<lib>.toml), and
# LibMeta.

const EMPTY_STRSET = Set{String}()

"""
The per-library metadata the emitters consume, built once by gen_files
(assemble.jl) from the metadata files, the TOML and the parsed headers.
Function-keyed entries map a C function name to argument names.
"""
Base.@kwdef struct LibMeta
  "Argument rank in the array forms, where the metadata imposes one (1d/2d/3d/any-rank)."
  dims::Dict{String,Dict{String,Int}} = Dict{String,Dict{String,Int}}()
  "Functions withheld from the array forms (`fortran-arrays = false`)."
  no_arrays::Set{String} = Set{String}()
  "The scalar pointer arguments (`scalar`, `ptrmode`, `device`), reclassified from buffer to scalar."
  scalar_ptrs::Dict{String,Set{String}} = Dict{String,Set{String}}()
  "The pointer-mode subset of `scalar_ptrs` (`ptrmode`, and `device`)."
  ptrmode::Dict{String,Set{String}} = Dict{String,Set{String}}()
  "Typed pointers kept as an opaque c_ptr in the array overloads (`opaque`)."
  cptr_args::Dict{String,Set{String}} = Dict{String,Set{String}}()
  "Kernel-written scalars, which get no _typed form (`device`)."
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

"""
The metadata file of one library, metadata/<lib>.toml: what its C headers cannot
express. One table per C function (an ILP64 `_64` or `_v2` variant inherits its
base function's table), whose keys are argument names, plus a `["*"]` table that
applies to every function.

    format = 1

    [hipblasSgemv]
    alpha = "scalar-host-or-device"
    beta  = "scalar-host-or-device"

An argument takes one value, or a list of values that answer different questions:

  What is it? (at most one; by default, what its C type says)
    scalar-host            a pointer to one value, read or written on the host
    scalar-device          a pointer to one value in device memory (hipSOLVER's
                           devInfo): no form takes it as a host variable
    scalar-host-or-device  a pointer to one value, on the host or the device as
                           the handle's pointer mode says
    struct-array           a pointer to a C struct that is an array, not one element
    function-pointer       a function pointer declared void*
  How is it passed? (at most one; by default, what its C type says)
    by-value               by value although its C type is a pointer
    by-reference           an array of pointers kept by reference, so a caller can
                           pass one pointer variable (arrays of pointers written
                           `T* x[]` or `T* const* x` are otherwise passed by value)
  Its rank in the Fortran array forms (at most one; by default 1, plus 1 when a
  leading dimension `ld*` follows it, plus 1 when a batch stride `stride*` does):
    1d, 2d, 3d             that rank
    any-rank               the array forms take it at rank 0 to 3 (an FFT's data)
  Adjustments:
    nullable               the C API accepts NULL: OPTIONAL in Fortran
    always-c-ptr           stays type(c_ptr) in the array forms too (a workspace,
                           an output in device pointer mode)

A function gets array forms (F2008 per-rank, F2018 assumed-rank) when it has a
data buffer; `fortran-arrays = false` in its table withholds them.
"""
struct Metadata
  scalar::Dict{String,Set{String}}
  ptrmode::Dict{String,Set{String}}
  devonly::Dict{String,Set{String}}
  cptr::Dict{String,Set{String}}
  optional::Dict{String,Set{String}}
  byvalue::Dict{String,Set{String}}
  funptr::Dict{String,Set{String}}
  arrays::Dict{String,Set{String}}
  byref::Dict{String,Set{String}}
  "Argument rank in the array forms: 1, 2, 3, or ANY_RANK."
  dims::Dict{String,Dict{String,Int}}
  "Functions whose table sets `fortran-arrays = false`."
  no_arrays::Set{String}
  path::String
end

const METADATA_FORMAT = 1
const ANY_RANK = -1
const KIND_VALUES = ("scalar-host", "scalar-device", "scalar-host-or-device",
                     "struct-array", "function-pointer")
const PASSING_VALUES = ("by-value", "by-reference")
const DIM_VALUES = Dict("1d" => 1, "2d" => 2, "3d" => 3, "any-rank" => ANY_RANK)
const ADJUST_VALUES = ("nullable", "always-c-ptr")
const ARG_VALUES = (KIND_VALUES..., PASSING_VALUES..., "1d", "2d", "3d", "any-rank", ADJUST_VALUES...)
# How a C argument is passed, which [\"*\"] may set for every function.
const STAR_VALUES = ("struct-array", "function-pointer", PASSING_VALUES..., "nullable")

function empty_metadata(path::String="")
  d() = Dict{String,Set{String}}()
  Metadata(d(), d(), d(), d(), d(), d(), d(), d(), d(), Dict{String,Dict{String,Int}}(),
           Set{String}(), path)
end

# Read metadata/<lib>.toml; a missing or empty file is empty metadata. Malformed
# content is an error rather than a warning, since a misspelled value would
# otherwise be dropped and change the binding silently.
function load_metadata(path::String) :: Metadata
  md = empty_metadata(path)
  isfile(path) || return md
  t = TOML.parsefile(path)
  bad(msg) = error("$(basename(path)): $(msg)")
  # An empty file, or one with only comments, is no metadata; `format` is required
  # as soon as there is an entry.
  isempty(t) && return md
  fmt = get(t, "format", nothing)
  fmt == METADATA_FORMAT || bad("`format = $(METADATA_FORMAT)` is required, found $(repr(fmt))")
  add!(d, fn, a) = push!(get!(d, fn, Set{String}()), a)
  for (fn, tbl) in t
    fn == "format" && continue
    tbl isa AbstractDict || bad("`$(fn)` must be a table, [$(fn)]")
    for (key, v) in tbl
      if key == "fortran-arrays"
        fn == "*" && bad("[\"*\"] cannot set fortran-arrays")
        v === false || bad("[$(fn)] fortran-arrays: only `false` is meaningful, not $(repr(v))")
        push!(md.no_arrays, fn)
        continue
      end
      vals = v isa AbstractString ? [v] : v isa AbstractVector ? v : bad("[$(fn)] $(key): not a string or list")
      all(x -> x isa AbstractString && x in ARG_VALUES, vals) ||
        bad("[$(fn)] $(key) = $(repr(v)): the values are $(join(ARG_VALUES, ", "))")
      allunique(vals) || bad("[$(fn)] $(key) = $(repr(v)): a value is repeated")
      for (group, what) in ((KIND_VALUES, "what it is"), (PASSING_VALUES, "how it is passed"),
                            (Tuple(keys(DIM_VALUES)), "its rank"))
        count(in(group), vals) <= 1 ||
          bad("[$(fn)] $(key) = $(repr(v)): more than one answer to $(what) ($(join(group, ", ")))")
      end
      fn == "*" && !all(in(STAR_VALUES), vals) &&
        bad("[\"*\"] $(key) = $(repr(v)): only $(join(STAR_VALUES, ", ")) apply to every function")
      # Store names in their emitted spelling (safe_argname, idempotent), since every
      # consumer compares against a.name; both `value` and `myValue` are accepted.
      a = safe_argname(String(key))
      for x in vals
        x in ("scalar-host", "scalar-device", "scalar-host-or-device") && add!(md.scalar, fn, a)
        # A device scalar is also pointer-mode for the emitter: it keeps the c_ptr form.
        x in ("scalar-host-or-device", "scalar-device") && add!(md.ptrmode, fn, a)
        x == "scalar-device"    && add!(md.devonly, fn, a)
        x == "always-c-ptr"     && add!(md.cptr, fn, a)
        x == "nullable"         && add!(md.optional, fn, a)
        x == "by-value"         && add!(md.byvalue, fn, a)
        x == "function-pointer" && add!(md.funptr, fn, a)
        x == "struct-array"     && add!(md.arrays, fn, a)
        x == "by-reference"     && add!(md.byref, fn, a)
        haskey(DIM_VALUES, x)   && (get!(md.dims, fn, Dict{String,Int}())[a] = DIM_VALUES[x])
      end
    end
  end
  return md
end

# -1 means no array overloads.
# An ILP64 (_64) or _v2 variant inherits its base function's entry in every
# per-function metadata file, so the base name is curated once for all of them.
# _spt (per-thread default stream) first: hipStreamGetCaptureInfo_v2_spt takes the
# table of hipStreamGetCaptureInfo_v2, whose arguments differ from the unversioned one.
variant_base(name) = replace(name, r"(_v2)?(_64)?(_spt)?$" => "")
function meta_get(d, name, default)
  haskey(d, name) && return d[name]
  n = replace(name, r"_spt$" => "")
  haskey(d, n) && return d[n]
  return get(d, variant_base(name), default)
end

imposed_dims(f::FuncInfo, meta::LibMeta) = meta_get(meta.dims, f.name, Dict{String,Int}())
withheld(f::FuncInfo, meta::LibMeta) = f.name in meta.no_arrays || variant_base(f.name) in meta.no_arrays
# The rank_N array forms go up to rank 1, or to 3 when a buffer is any-rank (an
# FFT's data, whose rank the plan decides); -1 means no array forms.
function native_maxrank(f::FuncInfo, meta::LibMeta)
  (withheld(f, meta) || !func_has_buffer(f, meta)) && return -1
  return ANY_RANK in values(imposed_dims(f, meta)) ? 3 : 1
end
# The _full_rank form gives every buffer its natural rank (arg_natural_rank); it is
# emitted when one of them is above 1, and not beside the rank 0-3 forms of an
# any-rank function, which already cover them.
wants_fullrank(f::FuncInfo, meta::LibMeta) = native_maxrank(f, meta) == 1

# Argument-passing overrides the C headers cannot express; the `["*"]` table
# applies to every function.
#   value     force `, value`: HIP's `void** extra` passed by reference sends the
#             address of a NULL variable, never NULL, and HIP rejects the launch
#             (kernelParams, same C type, is by reference).
#   funptr    type(c_funptr), value for function pointers declared void*.
#   optional  nullable by-reference scalar (c_null_ptr by reference is not NULL;
#             OPTIONAL in bind(C) needs F2018 18.3.6): bind(C) takes
#             type(c_ptr),value, the module procedures take it OPTIONAL (see wants_opt).
#   array     pointer to an emitted derived type is an array, `type(T) :: x(*)`.
#   ref       an array of pointers stays `type(c_ptr)` by reference (rocfft_execute).
function apply_arg_overrides(funcs::Vector{FuncInfo}, md::Metadata) :: Vector{FuncInfo}
  byval, funptr, opt, arrs, refs = md.byvalue, md.funptr, md.optional, md.arrays, md.byref
  libname = replace(basename(md.path), r"\.toml$" => "")
  all(isempty, (byval, funptr, opt, arrs, refs)) && return funcs
  names(d, f) = union(get(d, f.name, Set{String}()), get(d, "*", Set{String}()))
  out = FuncInfo[]
  rejected = String[]
  for f in funcs
    v, p, o, r = names(byval, f), names(funptr, f), names(opt, f), names(arrs, f)
    b = names(refs, f)
    all(isempty, (v, p, o, r, b)) && (push!(out, f); continue)
    function override(a)
      a.name in p && return ArgInfo(a.name, "type(c_funptr)", ", value", a.is_string)
      if a.name in b
        a.ftype == "type(c_ptr)" && a.suffix == ", value" && return ArgInfo(a.name, a.ftype, "", a.is_string)
        push!(rejected, "$(f.name) $(a.name) (ref: not an array of pointers)")
      end
      a.name in v && return ArgInfo(a.name, a.ftype, ", value", a.is_string)
      if a.name in r
        startswith(a.ftype, "type(") && a.suffix == "" &&
          return ArgInfo(a.name, a.ftype, "(*)", a.is_string)
        push!(rejected, "$(f.name) $(a.name) (array: not a derived-type pointer)")
      end
      if a.name in o
        a.suffix == "" && return ArgInfo(a.name, a.ftype, ", optional", a.is_string)
        push!(rejected, "$(f.name) $(a.name) (optional: not a by-reference scalar)")
      end
      return a
    end
    push!(out, FuncInfo(f.name, f.ret_ftype, f.is_void, ArgInfo[override(a) for a in f.args]))
  end
  isempty(rejected) || @warn "$(libname): $(length(rejected)) argument override(s) ignored:" rejected
  return out
end

# Scalar pointer arguments (`scalar`, `ptrmode`, `device`) stay type(c_ptr),value in
# the bind(C) specific, so device pointer mode and NULL remain expressible, and get
# their natural Fortran type in a _typed module procedure of the same generic.
# `ptrmode` names those governed by <lib>_set_pointer_mode; a routine that mixes
# them with host-only scalars also gets a _devptr form. `device` names
# kernel-written scalars (hipSOLVER's devInfo), which get no _typed form.
# _typed must be a module procedure: two bind(C) specifics sharing one binding
# label are forbidden by F2018 19.2.

# Turn the scalar pointer arguments from `x(*)` into scalars (suffix "").
# Also returns, per function, the arguments so reclassified (LibMeta.scalar_ptrs,
# so the generic can also offer the type(c_ptr) form for device pointer mode) and
# their pointer-mode subset (LibMeta.ptrmode).
function apply_argkinds(funcs::Vector{FuncInfo}, md::Metadata)
  scalars, ptrmode_file = md.scalar, md.ptrmode
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
    @info "metadata: $(length(uncovered)) function(s) with scalar-looking args not classified (curate $(basename(md.path))):" uncovered
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

"""
    check_metadata_names(funcs, md)

Warn about every metadata entry that matches nothing, which would otherwise be
ignored silently: a function table no declared function has (a typo, or an API
removed), and an argument name the function does not have. A table is valid when
only its _64/_v2 variant is declared. Run on the functions as parsed, before any
metadata applies.
"""
function check_metadata_names(funcs::Vector{FuncInfo}, md::Metadata)
  isfile(md.path) || return
  args_of = Dict{String,Set{String}}()
  for f in funcs
    for n in (f.name, variant_base(f.name))
      union!(get!(args_of, n, Set{String}()), (a.name for a in f.args))
    end
  end
  t = TOML.parsefile(md.path)
  stale_keys, stale_args = String[], String[]
  for fn in sort!(collect(keys(t)))
    (fn == "format" || fn == "*") && continue
    if !haskey(args_of, fn)
      push!(stale_keys, fn)
      continue
    end
    for a in sort!(collect(keys(t[fn])))
      a == "fortran-arrays" && continue
      safe_argname(a) in args_of[fn] || push!(stale_args, "$(fn) $(a)")
    end
  end
  file = basename(md.path)
  isempty(stale_keys) ||
    @warn "$(file): $(length(stale_keys)) table(s) match no declared function (a typo, a removed API, or one newer than these headers):" stale_keys
  isempty(stale_args) ||
    @warn "$(file): $(length(stale_args)) argument name(s) the function does not have:" stale_args
end
