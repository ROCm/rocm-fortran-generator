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
  "Per function with a table: whether it withholds the array forms (`fortran-arrays = false`)."
  no_arrays_by::Dict{String,Bool} = Dict{String,Bool}()
  "The scalar pointer arguments (`scalar-host`, `scalar-pointer-mode`, `scalar-device`), reclassified from buffer to scalar."
  scalar_ptrs::Dict{String,Set{String}} = Dict{String,Set{String}}()
  "The pointer-mode subset of `scalar_ptrs` (`scalar-pointer-mode`, and `scalar-device`)."
  ptrmode::Dict{String,Set{String}} = Dict{String,Set{String}}()
  "Buffers the _devptr twins take as type(c_ptr) (`devptr`)."
  devptr_arrays::Dict{String,Set{String}} = Dict{String,Set{String}}()
  "Typed pointers kept as an opaque c_ptr in the array overloads (`always-c-ptr`)."
  cptr_args::Dict{String,Set{String}} = Dict{String,Set{String}}()
  "Kernel-written scalars, which get no _typed form (`scalar-device`)."
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
express. One table per C function, whose keys are argument names. A key may
name several functions with
braces (`["hipsolver{S,D,C,Z}gebrd"]`); a function named twice is an error. A `_64`
or `_spt` variant without a table of its own takes its base's whole table.

    format = 1

    ["rocblas_{s,d,c,z}rotg"]
    a = "scalar-pointer-mode"
    b = "scalar-pointer-mode"

An argument the table does not name takes the default the C signature implies
(signature_defaults, apply_workspace_default). One it names takes one value, or a
list of values that answer different questions:

  What is it? (at most one; by default, what its C type and the defaults say)
    scalar-host            a pointer to one value, read or written on the host
    scalar-device          a pointer to one value in device memory (hipSOLVER's
                           devInfo): no form takes it as a host variable; not in
                           a batched routine (check_batched_device_scalars)
    scalar-pointer-mode    a pointer to one value, on the host or the device as
                           the handle's pointer mode says (<lib>_set_pointer_mode)
    buffer                 a data buffer, where a default would take it for a
                           pointer to one value
    struct-array           a pointer to a C struct that is an array, not one element
    function-pointer       a function pointer declared void*
  How is it passed? (at most one; by default, what its C type says)
    by-value               by value although its C type is a pointer
    by-reference           an array of pointers kept by reference, so a caller can
                           pass one pointer variable (arrays of pointers written
                           `T* x[]` or `T* const* x` are otherwise passed by value)
  Its rank in the Fortran array forms (at most one; by default 1, plus 1 when a
  leading dimension `ld*` follows it in _full_rank, plus 1 more in _strided_rank
  when a batch stride `stride*` follows it, its leading dimension or its increment):
    1d, 2d, 3d             that rank
    any-rank               the array forms take it at rank 0 to 3 (an FFT's data)
  Adjustments:
    nullable               the C API accepts NULL: OPTIONAL in Fortran
    always-c-ptr           a buffer that stays type(c_ptr) in the array forms too
                           (not for scalars, whose array forms have a _devptr twin)
    devptr                 a buffer the _devptr twins take as type(c_ptr): one a
                           caller may hold as a device pointer (an info or a result
                           per batch entry), as hipfort took them

A function gets array forms (F2008 per-rank, F2018 assumed-rank) when it has a
data buffer; `fortran-arrays = false` in its table withholds them.

The metadata has the last word over every default, the workspace names included
(apply_workspace_default). Values that make no sense together are an error here;
a value that does not apply to its C argument (a header that changed) is a
warning in check_metadata_applies, its entry ignored, or an error with
ROCM_FORTRAN_STRICT=1.
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
  "Arguments with `devptr`: the _devptr forms take them as type(c_ptr)."
  devptr::Dict{String,Set{String}}
  "Per function as parsed, the arguments whose entry the headers made inapplicable: ignored."
  ignored::Dict{String,Set{String}}
  "Argument rank in the array forms: 1, 2, 3, or ANY_RANK."
  dims::Dict{String,Dict{String,Int}}
  "Functions whose table sets `fortran-arrays = false`."
  no_arrays::Set{String}
  "Every function name with a table, after brace expansion => the table."
  tables::Dict{String,Dict{String,Any}}
  "Every function name with a table => the key it was written as."
  origin::Dict{String,String}
  path::String
end

const METADATA_FORMAT = 1
const ANY_RANK = -1
const KIND_VALUES = ("scalar-host", "scalar-device", "scalar-pointer-mode", "buffer",
                     "struct-array", "function-pointer")
const SCALAR_VALUES = ("scalar-host", "scalar-device", "scalar-pointer-mode")
const PASSING_VALUES = ("by-value", "by-reference")
const DIM_VALUES = Dict("1d" => 1, "2d" => 2, "3d" => 3, "any-rank" => ANY_RANK)
const ADJUST_VALUES = ("nullable", "always-c-ptr", "devptr")
const ARG_VALUES = (KIND_VALUES..., PASSING_VALUES..., "1d", "2d", "3d", "any-rank", ADJUST_VALUES...)
# Values that describe the whole argument: listed with another, it would be ignored.
const ALONE_VALUES = ("struct-array", "function-pointer", PASSING_VALUES..., "any-rank")

function empty_metadata(path::String="")
  d() = Dict{String,Set{String}}()
  Metadata(d(), d(), d(), d(), d(), d(), d(), d(), d(), d(), d(), Dict{String,Dict{String,Int}}(),
           Set{String}(), Dict{String,Dict{String,Any}}(), Dict{String,String}(), path)
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
  for (k, tbl) in t
    k == "format" && continue
    tbl isa AbstractDict || bad("`$(k)` must be a table, [$(k)]")
    names = try
      expand_braces(k)
    catch e
      bad("[$(k)]: $(sprint(showerror, e))")
    end
    for fn in names
      occursin(r"^[A-Za-z_][A-Za-z0-9_]*$", fn) ||
        bad("[$(k)] names `$(fn)`, which is not a C function name")
      haskey(md.origin, fn) && bad("`$(fn)` has two tables, [$(md.origin[fn])] and [$(k)]")
      md.origin[fn] = k
      md.tables[fn] = tbl
    end
  end
  for (fn, tbl) in md.tables
    # Errors name the key as written, braces included, so it can be found in the file.
    k = md.origin[fn]
    at = occursin(r"[{}]", k) ? "[\"$(k)\"]" : "[$(k)]"
    for (key, v) in tbl
      if key == "fortran-arrays"
        v === false || bad("$(at) fortran-arrays: only `false` is meaningful, not $(repr(v))")
        push!(md.no_arrays, fn)
        continue
      end
      vals = v isa AbstractString ? [v] : v isa AbstractVector ? v : bad("$(at) $(key): not a string or list")
      all(x -> x isa AbstractString && x in ARG_VALUES, vals) ||
        bad("$(at) $(key) = $(repr(v)): the values are $(join(ARG_VALUES, ", "))")
      allunique(vals) || bad("$(at) $(key) = $(repr(v)): a value is repeated")
      for (group, what) in ((KIND_VALUES, "what it is"), (PASSING_VALUES, "how it is passed"),
                            (Tuple(keys(DIM_VALUES)), "its rank"))
        count(in(group), vals) <= 1 ||
          bad("$(at) $(key) = $(repr(v)): more than one answer to $(what) ($(join(group, ", ")))")
      end
      "always-c-ptr" in vals && any(in(SCALAR_VALUES), vals) &&
        bad("$(at) $(key) = $(repr(v)): always-c-ptr applies to buffers; a scalar's array forms already have a _devptr twin taking it as type(c_ptr)")
      # The values below would be ignored, or would change another argument's forms.
      i = findfirst(in(ALONE_VALUES), vals)
      length(vals) > 1 && i !== nothing &&
        bad("$(at) $(key) = $(repr(v)): $(vals[i]) takes no other value")
      any(in(("1d", "2d", "3d")), vals) && any(x -> x in SCALAR_VALUES || x == "always-c-ptr", vals) &&
        bad("$(at) $(key) = $(repr(v)): a rank applies to a data buffer in the array forms")
      "devptr" in vals && any(in((SCALAR_VALUES..., "always-c-ptr", "nullable")), vals) &&
        bad("$(at) $(key) = $(repr(v)): devptr goes with a data buffer (the _devptr forms take pointer-mode and device scalars as type(c_ptr) already)")
      "nullable" in vals && any(in(("scalar-device", "buffer", "always-c-ptr", "1d", "2d", "3d")), vals) &&
        bad("$(at) $(key) = $(repr(v)): nullable applies to a pointer to one value (scalar-host, scalar-pointer-mode) or to one struct")
      # Store names in their emitted spelling (safe_argname, idempotent), since every
      # consumer compares against a.name; both `value` and `myValue` are accepted.
      a = safe_argname(String(key))
      for x in vals
        x in ("scalar-host", "scalar-device", "scalar-pointer-mode") && add!(md.scalar, fn, a)
        # A device scalar is also pointer-mode for the emitter: it keeps the c_ptr form.
        x in ("scalar-pointer-mode", "scalar-device") && add!(md.ptrmode, fn, a)
        x == "scalar-device"    && add!(md.devonly, fn, a)
        x == "always-c-ptr"     && add!(md.cptr, fn, a)
        x == "nullable"         && add!(md.optional, fn, a)
        x == "by-value"         && add!(md.byvalue, fn, a)
        x == "function-pointer" && add!(md.funptr, fn, a)
        x == "struct-array"     && add!(md.arrays, fn, a)
        x == "by-reference"     && add!(md.byref, fn, a)
        x == "devptr"           && add!(md.devptr, fn, a)
        haskey(DIM_VALUES, x)   && (get!(md.dims, fn, Dict{String,Int}())[a] = DIM_VALUES[x])
      end
    end
  end
  # Keys spell arguments as the C header does; the emitted spelling (myInfo for
  # info, block_ ...) is accepted, so a table copied from a module still works, but
  # reported, so the files stay greppable against the headers.
  to_c = Dict(v => k for (k, v) in DUMMY_RENAMES)
  c_name(a) = get(to_c, a, endswith(a, "_") && a[1:end-1] in KEYWORD_DUMMIES ? a[1:end-1] : nothing)
  emitted = sort!(unique(["[$(md.origin[fn])] $(k) (the C name is $(c_name(k)))"
                          for (fn, tbl) in md.tables for k in keys(tbl) if c_name(k) !== nothing]))
  isempty(emitted) ||
    @warn "$(basename(path)): $(length(emitted)) argument(s) named as the module spells them, not as the C header does:" emitted
  # A variant's own table replaces its base's entirely, which is easy to miss when
  # one key is added to a _64 table: say which of the base's keys it drops.
  masked = String[]
  for fn in sort!(collect(keys(md.tables)))
    for base in variant_chain(fn)[2:end]
      haskey(md.tables, base) || continue
      md.origin[base] == md.origin[fn] && break
      lost = setdiff(keys(md.tables[base]), keys(md.tables[fn]))
      isempty(lost) || push!(masked, "[$(md.origin[fn])] drops $(join(sort!(collect(lost)), ", ")) of [$(md.origin[base])]")
      break
    end
  end
  isempty(masked) ||
    @warn "$(basename(path)): $(length(masked)) variant table(s) replace their base's and drop some of its keys (repeat them, or name both with braces, x{,_64}):" masked
  # A function's own table replaces its base's entirely: give every table an entry,
  # empty where it says nothing, so meta_get stops there instead of falling back.
  for fn in keys(md.tables)
    for d in (md.scalar, md.ptrmode, md.devonly, md.cptr, md.optional, md.byvalue,
              md.funptr, md.arrays, md.byref, md.devptr)
      get!(d, fn, Set{String}())
    end
    get!(md.dims, fn, Dict{String,Int}())
  end
  return md
end

# Brace expansion of a table key, as in a shell: "rocblas_{s,d}dot" names
# rocblas_sdot and rocblas_ddot, and an empty alternative is allowed ("x{,_64}").
function expand_braces(k::AbstractString) :: Vector{String}
  i = findfirst('{', k)
  if i === nothing
    occursin('}', k) && throw(ArgumentError("unbalanced braces"))
    return [String(k)]
  end
  j = findnext('}', k, i)
  j === nothing && throw(ArgumentError("unbalanced braces"))
  inner = k[nextind(k, i):prevind(k, j)]
  occursin('{', inner) && throw(ArgumentError("nested braces"))
  occursin(',', inner) || throw(ArgumentError("braces with one alternative"))
  head, tail = k[1:prevind(k, i)], k[nextind(k, j):end]
  return [x for alt in split(inner, ',') for x in expand_braces(head * alt * tail)]
end

# A variant without a table of its own takes its base function's: an _spt
# (per-thread default stream) variant first that of the same function without
# _spt, then an ILP64 _64 variant that of the 32-bit one. A _v2 is a new API, not a
# variant: it inherits nothing.
variant_chain(name) = unique([name, replace(name, r"_spt$" => ""),
                              replace(replace(name, r"_spt$" => ""), r"_64$" => "")])
variant_base(name) = last(variant_chain(name))
function meta_get(d, name, default)
  for n in variant_chain(name)
    haskey(d, n) && return d[n]
  end
  return default
end
# The table that applies to `name`, and the name it belongs to; nothing if none.
function applying_table(md::Metadata, name)
  for n in variant_chain(name)
    haskey(md.tables, n) && return (n, md.tables[n])
  end
  return nothing
end

imposed_dims(f::FuncInfo, meta::LibMeta) = meta_get(meta.dims, f.name, Dict{String,Int}())
withheld(f::FuncInfo, meta::LibMeta) = meta_get(meta.no_arrays_by, f.name, false)
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

# Argument-passing overrides the C headers cannot express.
#   by-value          force `, value`: HIP's `void** extra` passed by reference
#                     sends the address of a NULL variable, never NULL, and HIP
#                     rejects the launch (kernelParams, same C type, is by reference).
#   function-pointer  type(c_funptr), value for function pointers declared void*.
#   nullable          nullable by-reference scalar (c_null_ptr by reference is not
#                     NULL; OPTIONAL in bind(C) needs F2018 18.3.6): bind(C) takes
#                     type(c_ptr),value, the module procedures take it OPTIONAL
#                     (see wants_opt).
#   struct-array      pointer to an emitted derived type is an array, `type(T) :: x(*)`.
#   by-reference      an array of pointers stays `type(c_ptr)` by reference
#                     (rocfft_execute).
function apply_arg_overrides(funcs::Vector{FuncInfo}, md::Metadata) :: Vector{FuncInfo}
  byval, funptr, opt, arrs, refs = md.byvalue, md.funptr, md.optional, md.arrays, md.byref
  libname = replace(basename(md.path), r"\.toml$" => "")
  all(isempty, (byval, funptr, opt, arrs, refs)) && return funcs
  # A _64 or _spt variant without a table takes its base's, as in apply_argkinds.
  names(d, f) = meta_get(d, f.name, EMPTY_STRSET)
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
        push!(rejected, "$(f.name) $(a.name) (by-reference: not an array of pointers)")
      end
      a.name in v && return ArgInfo(a.name, a.ftype, ", value", a.is_string)
      if a.name in r
        startswith(a.ftype, "type(") && a.suffix == "" &&
          return ArgInfo(a.name, a.ftype, "(*)", a.is_string)
        push!(rejected, "$(f.name) $(a.name) (struct-array: not a pointer to an emitted struct)")
      end
      if a.name in o
        a.suffix == "" && return ArgInfo(a.name, a.ftype, ", optional", a.is_string)
        push!(rejected, "$(f.name) $(a.name) (nullable: not a pointer to one value or struct)")
      end
      return a
    end
    push!(out, FuncInfo(f.name, f.ret_ftype, f.is_void, ArgInfo[override(a) for a in f.args]))
  end
  isempty(rejected) ||
    metadata_report("$(libname).toml: $(length(rejected)) value(s) that do not apply, ignored: " * join(rejected, ", "))
  return out
end

# Scalar pointer arguments (`scalar-host`, `scalar-pointer-mode`, `scalar-device`)
# stay type(c_ptr),value in the bind(C) specific, so device pointer mode and NULL
# remain expressible, and get their natural Fortran type in a _typed module
# procedure of the same generic. `scalar-pointer-mode` names those governed by
# <lib>_set_pointer_mode; a routine that mixes them with host-only scalars also
# gets a _devptr form. `scalar-device` names kernel-written scalars (hipSOLVER's
# devInfo), which get no _typed form.
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
    # Flag only unambiguous scalar names (c/s/tau depend on the routine), in a
    # function with a table too: one that lists alpha may forget beta.
    named = named_args(md, f)
    any(a -> a.suffix == "(*)" && occursin(r"^(alpha|beta|alphai|betai)$"i, a.name) &&
             !(a.name in something(sset, EMPTY_STRSET)) && !(a.name in named) &&
             !(a.name in meta_get(md.cptr, f.name, EMPTY_STRSET)), f.args) &&
      push!(uncovered, f.name)
    sset === nothing && (push!(out, f); continue)
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
  if !isempty(byvalue)
    metadata_report("struct passed or returned by value but not emitted, so no Fortran type matches its ABI; " *
                    "the functions are left out (emit the struct with keep_structs): " * join(byvalue, ", "))
    omit = Set(first(split(b, r"[( ]")) for b in byvalue)
    funcs = [f for f in funcs if !(f.name in omit)]
  end
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
only its _64 or _spt variant is declared. Run on the functions as parsed, before any
metadata applies.
"""
function check_metadata_names(funcs::Vector{FuncInfo}, md::Metadata)
  isempty(md.tables) && return
  args_of = Dict{String,Set{String}}()
  for f in funcs
    for n in variant_chain(f.name)
      union!(get!(args_of, n, Set{String}()), (a.name for a in f.args))
    end
  end
  stale_keys, stale_args = String[], String[]
  for fn in sort!(collect(keys(md.tables)))
    k = md.origin[fn]
    where = k == fn ? fn : "$(fn) (from [$(k)])"
    if !haskey(args_of, fn)
      push!(stale_keys, where)
      continue
    end
    for a in sort!(collect(keys(md.tables[fn])))
      a == "fortran-arrays" && continue
      safe_argname(a) in args_of[fn] || push!(stale_args, "$(where) $(a)")
    end
  end
  file = basename(md.path)
  isempty(stale_keys) ||
    @warn "$(file): $(length(stale_keys)) table(s) match no declared function (a typo, a removed API, or one newer than these headers):" stale_keys
  isempty(stale_args) ||
    @warn "$(file): $(length(stale_args)) argument name(s) the function does not have:" stale_args
end

# A batch count argument: the routine works on that many problems.
is_batch_count(name) = occursin(r"^batch_?(count|size)$"i, name)

"""
    check_batched_device_scalars(funcs, md)

Stop on a `scalar-device` argument of a function that has a batch count: a value
the kernel writes in such a routine is one per batch entry (hipSOLVER's and
hipBLAS's batched devInfo), an array, and the C signature cannot tell it from one
value. Host and pointer-mode scalars of batched routines are legitimate (`alpha`,
shared by every batch entry; `lwork` of a size query). Run on the functions as
parsed, before any metadata applies.
"""
function check_batched_device_scalars(funcs::Vector{FuncInfo}, md::Metadata)
  isempty(md.devonly) && return
  bad = String[]
  drop = Tuple{String,String}[]
  for f in funcs
    any(a -> is_batch_count(a.name), f.args) || continue
    dev = meta_get(md.devonly, f.name, EMPTY_STRSET)
    for a in f.args
      a.name in dev && (push!(bad, "$(f.name) $(a.name)"); push!(drop, (f.name, a.name)))
    end
  end
  isempty(bad) && return
  # Reported first: strict, the generation stops with the metadata untouched.
  report_and_ignore!(md, drop, "$(basename(md.path)): scalar-device in a batched routine, where a kernel-written value is " *
                  "one per batch entry, an array; the entries are ignored, so they bind as buffers " *
                  "(fix them: no entry, or devptr): " * join(bad, ", "))
  return nothing
end

"""
    check_metadata_applies(funcs, md)

Stop on a value that does not apply to the C argument it names, which would
otherwise be ignored silently or change nothing: `always-c-ptr` or a rank on what
is not a data buffer (a handle, a `void*`, a workspace the generator already keeps
type(c_ptr)), a `scalar-*` on what is not a pointer to a value, `by-reference` on
what is not an array of pointers, and so on. Run on the functions as parsed,
before any metadata applies; names the function lacks are check_metadata_names'.
"""
function check_metadata_applies(funcs::Vector{FuncInfo}, md::Metadata)
  isempty(md.tables) && return
  bad = String[]
  drop = Tuple{String,String}[]
  for f in funcs
    hit = applying_table(md, f.name)
    hit === nothing && continue
    fn, tbl = hit
    byname = Dict(a.name => a for a in f.args)
    for (key, v) in tbl
      key == "fortran-arrays" && continue
      a = get(byname, safe_argname(String(key)), nothing)
      a === nothing && continue
      vals = v isa AbstractString ? [v] : v
      whys = [(x, w) for x in vals for w in (value_misfit(x, a, vals),) if w !== nothing]
      isempty(whys) && continue
      for (x, w) in whys; push!(bad, "$(f.name) $(key) = \"$(x)\" ($(w))"); end
      push!(drop, (f.name, a.name))
    end
  end
  isempty(bad) && return
  report_and_ignore!(md, drop, "$(basename(md.path)): $(length(bad)) value(s) that do not apply to the C argument " *
                  "(a header that changed, or a variant that inherits a table): their entries are ignored, " *
                  "so these arguments bind as their C declaration says; fix or remove them: " * join(bad, ", "))
  return nothing
end

# Why value `x` does not apply to the parsed argument `a`, or nothing.
function value_misfit(x, a::ArgInfo, vals)
  ptr_to_value = a.suffix == "(*)"
  if x in ("buffer", "devptr", "always-c-ptr", "1d", "2d", "3d", "any-rank")
    is_buffer(a) || return "not a data buffer: already type(c_ptr) or not a pointer"
  elseif startswith(x, "scalar-")
    ptr_to_value || return "not a pointer to a value"
  elseif x == "nullable"
    (a.suffix == "" || (ptr_to_value && any(startswith("scalar-"), vals))) ||
      return "not a pointer to one value or struct"
  elseif x == "struct-array"
    (startswith(a.ftype, "type(") && a.suffix == "") || return "not a pointer to a struct"
  elseif x == "by-reference"
    (a.ftype == "type(c_ptr)" && a.suffix == ", value") || return "not an array of pointers"
  elseif x == "by-value"
    a.suffix == ", value" && return "already passed by value"
  elseif x == "function-pointer"
    a.ftype == "type(c_ptr)" || return "not a void*"
  end
  return nothing
end

# A typed pointer named like a workspace (is_workspace_name) is type(c_ptr), value,
# unless the function's table names it: the metadata overrides every guess.
function apply_workspace_default(funcs::Vector{FuncInfo}, md::Metadata) :: Vector{FuncInfo}
  map(funcs) do f
    hit = applying_table(md, f.name)
    named = hit === nothing ? EMPTY_STRSET : Set{String}(safe_argname(String(k)) for k in keys(hit[2]))
    ws(a) = a.suffix == "(*)" && is_workspace_name(a.name) && !(a.name in named)
    any(ws, f.args) || return f
    FuncInfo(f.name, f.ret_ftype, f.is_void,
             ArgInfo[ws(a) ? ArgInfo(a.name, "type(c_ptr)", ", value", a.is_string) : a for a in f.args])
  end
end

# ---------------------------------------------------------------------------
# Defaults from the C signature. An argument the function's table does not name
# is classified by these rules, which read the function's name shape and each
# argument's C type and position, never the argument's name alone (except alpha
# and beta under pointer_mode). An entry in the table always wins; `buffer` keeps
# a pointer the rules would take for a scalar a data buffer.
#
#   size query  a *_buffer_size / *bufferSize* routine: its last integer output,
#               and every size_t output, are scalar-host (lwork, buffer_size)
#   getter      a *_get_* / *Get* routine without a by-value integer (which would
#               index into something): its integer and enum outputs are scalar-host
#   solver info in a library with [library] solver_info_handles, a routine whose
#               first argument is such a handle: its last argument (before the batch
#               count that ends a batched routine), an integer output, is the info
#               the kernel writes, scalar-device; a buffer with devptr when the
#               routine has a batch count (one per batch entry)
#   alpha, beta in a library with [library] pointer_mode = true: a const pointer
#               named alpha or beta is scalar-pointer-mode
# ---------------------------------------------------------------------------

const SIZE_QUERY_NAME = r"_buffer_size|[Bb]uffer[Ss]ize"
const GETTER_NAME     = r"_get(_|$)|Get"

Base.@kwdef struct DefaultRules
  pointer_mode::Bool = false
  solver_handles::Set{String} = Set{String}()
end
DefaultRules(cfg::Dict) =
  DefaultRules(pointer_mode = get(cfg["library"], "pointer_mode", false),
               solver_handles = Set{String}(get(cfg["library"], "solver_info_handles", String[])))

# The pointee of `a` is const: `const T *`, not `T *const`.
const_pointee(a::ArgInfo) =
  (i = findlast('*', a.ctype)) !== nothing && occursin(r"\bconst\b", a.ctype[1:prevind(a.ctype, i)])
int_output(a::ArgInfo) = a.suffix == "(*)" && startswith(a.ftype, "integer(") && !const_pointee(a)

"""
    signature_defaults(f, rules) -> Dict(argument => (value, rule))

The classification the C signature implies for `f`'s arguments, as parsed (before
any metadata applies). Every argument is considered; the caller drops those the
table names.
"""
function signature_defaults(f::FuncInfo, rules::DefaultRules)
  d = Dict{String,Tuple{String,String}}()
  outs = [a for a in f.args if int_output(a)]
  if occursin(SIZE_QUERY_NAME, f.name)
    isempty(outs) || (d[last(outs).name] = ("scalar-host", "size query: its last integer output"))
    for a in outs
      a.ftype == "integer(c_size_t)" && (d[a.name] = ("scalar-host", "size query: a size_t output"))
    end
  elseif occursin(GETTER_NAME, f.name)
    if !any(a -> a.suffix == ", value" && startswith(a.ftype, "integer("), f.args)
      for a in outs; d[a.name] = ("scalar-host", "getter: an integer or enum output"); end
    end
  elseif !isempty(f.args) && first(f.args).ctype in rules.solver_handles
    # The info comes last, or just before the batch count that ends a batched routine.
    a = length(f.args) >= 2 && is_batch_count(last(f.args).name) ? f.args[end-1] : last(f.args)
    if int_output(a)
      d[a.name] = any(x -> is_batch_count(x.name), f.args) ?
        ("devptr", "solver: its last integer output, one info per batch entry, a buffer") :
        ("scalar-device", "solver: its last integer output, the info the kernel writes")
    end
  end
  if rules.pointer_mode
    for a in f.args
      a.name in ("alpha", "beta") && a.suffix == "(*)" && const_pointee(a) &&
        (d[a.name] = ("scalar-pointer-mode", "pointer mode: a const alpha or beta"))
    end
  end
  return d
end

# The arguments of `f` its applying table names, in their emitted spelling.
named_args(md::Metadata, f::FuncInfo) =
  (hit = applying_table(md, f.name); hit === nothing ? EMPTY_STRSET :
   setdiff(Set{String}(safe_argname(String(k)) for k in keys(hit[2])),
           get(md.ignored, f.name, EMPTY_STRSET)))

"""
    apply_signature_defaults!(md, funcs, rules)

Add to `md`, per function, the signature defaults of the arguments its table does
not name, and warn about table entries that only repeat a default. Run on the
functions as parsed, before any metadata applies.
"""
function apply_signature_defaults!(md::Metadata, funcs::Vector{FuncInfo}, rules::DefaultRules)
  repeated = Set{String}()
  for f in funcs
    d = signature_defaults(f, rules)
    isempty(d) && continue
    hit = applying_table(md, f.name)
    named = named_args(md, f)
    if hit !== nothing
      for (key, v) in hit[2]
        a = safe_argname(String(key))
        a in get(md.ignored, f.name, EMPTY_STRSET) && continue
        haskey(d, a) && (v == first(d[a]) || v == [first(d[a])]) &&
          push!(repeated, "[$(md.origin[hit[1]])] $(key) ($(last(d[a])))")
      end
    end
    filter!(p -> !(first(p) in named), d)
    isempty(d) && continue
    for (dict, kinds) in ((md.scalar, SCALAR_VALUES),
                          (md.ptrmode, ("scalar-pointer-mode", "scalar-device")),
                          (md.devonly, ("scalar-device",)),
                          (md.devptr, ("devptr",)))
      s = copy(meta_get(dict, f.name, EMPTY_STRSET))
      for (a, (v, _)) in d; v in kinds && push!(s, a); end
      dict[f.name] = s
    end
  end
  isempty(repeated) ||
    @warn "$(basename(md.path)): $(length(repeated)) entr(y/ies) only repeat the default from the C signature; remove them:" sort!(collect(repeated))
  return md
end

"""
    explain_defaults(f, md, rules) -> Vector{String}

What the C signature of `f` (as parsed) decides beyond its table, in argument order,
for `explain_metadata.jl`: each argument the table does not name and a signature
default classifies, as `name = "value"   (default: <rule>)`; each workspace-named
typed pointer, as `name   (default: workspace, type(c_ptr))`; and, for an argument
the table names, whether it overrides or only repeats such a default.
"""
function explain_defaults(f::FuncInfo, md::Metadata, rules::DefaultRules)
  d = signature_defaults(f, rules)
  hit = applying_table(md, f.name)
  table = hit === nothing ? Dict{String,Any}() :
          Dict{String,Any}(safe_argname(String(k)) => v for (k, v) in hit[2])
  shown(v) = v isa AbstractVector ? "[" * join(repr.(v), ", ") * "]" : repr(v)
  lines = String[]
  for a in f.args
    ws = a.suffix == "(*)" && is_workspace_name(a.name)
    if haskey(table, a.name)
      v = table[a.name]
      if haskey(d, a.name)
        (val, rule) = d[a.name]
        push!(lines, v == val || v == [val] ?
          "$(a.name): the table only repeats the default \"$(val)\" ($(rule)); remove it" :
          "$(a.name): the table ($(shown(v))) overrides the default \"$(val)\" ($(rule))")
      elseif ws
        push!(lines, "$(a.name): the table ($(shown(v))) overrides the default (workspace, type(c_ptr))")
      end
    elseif haskey(d, a.name)
      (val, rule) = d[a.name]
      push!(lines, "$(a.name) = \"$(val)\"   (default: $(rule))")
    elseif ws
      push!(lines, "$(a.name)   (default: workspace, type(c_ptr))")
    end
  end
  return lines
end

# ROCM_FORTRAN_STRICT=1 turns the reports of what the headers made inapplicable
# into errors: for working on the metadata, or a CI that keeps it clean. Without
# it the generation goes on, so new or changed headers never stop it.
metadata_strict() = lowercase(get(ENV, "ROCM_FORTRAN_STRICT", "")) in ("1", "true", "yes")
function metadata_report(msg::AbstractString)
  metadata_strict() && error("ROCM_FORTRAN_STRICT: " * msg)
  @warn msg
end

# Ignore the entry of argument `a` (emitted name) for function `fn` as parsed: the
# table stays as written for the other functions it names or passes on.
function ignore_entry!(md::Metadata, fn::AbstractString, a::AbstractString)
  push!(get!(md.ignored, fn, Set{String}()), a)
  for d in (md.scalar, md.ptrmode, md.devonly, md.cptr, md.optional, md.byvalue,
            md.funptr, md.arrays, md.byref, md.devptr)
    s = meta_get(d, fn, nothing)
    (s === nothing || !(a in s)) && continue
    d[fn] = setdiff(s, [a])
  end
  dm = meta_get(md.dims, fn, nothing)
  (dm !== nothing && haskey(dm, a)) && (md.dims[fn] = (c = copy(dm); delete!(c, a); c))
  return md
end
function report_and_ignore!(md::Metadata, drop, msg::AbstractString)
  metadata_report(msg)
  for (fn, a) in drop; ignore_entry!(md, fn, a); end
end
