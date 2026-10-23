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

# The single place that chooses between the F2018 assumed-rank tier and the F2008
# per-rank tier, so the `module procedure` list and the wrapper bodies in
# `contains` can never name different tiers. Assumed-rank wins when both macros
# are defined: a `dimension(..)` dummy matches every rank, so the two tiers cannot
# coexist in one generic without making every call ambiguous.
#
# per_rank_is_default=false: the per-rank arm carries its own
# `#ifdef USE_ASSUMED_SHAPE`, so a build with neither macro gets nothing (needed in
# the unconditional `interface` region). true: the per-rank arm is the plain
# `#else`, for regions already inside emit_either_tier's outer `#if`.
#
# A tier fixed at generation time (ROCM_FORTRAN_ARRAY_INTERFACES) is emitted with
# no #ifdef; :none emits nothing. `mode` is a parameter only for the unit tests.
function emit_tier_guard(io, emit_assumed_rank, emit_per_rank;
                         per_rank_is_default::Bool = false,
                         mode::Symbol = ARRAY_IFACES)
  if mode === :assumed_rank
    emit_assumed_rank(io)
    return
  elseif mode === :assumed_shape
    emit_per_rank(io)
    return
  elseif mode === :none
    return
  end
  println(io, "#ifdef USE_ASSUMED_RANK")
  emit_assumed_rank(io)
  println(io, "#else")
  per_rank_is_default || println(io, "#ifdef USE_ASSUMED_SHAPE")
  emit_per_rank(io)
  per_rank_is_default || println(io, "#endif")
  println(io, "#endif")
end

# A region both tiers need and a build with neither macro must not see (overloads
# with no assumed-rank counterpart, the `contains` holding the wrapper bodies), so
# a plain F2003 build keeps only the bind(C) specifics.
function emit_either_tier(io, emit; mode::Symbol = ARRAY_IFACES)
  mode === :none && return
  mode === :all && println(io, "#if defined(USE_ASSUMED_SHAPE) || defined(USE_ASSUMED_RANK)")
  emit(io)
  mode === :all && println(io, "#endif")
end

# A buffer is a typed data pointer mapped to an assumed-size array `x(*)`: a c_ptr
# in the bind(C) specific, a Fortran array in the array overloads. An assumed-size
# array of a derived type (.arrayargs) is not one: it stays `type(T) :: x(*)`.
is_buffer(a::ArgInfo) = a.suffix == "(*)" && !startswith(a.ftype, "type(")

fdecl(ftype::AbstractString, suffix::AbstractString, name::AbstractString) =
  suffix == "(*)" ? "$(ftype) :: $(name)(*)" : "$(ftype)$(suffix) :: $(name)"
# A .cptrargs pass-through is not a data array: a function whose only buffer is one
# would get identical (hence ambiguous) rank_0 and rank_1 specifics.
func_has_buffer(f::FuncInfo, meta::LibMeta) =
  any(a -> is_buffer(a) && !is_cptr_passthrough(f, a, meta), f.args)

# The .argkinds scalar pointers (alpha, beta, devInfo, ...): host or device memory
# for the pointer-mode ones, so the bind(C) specific declares them
# type(c_ptr),value. The by-reference form is a module procedure (_typed), not a
# second bind(C) specific: a binding label must be unique (F2018 19.2).
scalar_ptr_args(f::FuncInfo, meta::LibMeta) = get(meta.scalar_ptrs, f.name, Set{String}())
has_scalar_ptr(f::FuncInfo, meta::LibMeta) = !isempty(scalar_ptr_args(f, meta))

# Which module procedures a generic carries beside its bind(C) specific.
wants_native(f, meta) = native_maxrank(f, meta) >= 0 && func_has_buffer(f, meta)
# Device-only scalars (.devonly) have no host variable to take by reference.
wants_typed(f, meta)  = !isempty(setdiff(scalar_ptr_args(f, meta), devonly_args(f, meta))) ||
                        !isempty(string_args(f, meta))

# Nullable by-reference arguments (.optional) that are not .argkinds scalars. An
# OPTIONAL dummy of a bind(C) interface is F2018 (18.3.6), so the bind(C) specific
# takes type(c_ptr),value and the _opt module procedure takes an OPTIONAL dummy and
# passes c_loc of it or c_null_ptr.
is_opt_arg(a::ArgInfo) = occursin("optional", a.suffix)
opt_ref_args(f::FuncInfo, meta::LibMeta) =
  Set{String}(a.name for a in f.args if is_opt_arg(a) && !(a.name in scalar_ptr_args(f, meta)))
# _opt and the bind(C) specific take the same actuals, so the latter leaves the
# generic and stays callable as `<name>_`.
wants_opt(f, meta) = !isempty(opt_ref_args(f, meta))

# `const char*` inputs, for libraries with [library] string_args = true (ROCTx).
# The _typed form takes character(kind=c_char,len=*),target and passes c_loc of it,
# without a copy: the caller supplies the NUL ("zone"//c_null_char is a constant
# expression), which matters inside a profiled region. character vs type(c_ptr)
# keeps the bind(C) specific in the generic unambiguous.
string_args(f::FuncInfo, meta::LibMeta) =
  meta.string_args ? Set{String}(a.name for a in f.args
                                 if a.is_string && a.ftype == "type(c_ptr)" && a.suffix == ", value") :
                     Set{String}()

# In device pointer mode the .ptrmode scalars are device addresses while the other
# .argkinds scalars are still host variables; _devptr spells that mixed call.
ptrmode_args(f::FuncInfo, meta::LibMeta) = get(meta.ptrmode, f.name, Set{String}())
host_args(f::FuncInfo, meta::LibMeta) =
  setdiff(scalar_ptr_args(f, meta), ptrmode_args(f, meta), devonly_args(f, meta))
wants_devptr(f, meta) = !isempty(setdiff(ptrmode_args(f, meta), devonly_args(f, meta))) &&
                        !isempty(host_args(f, meta))
# The array overloads take device-only scalars and .cptrargs scalars as variables;
# their _devptr twins take them as type(c_ptr).
cptr_scalars(f::FuncInfo, meta::LibMeta) =
  intersect(scalar_ptr_args(f, meta), meta_get(meta.cptr_args, f.name, EMPTY_STRSET))
wants_rank_devptr(f, meta) = !isempty(devonly_args(f, meta)) || !isempty(cptr_scalars(f, meta))

# Specific name capped at Fortran's 63-char limit. A plain prefix cut is not
# injective (it would silently dispatch to another C entry point), so cuts are
# registered and only a contested one gets a hash tag; uncontested cuts match
# upstream hipfort. First caller (header order) keeps the plain cut.
const SPEC_MEMO  = Dict{String,String}()   # base*suf  -> emitted identifier
const SPEC_TAKEN = Dict{String,String}()   # identifier -> base*suf that owns it

# FNV-1a: Julia's `hash` is not stable across versions.
function _stable_tag(s::AbstractString)
  h = 0x811c9dc5 % UInt32
  for b in codeunits(s); h = (h ⊻ UInt32(b)) * (0x01000193 % UInt32); end
  string(h & 0xffff, base = 16, pad = 4)
end

function spec_name(base::String, suf::String)
  full = base * suf
  haskey(SPEC_MEMO, full) && return SPEC_MEMO[full]
  # Untruncated names are registered too: a cut can land on one.
  name = length(full) <= 63 ? full : base[1:63-length(suf)] * suf
  if get(SPEC_TAKEN, name, full) != full
    tag = _stable_tag(base)
    name = base[1:63-length(suf)-5] * "_" * tag * suf
    n = 0
    while get(SPEC_TAKEN, name, full) != full
      n += 1
      name = base[1:63-length(suf)-5] * "_" * _stable_tag(base * string(n)) * suf
    end
  end
  SPEC_MEMO[full] = name; SPEC_TAKEN[name] = full
  return name
end

# The bind(C) specific's spelling: buffers, .argkinds scalars and nullable
# arguments become type(c_ptr),value.
raw_arg(a::ArgInfo) = is_buffer(a) ? ArgInfo(a.name, "type(c_ptr)", ", value", a.is_string) : a
raw_arg(f::FuncInfo, a::ArgInfo, meta::LibMeta) = (a.name in scalar_ptr_args(f, meta) || is_opt_arg(a)) ?
    ArgInfo(a.name, "type(c_ptr)", ", value", a.is_string) : raw_arg(a)
# integer(kind(<enumerator>)) is the same type as integer(c_int), but gfortran
# -Wc-binding-type flags it in every bind(C) interface. Module procedures keep it.
c_int_if_enum(ft::AbstractString) =
  occursin(r"^integer\(kind\(\w+\)\)$", ft) ? "integer(c_int)" : String(ft)
raw_func(f::FuncInfo, meta::LibMeta) =
  FuncInfo(f.name, c_int_if_enum(f.ret_ftype), f.is_void,
           ArgInfo[(r = raw_arg(f, a, meta);
                    ArgInfo(r.name, c_int_if_enum(r.ftype), r.suffix, r.is_string))
                   for a in f.args])

# The generic X: its bind(C) specific `X_` plus the module procedures that apply:
#   X_rank_N / X_full_rank / X_assumed_rank  buffers as Fortran arrays
#   X_typed   the .argkinds scalars by their Fortran type
#   X_devptr  the pointer-mode scalars as pointers, the host-only ones typed
#   X_opt     the nullable arguments as OPTIONAL dummies
# alias: emit the generic under another name (a versioned alias).
function emit_generic(io, f::FuncInfo, meta::LibMeta; alias::String = "")
  procs = String[]
  procs_ar = String[]
  if wants_native(f, meta)
    dp = wants_rank_devptr(f, meta)
    for r in 0:native_maxrank(f, meta)
      push!(procs, spec_name(f.name, "_rank_$(r)"))
      dp && push!(procs, spec_name(f.name, "_rank_$(r)_devptr"))
    end
    if emits_fullrank(f, meta)
      push!(procs, spec_name(f.name, "_full_rank"))
      dp && push!(procs, spec_name(f.name, "_full_rank_devptr"))
    end
    push!(procs_ar, spec_name(f.name, "_assumed_rank"))
    dp && push!(procs_ar, spec_name(f.name, "_assumed_rank_devptr"))
  end
  # Overloads the library emits itself (blas_aux_hooks), in the same tiers.
  let ep = get(meta.extra_procs, f.name, nothing)
    ep === nothing || (append!(procs, ep[1]); append!(procs_ar, ep[2]))
  end
  # Plain F2003 forms, listed outside the USE_ASSUMED_* guards.
  procs_always = wants_opt(f, meta) ? [spec_name(f.name, "_opt")] : String[]
  wants_typed(f, meta) && push!(procs_always, spec_name(f.name, "_typed"))
  wants_devptr(f, meta) && push!(procs_always, spec_name(f.name, "_devptr"))
  emit_named_interface(io, raw_func(f, meta), meta;
                       fname = isempty(alias) ? f.name : alias,
                       alias_of = isempty(alias) ? nothing : f.name,
                       module_procs=procs, module_procs_assumed=procs_ar,
                       module_procs_always=procs_always,
                       raw_in_generic=!wants_opt(f, meta))
end

# The `use` preamble of a forwarding wrapper, down to `implicit none`. The enums,
# types and sibling-library names come by host association from the module.
function emit_wrapper_uses(io)
  println(io, "      use iso_c_binding")
  println(io, "      implicit none")
end

# A buffer's rank in the _full_rank form: the metadata's 1d/2d/3d when it imposes
# one; otherwise 1, plus 1 when a leading dimension (lda, ldb, ...) follows it, plus 1
# when a batch stride (stride_A, stridex, ...) follows that or its increment: the
# matrices and vectors of a strided-batched routine are 3-D and 2-D.
function arg_natural_rank(f::FuncInfo, meta::LibMeta, idx::Int)
  args = f.args
  d = get(imposed_dims(f, meta), args[idx].name, 0)
  d > 0 && return d
  starts(j, p) = j <= length(args) && startswith(lowercase(args[j].name), p)
  r, j = 1, idx + 1
  if starts(j, "ld")
    r += 1; j += 1
  elseif starts(j, "inc")
    j += 1
  end
  starts(j, "stride") && (r += 1)
  return r
end

# Typed pointers kept as an opaque c_ptr in the array overloads instead of becoming
# a Fortran array (per function, from <lib>.cptrargs).
is_cptr_passthrough(f::FuncInfo, a::ArgInfo, meta::LibMeta) =
  a.name in meta_get(meta.cptr_args, f.name, EMPTY_STRSET)

# Device-only .argkinds scalars (<lib>.devonly), written by the kernel (hipSOLVER's
# devInfo): no _typed form, but the array overloads still take them typed. Such an
# argument must also be in .argkinds. An ILP64 or _v2 variant inherits its base
# routine's entry.
devonly_args(f::FuncInfo, meta::LibMeta) =
  meta_get(meta.devonly, f.name, EMPTY_STRSET)

# Without a buffer above rank 1, _full_rank would duplicate _rank_1 (ambiguous generic).
has_matrix_buffer(f::FuncInfo, meta::LibMeta) =
  any(i -> is_buffer(f.args[i]) && !is_cptr_passthrough(f, f.args[i], meta) &&
           arg_natural_rank(f, meta, i) >= 2, eachindex(f.args))
emits_fullrank(f::FuncInfo, meta::LibMeta) = wants_fullrank(f, meta) && has_matrix_buffer(f, meta)

# One module procedure of the generic:
#   default  the rank_<rank> array overload (ndims, or each buffer's natural rank)
#   assumed  the F2018 assumed-rank overload (dimension(..)), alternative to rank_N
#   typed    the _typed form: buffers stay type(c_ptr), .argkinds scalars by reference
#   devptr   with typed, the _devptr form; otherwise an array overload's twin
#   opt      the _opt form, the C signature with nullable arguments OPTIONAL
# A .optional argument is an optional dummy in every form, forwarded as
# c_null_ptr when absent.
function emit_rank_wrapper(io, f::FuncInfo, meta::LibMeta, rank::Int = 0;
                           assumed::Bool = false,
                           typed::Bool = false, devptr::Bool = false, opt::Bool = false,
                           suffix::String = opt ? "_opt" :
                                            (typed ? (devptr ? "_devptr" : "_typed") :
                                             assumed ? "_assumed_rank" : "_rank_$(rank)") *
                                            (devptr && !typed ? "_devptr" : ""),
                           ndims::Int = rank, natural::Bool = false)
  name  = f.name
  wname = spec_name(name, suffix)
  rawnm = name * "_"
  joined = join((a.name for a in f.args), ",")
  # Checked before is_cptr_passthrough: some rocBLAS rot-family args are in both
  # .argkinds and .cptrargs, and the scalar rule wins.
  scalars   = scalar_ptr_args(f, meta)
  devonly   = devonly_args(f, meta)
  typedargs = opt    ? Set{String}() :
              devptr ? (typed ? host_args(f, meta) : setdiff(host_args(f, meta), cptr_scalars(f, meta))) :
              typed  ? setdiff(scalars, devonly) : scalars
  asptr     = setdiff(scalars, typedargs)
  strargs   = typed ? string_args(f, meta) : Set{String}()
  optref    = opt_ref_args(f, meta)
  typed     = typed || opt
  if f.is_void
    println_wrapped(io, "    subroutine $(wname)($joined)", "        ")
  else
    println_wrapped(io, "    function $(wname)($joined)", "        ")
  end
  emit_wrapper_uses(io)
  f.is_void || println(io, "      $(f.ret_ftype) :: $(wname)")
  for (i, a) in enumerate(f.args)
    if a.name in strargs
      println(io, "      character(kind=c_char,len=*),intent(in),target :: $(a.name)")
    elseif a.name in typedargs
      println(io, "      $(a.ftype),$(is_opt_arg(a) ? "optional," : "")target :: $(a.name)")
    elseif a.name in optref
      println(io, "      $(a.ftype),optional,target :: $(a.name)")
    elseif a.name in asptr
      println(io, "      type(c_ptr),value :: $(a.name)")
    elseif is_buffer(a) && (typed || is_cptr_passthrough(f, a, meta))
      println(io, "      type(c_ptr) :: $(a.name)")
    elseif is_buffer(a)
      if assumed
        println(io, "      $(a.ftype),target,dimension(..) :: $(a.name)")
      else
        nd = natural ? arg_natural_rank(f, meta, i) : ndims
        dimattr = nd == 0 ? "" : ",dimension(" * join(fill(":", nd), ",") * ")"
        println(io, "      $(a.ftype),target$(dimattr) :: $(a.name)")
      end
    else
      # By reference, except: a C `char` (gfortran 13 forwards a by-reference
      # character(c_char) to a `value` dummy as a stray byte), and type(c_ptr) /
      # type(c_funptr) (an address-constant actual becomes a .rodata temporary that
      # a PIE can only relocate with DT_TEXTREL).
      byval = a.suffix == ", value" &&
              (startswith(a.ftype, "character") || a.ftype in ("type(c_ptr)", "type(c_funptr)"))
      println(io, "      " * fdecl(a.ftype, (a.suffix == ", value" && !byval) ? "" : a.suffix, a.name))
    end
  end
  # c_loc of an absent optional is not allowed: build the address beforehand.
  opts = [a.name for a in f.args if (a.name in typedargs && is_opt_arg(a)) || a.name in optref]
  for n in opts; println(io, "      type(c_ptr) :: $(n)__p"); end
  println(io, "      !")
  for n in opts
    println(io, "      $(n)__p = c_null_ptr")
    println(io, "      if (present($(n))) $(n)__p = c_loc($(n))")
  end
  callargs = join((a.name in opts ? "$(a.name)__p" :
                   (a.name in typedargs || a.name in strargs) ? "c_loc($(a.name))" :
                   (is_buffer(a) && !typed && !is_cptr_passthrough(f, a, meta)) ? "c_loc($(a.name))" :
                   a.name
                   for a in f.args), ",")
  if f.is_void
    println_wrapped(io, "      call $(rawnm)($callargs)", "        ")
    println(io, "    end subroutine")
  else
    println_wrapped(io, "      $(wname) = $(rawnm)($callargs)", "        ")
    println(io, "    end function")
  end
  println(io, "")
end

# The array overloads (the guarded `contains` body).
function emit_wrappers_body(io, funcs::Vector{FuncInfo}, meta::LibMeta)
  for f in funcs
    wants_native(f, meta) || continue
    dp = wants_rank_devptr(f, meta)
    # Already inside emit_either_tier's `#if`, hence per_rank_is_default.
    emit_tier_guard(io,
      function (o)
        emit_rank_wrapper(o, f, meta; assumed=true)
        dp && emit_rank_wrapper(o, f, meta; assumed=true, devptr=true)
      end,
      function (o)
        for r in 0:native_maxrank(f, meta)
          emit_rank_wrapper(o, f, meta, r)
          dp && emit_rank_wrapper(o, f, meta, r; devptr=true)
        end
        if emits_fullrank(f, meta)
          emit_rank_wrapper(o, f, meta, 2; suffix="_full_rank", natural=true)
          dp && emit_rank_wrapper(o, f, meta, 2; suffix="_full_rank_devptr", natural=true,
                                  devptr=true)
        end
      end;
      per_rank_is_default = true)
  end
end

# The _opt/_typed/_devptr forms, in the unguarded `contains`: their generic
# entries are listed outside the USE_ASSUMED_* guards.
function emit_typed_body(io, funcs::Vector{FuncInfo}, meta::LibMeta)
  for f in funcs
    (wants_typed(f, meta) || wants_opt(f, meta)) || continue
    wants_opt(f, meta)    && emit_rank_wrapper(io, f, meta; opt=true)
    wants_typed(f, meta)  && emit_rank_wrapper(io, f, meta; typed=true)
    wants_devptr(f, meta) && emit_rank_wrapper(io, f, meta; typed=true, devptr=true)
  end
end

# Guarded array overloads only; counting the unguarded forms would open an empty
# `#if` block.
needs_wrappers(funcs::Vector{FuncInfo}, meta::LibMeta) = any(f -> wants_native(f, meta), funcs)

needs_typed(funcs::Vector{FuncInfo}, meta::LibMeta) =
  any(f -> wants_typed(f, meta) || wants_opt(f, meta), funcs)
