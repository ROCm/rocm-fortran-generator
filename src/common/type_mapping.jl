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

# Kind of `t`, canonicalizing only an Elaborated type. Not a full canonicalize:
# record_ret_ftype / enum_first_const rely on a CXType_Typedef staying unresolved.
canon_kind(t) = (k = Clang.kind(t);
                 k == Clang.CXType_Elaborated ? Clang.kind(Clang.getCanonicalType(t)) : k)

# True for an input string (`const char*`); a non-const `char*` is an output buffer.
function is_string_arg(t)
  k = Clang.kind(t)
  if k == Clang.CXType_Pointer
    pt = Clang.getPointeeType(t)
    if Clang.kind(pt) in (Clang.CXType_Char_S, Clang.CXType_Char_U)
      return Clang.LibClang.clang_isConstQualifiedType(pt.type) != 0
    end
  end
  return false
end

# The intrinsic complex kind (c_float_complex/c_double_complex) of a ROCm complex
# struct, recognized by name, or nothing.
function complex_kind(spelling::AbstractString)
  n = lowercase(strip(replace(spelling, r"\b(const|struct|volatile)\b" => "", "*" => "")))
  (endswith(n, "double_complex") || endswith(n, "doublecomplex")) && return "c_double_complex"
  (endswith(n, "float_complex")  || endswith(n, "floatcomplex")   ||
        n in ("hipcomplex", "hipblascomplex", "hipsolvercomplex",
              "hipfftcomplex", "rocfft_complex")) && return "c_float_complex"
  return nothing
end

# 16-bit float structs (rocblas_half, hipblasHalf, …): a `T*` is a data buffer,
# so the pointee maps to integer(c_short) like the __half/__bf16 builtins.
function half_kind(spelling::AbstractString)
  n = lowercase(strip(replace(spelling, r"\b(const|struct|volatile)\b" => "", "*" => "")))
  (endswith(n, "bfloat16") || endswith(n, "_half") || endswith(n, "half") &&
     occursin(r"(rocblas|hipblas|hip|roc)", n)) ? "integer(c_short)" : nothing
end

# Bare type name: no qualifiers, no `*`, no ABI suffix (hipDeviceProp_tR0600).
clean_type_name(spelling::AbstractString) =
  replace(strip(replace(spelling, r"\b(const|struct|volatile)\b" => "", "*" => "")),
          r"R\d{4}$" => "")

# Width-exact typedefs, matched by name before canonicalization: on LLP64 (Windows)
# `long` is 32-bit, so size_t → unsigned long → c_long would be an ABI bug.
const _CKIND_TYPEDEFS = Dict{String,String}(
  "size_t"    => "integer(c_size_t)",
  # c_intptr_t, not c_ptrdiff_t (Fortran 2008); same width on LP64 and LLP64.
  "ssize_t"   => "integer(c_intptr_t)",
  "ptrdiff_t" => "integer(c_intptr_t)",
  "intptr_t"  => "integer(c_intptr_t)",
  "uintptr_t" => "integer(c_intptr_t)",
  "int64_t"   => "integer(c_int64_t)",
  "uint64_t"  => "integer(c_int64_t)",
  # Library typedefs of (u)int64_t.
  "rocblas_stride" => "integer(c_int64_t)",
  "hipblasStride"  => "integer(c_int64_t)",
  "roctx_range_id_t"  => "integer(c_int64_t)",
  "roctx_thread_id_t" => "integer(c_int64_t)",
  "int32_t"   => "integer(c_int32_t)",
  "uint32_t"  => "integer(c_int32_t)",
  "int16_t"   => "integer(c_int16_t)",
  "uint16_t"  => "integer(c_int16_t)",
  "int8_t"    => "integer(c_int8_t)",
  "uint8_t"   => "integer(c_int8_t)",
)
function typedef_ckind(spelling::AbstractString)
  s = strip(replace(String(spelling), r"\b(const|volatile)\b" => ""))
  return get(_CKIND_TYPEDEFS, s, nothing)
end

# The mappers below return (ftype::String, by_value::Bool).

# Array parameters decay to `T*`. An array of pointers (`void* x[]`) is a scalar
# c_ptr by reference; collect_funcs flips the *_batched device arrays to by value.
function _ftype_of_array(t)
  el    = Clang.getElementType(t)
  isptr = canon_kind(el) == Clang.CXType_Pointer
  isptr && return ("type(c_ptr)", false)
  return (first(cltype_to_fortran(el)), false)
end

# A named typedef passed by value.
function _ftype_of_elaborated(t)
  tk = typedef_ckind(Clang.spelling(t))
  tk !== nothing && return (tk, true)
  ct = Clang.getCanonicalType(t)
  ck = Clang.kind(ct)
  ck == Clang.CXType_Enum      && return ("integer(c_int)",     true)
  ck == Clang.CXType_Bool      && return ("logical(c_bool)",    true)
  # A typedef'd char by value is a character, not an address (else an unfillable c_ptr).
  ck == Clang.CXType_Char_S    && return ("character(c_char)",  true)
  ck == Clang.CXType_Char_U    && return ("character(c_char)",  true)
  ck == Clang.CXType_SChar     && return ("character(c_char)",  true)
  ck == Clang.CXType_UChar     && return ("character(c_char)",  true)
  ck == Clang.CXType_Half      && return ("integer(c_short)",   true)
  ck == Clang.CXType_BFloat16  && return ("integer(c_short)",   true)
  ck == Clang.CXType_Float     && return ("real(c_float)",      true)
  ck == Clang.CXType_Double    && return ("real(c_double)",     true)
  ck == Clang.CXType_Int       && return ("integer(c_int)",     true)
  ck == Clang.CXType_UInt      && return ("integer(c_int)",     true)
  ck == Clang.CXType_Short     && return ("integer(c_short)",   true)
  ck == Clang.CXType_UShort    && return ("integer(c_short)",   true)
  ck == Clang.CXType_Long      && return ("integer(c_long)",    true)
  ck == Clang.CXType_ULong     && return ("integer(c_long)",    true)
  ck == Clang.CXType_LongLong  && return ("integer(c_int64_t)", true)
  ck == Clang.CXType_ULongLong && return ("integer(c_int64_t)", true)
  if ck == Clang.CXType_Pointer
    pt = Clang.getPointeeType(ct)
    Clang.kind(pt) == Clang.CXType_FunctionProto && return ("type(c_funptr)", true)
    return ("type(c_ptr)", true)
  end
  if ck == Clang.CXType_Record
    cxk = complex_kind(Clang.spelling(t))
    cxk !== nothing && return ("complex($(cxk))", true)
    # A struct by value (dim3) is its bytes, not an address. Structs that are not
    # emitted are reverted to type(c_ptr) by revert_unknown_structs.
    return ("type($(clean_type_name(Clang.spelling(t))))", true)
  end
  record_unmapped_cptr!(Clang.spelling(t))
  return ("type(c_ptr)", true)
end

# Pointer types. The omissions vs the by-value tables (`short*`, a typedef'd `long*`,
# …) are deliberate and fall through to type(c_ptr); do not unify them.
function _ftype_of_pointer(t)
  pt  = Clang.getPointeeType(t)
  pk  = Clang.kind(pt)
  pk == Clang.CXType_Void             && return ("type(c_ptr)",        true)
  pk == Clang.CXType_Half             && return ("integer(c_short)",   false)  # __half*
  pk == Clang.CXType_BFloat16         && return ("integer(c_short)",   false)  # __bf16*
  pk == Clang.CXType_Float            && return ("real(c_float)",       false)
  pk == Clang.CXType_Double           && return ("real(c_double)",      false)
  pk == Clang.CXType_Int              && return ("integer(c_int)",      false)
  pk == Clang.CXType_UInt             && return ("integer(c_int)",      false)
  pk == Clang.CXType_Long             && return ("integer(c_long)",     false)
  pk == Clang.CXType_ULong            && return ("integer(c_long)",     false)
  pk == Clang.CXType_LongLong         && return ("integer(c_int64_t)",  false)
  pk == Clang.CXType_ULongLong        && return ("integer(c_int64_t)",  false)
  pk == Clang.CXType_Bool             && return ("logical(c_bool)",     false)
  pk == Clang.CXType_FunctionProto    && return ("type(c_funptr)",      true)
  # char* stays type(c_ptr), value rather than `character(c_char) :: x(*)`:
  # passing a character scalar to x(*) relies on sequence association, which
  # generic resolution (every routine sits in a named interface) does not allow.
  pk in (Clang.CXType_Char_S,
         Clang.CXType_Char_U,
         Clang.CXType_SChar,
         Clang.CXType_UChar)          && return ("type(c_ptr)",         true)
  pk == Clang.CXType_Enum             && return ("integer(c_int)",      false)
  if pk == Clang.CXType_Elaborated
    tk = typedef_ckind(Clang.spelling(pt))
    tk !== nothing && return (tk, false)
    ct2 = Clang.getCanonicalType(pt)
    ck2 = Clang.kind(ct2)
    ck2 == Clang.CXType_Enum         && return ("integer(c_int)",      false)
    ck2 == Clang.CXType_Bool         && return ("logical(c_bool)",     false)
    ck2 == Clang.CXType_Half         && return ("integer(c_short)",    false)
    ck2 == Clang.CXType_BFloat16     && return ("integer(c_short)",    false)
    ck2 == Clang.CXType_Float        && return ("real(c_float)",       false)
    ck2 == Clang.CXType_Double       && return ("real(c_double)",      false)
    ck2 == Clang.CXType_Int          && return ("integer(c_int)",      false)
    ck2 == Clang.CXType_UInt         && return ("integer(c_int)",      false)
    ck2 == Clang.CXType_LongLong     && return ("integer(c_int64_t)",  false)
    ck2 == Clang.CXType_ULongLong    && return ("integer(c_int64_t)",  false)
    ck2 == Clang.CXType_FunctionProto && return ("type(c_funptr)",     true)
    # handle* (struct**): output handle slot, scalar c_ptr by reference.
    ck2 == Clang.CXType_Pointer && return ("type(c_ptr)", false)
    # libclang presents a named struct pointee as Elaborated, so there is no
    # bare-Record pointee case.
    if ck2 == Clang.CXType_Record
      hk = half_kind(Clang.spelling(pt))
      hk !== nothing && return (hk, false)
      cxk = complex_kind(Clang.spelling(pt))
      cxk !== nothing && return ("complex($(cxk))", false)
      return ("type($(clean_type_name(Clang.spelling(pt))))", false)
    end
  end
  if pk == Clang.CXType_Pointer
    # T** (hipMalloc, batched arrays): scalar c_ptr by reference.
    return ("type(c_ptr)", false)
  end
  record_unmapped_cptr!(Clang.spelling(pt))
  return ("type(c_ptr)", true)
end

function cltype_to_fortran(t)
  k = Clang.kind(t)

  k in (Clang.CXType_IncompleteArray, Clang.CXType_ConstantArray) && return _ftype_of_array(t)

  k == Clang.CXType_Void       && return ("void",               true)
  k == Clang.CXType_Bool       && return ("logical(c_bool)",    true)
  k == Clang.CXType_Char_S     && return ("character(c_char)",  true)
  k == Clang.CXType_Char_U     && return ("character(c_char)",  true)
  k == Clang.CXType_SChar      && return ("character(c_char)",  true)
  k == Clang.CXType_UChar      && return ("character(c_char)",  true)
  k == Clang.CXType_Half       && return ("integer(c_short)",   true)
  k == Clang.CXType_BFloat16   && return ("integer(c_short)",   true)
  k == Clang.CXType_Float      && return ("real(c_float)",      true)
  k == Clang.CXType_Double     && return ("real(c_double)",     true)
  k == Clang.CXType_Int        && return ("integer(c_int)",     true)
  k == Clang.CXType_UInt       && return ("integer(c_int)",     true)
  k == Clang.CXType_Short      && return ("integer(c_short)",   true)
  k == Clang.CXType_UShort     && return ("integer(c_short)",   true)
  k == Clang.CXType_Long       && return ("integer(c_long)",    true)
  k == Clang.CXType_ULong      && return ("integer(c_long)",    true)
  k == Clang.CXType_LongLong   && return ("integer(c_int64_t)", true)
  k == Clang.CXType_ULongLong  && return ("integer(c_int64_t)", true)
  k == Clang.CXType_Enum       && return ("integer(c_int)",     true)

  k == Clang.CXType_Elaborated && return _ftype_of_elaborated(t)
  k == Clang.CXType_Pointer    && return _ftype_of_pointer(t)

  record_unmapped_cptr!(Clang.spelling(t))
  return ("type(c_ptr)", true)
end
