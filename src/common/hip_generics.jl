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

# Typed generic overloads for the HIP memory families (hipMalloc, hipFree,
# hipMemcpy, hipHostRegister and relatives), mirroring hipfort's ergonomics, and
# the hipGetDeviceProperties interface. Folded into `module hip`: each family has a
# _spec half (interface blocks, for the specification part) and a _body half
# (wrappers, after `contains`), so the enums, types and hipMemcpy are reached by
# host association.
#
# Each generic bundles the bind(C) specific (<fn>_, still callable with a raw
# type(c_ptr) and a byte count) and one module procedure per element type x rank,
# taking counts in ELEMENTS.
#
# No wrapper, per-rank or assumed-rank, uses the `contiguous` attribute: passing
# a pointer that is not provably contiguous to a contiguous dummy can trigger
# copy-in/out to a host temporary, which is fatal for device buffers. The arrays
# must be contiguous: c_loc gives the address of their first element.

# (tag, Fortran type, element size in bytes)
const HIP_GEN_TYPES = [
  ("i4", "integer(c_int)",            4),
  ("i8", "integer(c_int64_t)",        8),
  ("r4", "real(c_float)",             4),
  ("r8", "real(c_double)",            8),
  ("c4", "complex(c_float_complex)",  8),
  ("c8", "complex(c_double_complex)", 16),
  ("l",  "logical(c_bool)",           1),
]

# Rank 0 is a scalar pointer, as in hipfort (`hipMalloc(d, source=h)` on a scalar).
const HIP_GEN_RANKS = 0:7

dim_attr(r) = r == 0 ? "" : ", dimension(" * join(fill(":", r), ",") * ")"

# Element designator for c_loc: "" for a scalar, "(1,1,...)" otherwise. c_loc of
# the first element needs no `contiguous` attribute and never triggers copy-in/out
# (which would make c_loc return the address of a host temporary).
first_elem(r) = r == 0 ? "" : "(" * join(fill("1", r), ",") * ")"

cfp_shape(r, expr) = r == 0 ? "" : ", shape=$(expr)"

# Element count as a c_size_t. `size(x, kind=c_size_t)`, not `int(size(x), c_size_t)`:
# the latter evaluates size() in default integer first and wraps past 2^31 - 1 elements.
csz(r, x) = r == 0 ? "int(1, c_size_t)" : "size($(x), kind=c_size_t)"

emit_aux_bind(io, sig::String, hipname::String) =
  emit_bind_signature(io, "    $(sig)", "bind(c, name=\"$(hipname)\")", "        ")

# Per-dimension lengths come in two kinds (c_int and c_size_t, as in hipfort) so
# that hipMalloc(ptr, n) also resolves for a c_size_t count.
# After an allocation call: on failure, leave ptr unassociated and return. HIP may
# return before writing its output, so cptr starts as c_null_ptr and ptr is never
# associated with an address the allocation did not return.
function emit_alloc_failed(io, ind::String)
  println(io, "$(ind)if (res /= 0) then")
  println(io, "$(ind)  ptr => null()")
  println(io, "$(ind)  return")
  println(io, "$(ind)end if")
end

function emit_hipmalloc_impls(io)
  for (tag, ftype, bytes) in HIP_GEN_TYPES, r in HIP_GEN_RANKS,
      (suf, lenkind) in (("", "c_int"), ("_c_size_t", "c_size_t"))
    r == 0 && continue   # a scalar only has the _source form
    name    = "hipMalloc_$(tag)_$(r)$(suf)"
    lenargs = join(["length$(i)" for i in 1:r], ", ")
    shape   = join(["length$(i)" for i in 1:r], ",")
    println(io, "  function $(name)(ptr, $(lenargs)) result(res)")
    println(io, "    use iso_c_binding")
    println(io, "    implicit none")
    println(io, "    $(ftype), pointer$(dim_attr(r)), intent(inout) :: ptr")
    println(io, "    integer($(lenkind)), intent(in) :: $(lenargs)")
    println(io, "    integer(c_int) :: res")
    println(io, "    integer(c_size_t) :: nbytes")
    println(io, "    type(c_ptr) :: cptr")
    # One factor per line keeps rank 7 within the free-form 132-column limit.
    println(io, "    nbytes = $(bytes)_c_size_t")
    for i in 1:r
      println(io, "    nbytes = nbytes * int(length$(i), c_size_t)")
    end
    println(io, "    cptr = c_null_ptr")
    println(io, "    res = hipMalloc_(cptr, nbytes)")
    emit_alloc_failed(io, "    ")
    println(io, "    call c_f_pointer(cptr, ptr$(cfp_shape(r, "[$(shape)]")))")
    println(io, "  end function $(name)")
    println(io, "")
  end
end

# Emit `ptr(<lb1>:,<lb2>:,...) => tmp`, wrapped when it would exceed 132 columns.
function emit_ptr_remap(io, r, boundfn)
  parts = [boundfn(i) for i in 1:r]
  s = "      ptr(" * join(parts, ",") * ") => tmp"
  if length(s) <= 125
    println(io, s)
  else
    println(io, "      ptr(" * parts[1] * ",&")
    for k in 2:r-1
      println(io, "        " * parts[k] * ",&")
    end
    println(io, "        " * parts[r] * ") => tmp")
  end
end

# hipfort's combined allocation form: one procedure per type x rank whose OPTIONAL
# arguments are dispatched by present():
#   <fn>(ptr, dims=[, lbounds=])    <fn>(ptr, dims8=[, lbounds8=])
#   <fn>(ptr, mold=a)   <fn>(ptr, source=a)   <fn>(ptr, dsource=a_d)
# mold/source/dsource keep a's lower bounds; the scalar form only has source/dsource.
# The copy runs only if the allocation succeeded, so an out-of-memory status is not
# overwritten by the copy's.
function emit_alloc_source_impls(io; family, rawfn, flags=false,
                                 src_kind="hipMemcpyHostToDevice",
                                 dsrc_kind="hipMemcpyDeviceToDevice")
  fa = flags ? ", flags" : ""
  for (tag, ftype, bytes) in HIP_GEN_TYPES, r in HIP_GEN_RANKS
    name = "$(family)_$(tag)_$(r)_source"
    b    = "$(bytes)_c_size_t"
    if r == 0
      println(io, "  function $(name)(ptr, dsource, source$(fa)) result(res)")
      println(io, "    use iso_c_binding")
      println(io, "    implicit none")
      println(io, "    $(ftype), pointer, intent(inout) :: ptr")
      println(io, "    $(ftype), target, intent(in), optional :: dsource, source")
      flags && println(io, "    integer(c_int), intent(in) :: flags")
      println(io, "    integer(c_int) :: res")
      println(io, "    integer :: nOptArgs")
      println(io, "    type(c_ptr) :: cptr")
      println(io, "    cptr = c_null_ptr")
      println(io, "    nOptArgs = 0")
      println(io, "    if (present(dsource)) nOptArgs = nOptArgs + 1")
      println(io, "    if (present(source))  nOptArgs = nOptArgs + 1")
      println(io, "    if (nOptArgs > 1) ERROR STOP \"$(family): specify only one of dsource/source\"")
      println(io, "    if (present(dsource)) then")
      println(io, "      res = $(rawfn)(cptr, $(b)$(fa))")
      emit_alloc_failed(io, "      ")
      println(io, "      res = hipMemcpy(cptr, c_loc(dsource), $(b), $(dsrc_kind))")
      println(io, "      call c_f_pointer(cptr, ptr)")
      println(io, "    else if (present(source)) then")
      println(io, "      res = $(rawfn)(cptr, $(b)$(fa))")
      emit_alloc_failed(io, "      ")
      println(io, "      res = hipMemcpy(cptr, c_loc(source), $(b), $(src_kind))")
      println(io, "      call c_f_pointer(cptr, ptr)")
      println(io, "    else")
      println(io, "      res = $(rawfn)(cptr, $(b)$(fa))")
      emit_alloc_failed(io, "      ")
      println(io, "      call c_f_pointer(cptr, ptr)")
      println(io, "    end if")
      println(io, "  end function $(name)")
      println(io, "")
    else
      shp = join(fill(":", r), ",")
      println(io, "  function $(name)(ptr, dims, dims8, lbounds, lbounds8, dsource, source, mold$(fa)) result(res)")
      println(io, "    use iso_c_binding")
      println(io, "    implicit none")
      println(io, "    $(ftype), pointer, dimension($(shp)), intent(inout) :: ptr")
      println(io, "    integer(c_int), intent(in), optional :: dims($(r)), lbounds($(r))")
      println(io, "    integer(c_int64_t), intent(in), optional :: dims8($(r)), lbounds8($(r))")
      println(io, "    $(ftype), target, dimension($(shp)), intent(in), optional :: dsource, source, mold")
      flags && println(io, "    integer(c_int), intent(in) :: flags")
      println(io, "    integer(c_int) :: res")
      println(io, "    integer :: nOptArgs")
      println(io, "    type(c_ptr) :: cptr")
      println(io, "    $(ftype), pointer, dimension($(shp)) :: tmp")
      println(io, "    cptr = c_null_ptr")
      println(io, "    nOptArgs = 0")
      for a in ("dims", "dims8", "dsource", "source", "mold")
        println(io, "    if (present($(a))) nOptArgs = nOptArgs + 1")
      end
      println(io, "    if (nOptArgs == 0) ERROR STOP \"$(family): specify one of dims/dims8/dsource/source/mold\"")
      println(io, "    if (nOptArgs > 1)  ERROR STOP \"$(family): specify only one of dims/dims8/dsource/source/mold\"")
      println(io, "    if (present(lbounds8) .and. .not. present(dims8)) ERROR STOP \"$(family): lbounds8 requires dims8\"")
      println(io, "    if (present(lbounds)  .and. .not. present(dims))  ERROR STOP \"$(family): lbounds requires dims\"")
      println(io, "    if (present(dsource)) then")
      println(io, "      res = $(rawfn)(cptr, size(dsource, kind=c_size_t)*$(b)$(fa))")
      emit_alloc_failed(io, "      ")
      println(io, "      res = hipMemcpy(cptr, c_loc(dsource), size(dsource, kind=c_size_t)*$(b), $(dsrc_kind))")
      println(io, "      call c_f_pointer(cptr, tmp, shape=shape(dsource))")
      emit_ptr_remap(io, r, i -> "LBOUND(dsource,$(i)):")
      println(io, "    else if (present(source)) then")
      println(io, "      res = $(rawfn)(cptr, size(source, kind=c_size_t)*$(b)$(fa))")
      emit_alloc_failed(io, "      ")
      println(io, "      res = hipMemcpy(cptr, c_loc(source), size(source, kind=c_size_t)*$(b), $(src_kind))")
      println(io, "      call c_f_pointer(cptr, tmp, shape=shape(source))")
      emit_ptr_remap(io, r, i -> "LBOUND(source,$(i)):")
      println(io, "    else if (present(mold)) then")
      println(io, "      res = $(rawfn)(cptr, size(mold, kind=c_size_t)*$(b)$(fa))")
      emit_alloc_failed(io, "      ")
      println(io, "      call c_f_pointer(cptr, tmp, shape=shape(mold))")
      emit_ptr_remap(io, r, i -> "LBOUND(mold,$(i)):")
      println(io, "    else if (present(dims8)) then")
      println(io, "      res = $(rawfn)(cptr, product(dims8)*$(b)$(fa))")
      emit_alloc_failed(io, "      ")
      println(io, "      call c_f_pointer(cptr, tmp, shape=dims8)")
      println(io, "      if (present(lbounds8)) then")
      emit_ptr_remap(io, r, i -> "lbounds8($(i)):")
      println(io, "      else")
      println(io, "        ptr => tmp")
      println(io, "      end if")
      println(io, "    else if (present(dims)) then")
      println(io, "      res = $(rawfn)(cptr, product(int(dims, c_size_t))*$(b)$(fa))")
      emit_alloc_failed(io, "      ")
      println(io, "      call c_f_pointer(cptr, tmp, shape=dims)")
      println(io, "      if (present(lbounds)) then")
      emit_ptr_remap(io, r, i -> "lbounds($(i)):")
      println(io, "      else")
      println(io, "        ptr => tmp")
      println(io, "      end if")
      println(io, "    end if")
      println(io, "  end function $(name)")
      println(io, "")
    end
  end
end

emit_hipmalloc_source_impls(io)      = emit_alloc_source_impls(io; family="hipMalloc", rawfn="hipMalloc_")
emit_hipmallocmanaged_source_impls(io) = emit_alloc_source_impls(io; family="hipMallocManaged", rawfn="hipMallocManaged_", flags=true)
emit_hiphostmalloc_source_impls(io)  = emit_alloc_source_impls(io; family="hipHostMalloc", rawfn="hipHostMalloc_", flags=true,
                                                               src_kind="hipMemcpyHostToHost", dsrc_kind="hipMemcpyDeviceToHost")

# hipMallocManaged / hipHostMalloc length forms: `flags` is OPTIONAL and defaults
# to the enum constant `flagdef`.
function emit_flagged_alloc_impls(io, family::String, rawfn::String, flagdef::String)
  for (tag, ftype, bytes) in HIP_GEN_TYPES, r in HIP_GEN_RANKS,
      (suf, lenkind) in (("", "c_int"), ("_c_size_t", "c_size_t"))
    r == 0 && continue
    name    = "$(family)_$(tag)_$(r)$(suf)"
    lenargs = join(["length$(i)" for i in 1:r], ", ")
    shape   = join(["length$(i)" for i in 1:r], ",")
    println(io, "  function $(name)(ptr, $(lenargs), flags) result(res)")
    println(io, "    use iso_c_binding")
    println(io, "    implicit none")
    println(io, "    $(ftype), pointer$(dim_attr(r)), intent(inout) :: ptr")
    println(io, "    integer($(lenkind)), intent(in) :: $(lenargs)")
    println(io, "    integer(c_int), intent(in), optional :: flags")
    println(io, "    integer(c_int) :: res")
    println(io, "    integer(c_int) :: fl")
    println(io, "    integer(c_size_t) :: nbytes")
    println(io, "    type(c_ptr) :: cptr")
    println(io, "    fl = $(flagdef)")
    println(io, "    if (present(flags)) fl = flags")
    println(io, "    nbytes = $(bytes)_c_size_t")
    for i in 1:r
      println(io, "    nbytes = nbytes * int(length$(i), c_size_t)")
    end
    println(io, "    cptr = c_null_ptr")
    println(io, "    res = $(rawfn)(cptr, nbytes, fl)")
    emit_alloc_failed(io, "    ")
    println(io, "    call c_f_pointer(cptr, ptr$(cfp_shape(r, "[$(shape)]")))")
    println(io, "  end function $(name)")
    println(io, "")
  end
end

emit_hipmallocmanaged_impls(io) =
  emit_flagged_alloc_impls(io, "hipMallocManaged", "hipMallocManaged_", "hipMemAttachGlobal")
emit_hiphostmalloc_impls(io) =
  emit_flagged_alloc_impls(io, "hipHostMalloc", "hipHostMalloc_", "hipHostMallocDefault")

# `only_if_allocated=.true.` (as in hipfort) skips the free of an unassociated pointer.
function emit_free_family_impls(io, family::String, rawfn::String)
  for (tag, ftype, _bytes) in HIP_GEN_TYPES, r in HIP_GEN_RANKS
    name = "$(family)_$(tag)_$(r)"
    println(io, "  function $(name)(ptr, only_if_allocated) result(res)")
    println(io, "    use iso_c_binding")
    println(io, "    implicit none")
    println(io, "    $(ftype), pointer$(dim_attr(r)), intent(inout) :: ptr")
    println(io, "    logical, intent(in), optional :: only_if_allocated")
    println(io, "    integer(c_int) :: res")
    println(io, "    logical :: guard")
    println(io, "    guard = .false.")
    println(io, "    if (present(only_if_allocated)) guard = only_if_allocated")
    println(io, "    res = 0")   # hipSuccess; skipping an unassociated pointer is not an error
    println(io, "    if (associated(ptr)) then")
    # c_loc(ptr), not first_elem: with custom lower bounds (1,...,1) is inside the
    # block, and HIP requires the address the allocation returned. A pointer dummy
    # is never copied in, so c_loc(ptr) is safe.
    println(io, "      res = $(rawfn)(c_loc(ptr))")
    println(io, "      ptr => null()")
    # c_loc of an unassociated pointer is not allowed: without the guard, free NULL,
    # as the C call does, which HIP accepts.
    println(io, "    else if (.not. guard) then")
    println(io, "      res = $(rawfn)(c_null_ptr)")
    println(io, "    end if")
    println(io, "  end function $(name)")
    println(io, "")
  end
end

emit_hipfree_impls(io)     = emit_free_family_impls(io, "hipFree",     "hipFree_")
emit_hiphostfree_impls(io) = emit_free_family_impls(io, "hipHostFree", "hipHostFree_")

# (family, pitched, isasync): `pitched` selects the 2-D dpitch/spitch/width/height
# form, `isasync` appends the stream argument.
const HIP_MEMCPY_FAMILIES = [
  ("hipMemcpy",        false, false),
  ("hipMemcpyAsync",   false, true),
  ("hipMemcpy2D",      true,  false),
  ("hipMemcpy2DAsync", true,  true),
]

# Every family this file owns. src/hip/generator.jl drops these names from the
# plain bind(C) path so each generic here is the sole definition.
const HIP_TYPED_FAMILIES = [
  "hipMalloc", "hipMallocManaged", "hipHostMalloc", "hipFree", "hipHostFree",
  first.(HIP_MEMCPY_FAMILIES)...,
  "hipHostRegister", "hipHostUnregister", "hipHostGetDevicePointer", "hipHostGetFlags",
]

# Typed hipMemcpy families, with hipfort's specific names:
#   hipMemcpy(dest, src, count, kind)   ! _c_size_t / _c_int: explicit element count
#   hipMemcpy(dest, src, kind)          ! base name: count = size(dest)
# The pitched families take pitches and width in elements, height in rows, and have
# no inferred-count form. `assumed` emits one assumed-rank specific per type instead
# of the rank 0..7 set, without `contiguous` either (see the top of this file).
function emit_memcpy_impls(io, family::String; pitched::Bool, isasync::Bool, assumed=false)
  raw    = "$(family)_"
  stream = isasync ? ", stream" : ""
  for (tag, ftype, bytes) in HIP_GEN_TYPES, r in (assumed ? (-1:-1) : HIP_GEN_RANKS)
    da = assumed ? ", dimension(..)" : dim_attr(r)
    fe = assumed ? "" : first_elem(r)
    rp = assumed ? "assumed_rank" : "$(r)"
    for (csuf, ckind) in (("_c_size_t", "c_size_t"), ("_c_int", "c_int"))
      name = "$(family)_$(tag)_$(rp)$(csuf)"
      println(io, pitched ?
        "  function $(name)(dest, dpitch, src, spitch, width, height, myKind$(stream)) result(res)" :
        "  function $(name)(dest, src, length, myKind$(stream)) result(res)")
      println(io, "    use iso_c_binding")
      println(io, "    implicit none")
      println(io, "    $(ftype), target$(da), intent(inout) :: dest")
      pitched && println(io, "    integer($(ckind)), value :: dpitch, spitch, width, height")
      println(io, "    $(ftype), target$(da), intent(in)    :: src")
      pitched || println(io, "    integer($(ckind)), value :: length")
      println(io, "    integer(c_int), value :: myKind")
      isasync && println(io, "    type(c_ptr), value :: stream")
      println(io, "    integer(c_int) :: res")
      if pitched
        println(io, "    integer(c_size_t) :: b")
        println(io, "    b = $(bytes)_c_size_t")
        println(io, "    res = $(raw)(c_loc(dest$(fe)), b*int(dpitch,c_size_t), &")
        println(io, "      c_loc(src$(fe)), b*int(spitch,c_size_t), b*int(width,c_size_t), &")
        println(io, "      int(height,c_size_t), myKind$(stream))")
      else
        println(io, "    integer(c_size_t) :: nbytes")
        println(io, "    nbytes = int(length, c_size_t) * $(bytes)_c_size_t")
        println(io, "    res = $(raw)(c_loc(dest$(fe)), c_loc(src$(fe)), nbytes, myKind$(stream))")
      end
      println(io, "  end function $(name)")
      println(io, "")
    end
    pitched && continue
    szx  = assumed ? "size(dest, kind=c_size_t)" : csz(r, "dest")
    name = "$(family)_$(tag)_$(rp)"
    println(io, "  function $(name)(dest, src, myKind$(stream)) result(res)")
    println(io, "    use iso_c_binding")
    println(io, "    implicit none")
    println(io, "    $(ftype), target$(da), intent(inout) :: dest")
    println(io, "    $(ftype), target$(da), intent(in)    :: src")
    println(io, "    integer(c_int), value :: myKind")
    isasync && println(io, "    type(c_ptr), value :: stream")
    println(io, "    integer(c_int) :: res")
    println(io, "    integer(c_size_t) :: nbytes")
    println(io, "    nbytes = $(szx) * $(bytes)_c_size_t")
    println(io, "    res = $(raw)(c_loc(dest$(fe)), c_loc(src$(fe)), nbytes, myKind$(stream))")
    println(io, "  end function $(name)")
    println(io, "")
  end
end

function emit_hiphostregister_impls(io)
  for (tag, ftype, bytes) in HIP_GEN_TYPES, r in HIP_GEN_RANKS
    b = "$(bytes)_c_size_t"
    # _nosize: the byte size is inferred from the array.
    name = "hipHostRegister_$(tag)_$(r)_nosize"
    println(io, "  function $(name)(hostPtr, flags) result(res)")
    println(io, "    use iso_c_binding")
    println(io, "    implicit none")
    println(io, "    $(ftype), target$(dim_attr(r)), intent(in) :: hostPtr")
    println(io, "    integer(c_int), intent(in) :: flags")
    println(io, "    integer(c_int) :: res")
    println(io, "    res = hipHostRegister_(c_loc(hostPtr$(first_elem(r))), $(csz(r, "hostPtr"))*$(b), flags)")
    println(io, "  end function $(name)")
    println(io, "")
    r == 0 && continue
    for (suf, lenkind) in (("", "c_int"), ("_c_size_t", "c_size_t"))
      name    = "hipHostRegister_$(tag)_$(r)$(suf)"
      lenargs = join(["length$(i)" for i in 1:r], ", ")
      println(io, "  function $(name)(hostPtr, $(lenargs), flags) result(res)")
      println(io, "    use iso_c_binding")
      println(io, "    implicit none")
      println(io, "    $(ftype), target$(dim_attr(r)), intent(in) :: hostPtr")
      println(io, "    integer($(lenkind)), intent(in) :: $(lenargs)")
      println(io, "    integer(c_int), intent(in) :: flags")
      println(io, "    integer(c_int) :: res")
      println(io, "    integer(c_size_t) :: nbytes")
      println(io, "    nbytes = $(b)")
      for i in 1:r
        println(io, "    nbytes = nbytes * int(length$(i), c_size_t)")
      end
      println(io, "    res = hipHostRegister_(c_loc(hostPtr$(first_elem(r))), nbytes, flags)")
      println(io, "  end function $(name)")
      println(io, "")
    end
  end
end

# One specific per type x rank taking the Fortran buffer `buf`; `actuals` maps the
# c_loc expression of `buf` to the actual-argument list of the <family>_ bind.
function emit_hostptr_impls(io, family::String; args::String, buf::String,
                            before::Vector{String}=String[], after::Vector{String}=String[],
                            actuals::Function)
  for (tag, ftype, _b) in HIP_GEN_TYPES, r in HIP_GEN_RANKS
    name = "$(family)_$(tag)_$(r)"
    println(io, "  function $(name)($(args)) result(res)")
    println(io, "    use iso_c_binding")
    println(io, "    implicit none")
    for d in before; println(io, "    $(d)"); end
    println(io, "    $(ftype), target$(dim_attr(r)), intent(inout) :: $(buf)")
    for d in after; println(io, "    $(d)"); end
    println(io, "    integer(c_int) :: res")
    println(io, "    res = $(family)_($(actuals("c_loc($(buf)$(first_elem(r)))")))")
    println(io, "  end function $(name)")
    println(io, "")
  end
end

emit_hiphostunregister_impls(io) =
  emit_hostptr_impls(io, "hipHostUnregister"; args="hostPtr", buf="hostPtr",
                     actuals = loc -> loc)
emit_hiphostgetdevicepointer_impls(io) =
  emit_hostptr_impls(io, "hipHostGetDevicePointer"; args="devPtr, hstPtr, flags", buf="hstPtr",
                     before=["type(c_ptr) :: devPtr"], after=["integer(c_int), value :: flags"],
                     actuals = loc -> "devPtr, $(loc), flags")
emit_hiphostgetflags_impls(io) =
  emit_hostptr_impls(io, "hipHostGetFlags"; args="flagsPtr, hostPtr", buf="hostPtr",
                     before=["integer(c_int) :: flagsPtr"],
                     actuals = loc -> "flagsPtr, $(loc)")

function proc_list(prefix; suffixes = [""])
  names = String[]
  for (tag, _ft, _b) in HIP_GEN_TYPES, r in HIP_GEN_RANKS, s in suffixes
    push!(names, "$(prefix)_$(tag)_$(r)$(s)")
  end
  return names
end

function emit_proc_list(io, names)
  for n in names
    println(io, "    module procedure $(n)")
  end
end

function ar_proc_list(prefix; suffixes = [""])
  names = String[]
  for (tag, _ft, _b) in HIP_GEN_TYPES, s in suffixes
    push!(names, "$(prefix)_$(tag)_assumed_rank$(s)")
  end
  return names
end

# Assumed-rank names under USE_ASSUMED_RANK, per-rank names under USE_ASSUMED_SHAPE;
# must use the same guard as hipmemcpy_body.
function emit_guarded_proc_list(io, per_rank_names, assumed_names)
  emit_tier_guard(io,
    o -> emit_proc_list(o, assumed_names),
    o -> emit_proc_list(o, per_rank_names))
end

# The typed hipMalloc/hipFree/hipHostRegister families have no assumed-rank form:
# they take Fortran pointers or per-rank arrays, which either tier keeps.
emit_either_tier_proc_list(io, names) = emit_either_tier(io, o -> emit_proc_list(o, names))

# A scalar has no length form (only _source / _nosize), so drop _0 and _0_c_size_t.
drop_rank0_lengths(names) = filter(n -> !(endswith(n, "_0") || endswith(n, "_0_c_size_t")), names)

# `interface <gname>`: the bind(C) specific <gname>_ (C symbol <gname>, c_int
# result, dummies `decls`), then the module procedures written by `procs(io)`.
function emit_aux_generic(io, gname::String, args::String, decls::Vector{String},
                          procs::Function)
  raw = "$(gname)_"
  println(io, "  interface $(gname)")
  emit_aux_bind(io, "function $(raw)($(args))", gname)
  println(io, "      use iso_c_binding")
  println(io, "      implicit none")
  println(io, "      integer(c_int) :: $(raw)")
  for d in decls; println(io, "      $(d)"); end
  println(io, "    end function $(raw)")
  procs(io)
  println(io, "  end interface $(gname)")
  println(io, "")
end

emit_hipmalloc_generic(io) =
  emit_aux_generic(io, "hipMalloc", "ptr, sizeBytes",
                   ["type(c_ptr) :: ptr",
                    "integer(c_size_t), value :: sizeBytes"],
                   io -> emit_either_tier_proc_list(io, drop_rank0_lengths(
                           proc_list("hipMalloc"; suffixes=["", "_c_size_t", "_source"]))))

emit_flagged_alloc_generic(io, family::String) =
  emit_aux_generic(io, family, "ptr, sizeBytes, flags",
                   ["type(c_ptr) :: ptr",
                    "integer(c_size_t), value :: sizeBytes",
                    "integer(c_int), value :: flags"],
                   io -> emit_either_tier_proc_list(io, drop_rank0_lengths(
                           proc_list(family; suffixes=["", "_c_size_t", "_source"]))))

emit_free_generic(io, name::String) =
  emit_aux_generic(io, name, "ptr", ["type(c_ptr), value :: ptr"],
                   io -> emit_either_tier_proc_list(io, proc_list(name)))

function emit_memcpy_generic(io, family::String; pitched::Bool, isasync::Bool)
  args  = pitched ? "dest, dpitch, src, spitch, width, height, myKind" : "dest, src, sizeBytes, myKind"
  decls = pitched ? ["type(c_ptr), value :: dest",
                     "integer(c_size_t), value :: dpitch",
                     "type(c_ptr), value :: src",
                     "integer(c_size_t), value :: spitch",
                     "integer(c_size_t), value :: width",
                     "integer(c_size_t), value :: height",
                     "integer(c_int), value :: myKind"] :
                    ["type(c_ptr), value :: dest",
                     "type(c_ptr), value :: src",
                     "integer(c_size_t), value :: sizeBytes",
                     "integer(c_int), value :: myKind"]
  if isasync
    args *= ", stream"
    push!(decls, "type(c_ptr), value :: stream")
  end
  sufs = pitched ? ["_c_size_t", "_c_int"] : ["", "_c_size_t", "_c_int"]
  emit_aux_generic(io, family, args, decls,
                   io -> emit_guarded_proc_list(io, proc_list(family; suffixes=sufs),
                                                    ar_proc_list(family; suffixes=sufs)))
end

emit_hiphostregister_generic(io) =
  emit_aux_generic(io, "hipHostRegister", "hostPtr, sizeBytes, flags",
                   ["type(c_ptr), value :: hostPtr",
                    "integer(c_size_t), value :: sizeBytes",
                    "integer(c_int), value :: flags"],
                   io -> emit_either_tier_proc_list(io, drop_rank0_lengths(
                           proc_list("hipHostRegister"; suffixes=["_nosize", "", "_c_size_t"]))))

emit_hiphostunregister_generic(io) =
  emit_aux_generic(io, "hipHostUnregister", "hostPtr", ["type(c_ptr), value :: hostPtr"],
                   io -> emit_either_tier_proc_list(io, proc_list("hipHostUnregister")))

emit_hiphostgetdevicepointer_generic(io) =
  emit_aux_generic(io, "hipHostGetDevicePointer", "devPtr, hstPtr, flags",
                   ["type(c_ptr) :: devPtr",
                    "type(c_ptr), value :: hstPtr",
                    "integer(c_int), value :: flags"],
                   io -> emit_either_tier_proc_list(io, proc_list("hipHostGetDevicePointer")))

emit_hiphostgetflags_generic(io) =
  emit_aux_generic(io, "hipHostGetFlags", "flagsPtr, hostPtr",
                   ["integer(c_int) :: flagsPtr",
                    "type(c_ptr), value :: hostPtr"],
                   io -> emit_either_tier_proc_list(io, proc_list("hipHostGetFlags")))

function hipmemcpy_spec(io)
  for (family, pitched, isasync) in HIP_MEMCPY_FAMILIES
    emit_memcpy_generic(io, family; pitched=pitched, isasync=isasync)
  end
end

function hipmemcpy_body(io)
  # Same guard as emit_guarded_proc_list. per_rank_is_default: extra_wrappers are
  # already inside `#if defined(USE_ASSUMED_SHAPE) || defined(USE_ASSUMED_RANK)`.
  emit_tier_guard(io,
    function (o)
      for (family, pitched, isasync) in HIP_MEMCPY_FAMILIES
        emit_memcpy_impls(o, family; pitched=pitched, isasync=isasync, assumed=true)
      end
    end,
    function (o)
      for (family, pitched, isasync) in HIP_MEMCPY_FAMILIES
        emit_memcpy_impls(o, family; pitched=pitched, isasync=isasync)
      end
    end;
    per_rank_is_default = true)
end

function hipmalloc_spec(io)
  emit_hipmalloc_generic(io)
  emit_flagged_alloc_generic(io, "hipMallocManaged")
  emit_flagged_alloc_generic(io, "hipHostMalloc")
  emit_free_generic(io, "hipFree")
  emit_free_generic(io, "hipHostFree")
end

function hipmalloc_body(io)
  emit_hipmalloc_impls(io)
  emit_hipmalloc_source_impls(io)
  emit_hipmallocmanaged_impls(io)
  emit_hipmallocmanaged_source_impls(io)
  emit_hiphostmalloc_impls(io)
  emit_hiphostmalloc_source_impls(io)
  emit_hipfree_impls(io)
  emit_hiphostfree_impls(io)
end

function hiphostregister_spec(io)
  emit_hiphostregister_generic(io)
  emit_hiphostunregister_generic(io)
  emit_hiphostgetdevicepointer_generic(io)
  emit_hiphostgetflags_generic(io)
end

function hiphostregister_body(io)
  emit_hiphostregister_impls(io)
  emit_hiphostunregister_impls(io)
  emit_hiphostgetdevicepointer_impls(io)
  emit_hiphostgetflags_impls(io)
end

# The hipGetDeviceProperties generic, bound to the hipGetDevicePropertiesR0600
# symbol that the HIP header #defines it to.
function hip_auxiliary_spec(io)
  println(io, "  interface hipGetDeviceProperties")
  println(io, "    function hipGetDeviceProperties_(prop,deviceId) bind(c, name=\"hipGetDevicePropertiesR0600\")")
  println(io, "      use iso_c_binding")
  # The enums and types live in the enclosing `module hip`, hence IMPORT.
  println(io, "      import")
  println(io, "      implicit none")
  # c_int, not kind(hipSuccess): see c_int_if_enum in emit.jl.
  println(io, "      integer(c_int) :: hipGetDeviceProperties_")
  println(io, "      type(hipDeviceProp_t),intent(out) :: prop")
  println(io, "      integer(c_int),value :: deviceId")
  println(io, "    end function")
  println(io, "  end interface")
  println(io, "")
end
