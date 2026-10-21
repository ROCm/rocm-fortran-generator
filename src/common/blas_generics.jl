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

# Typed array overloads for the hipBLAS / rocBLAS Set/Get Vector/Matrix helpers.
# The helpers take their buffers as void* and an element size, so these overloads
# are emitted here, one per element type and shape. The bind(C) specifics come
# from the headers like any other function's; blas_aux_hooks lists these overloads
# in the same generics (extra_procs).

# (tag, Fortran type, elem_size passed to the bind(C) interface)
const BLAS_GEN_TYPES = [
  ("l",  "logical(c_bool)",           "1"),
  ("i4", "integer(c_int)",            "4"),
  # c_int64_t, not c_long: c_long is 4 bytes on Windows (LLP64), which would make
  # the i8 specific ambiguous with the i4 one.
  ("i8", "integer(c_int64_t)",        "8"),
  ("r4", "real(c_float)",             "4"),
  ("r8", "real(c_double)",            "8"),
  ("c4", "complex(c_float_complex)",  "2*4"),
  ("c8", "complex(c_double_complex)", "2*8"),
]

# (hipBLAS name, rocBLAS name, :vector | :matrix, async?)
const BLAS_FAMILIES = [
  ("hipblasSetVector",      "rocblas_set_vector",       :vector, false),
  ("hipblasGetVector",      "rocblas_get_vector",       :vector, false),
  ("hipblasSetMatrix",      "rocblas_set_matrix",       :matrix, false),
  ("hipblasGetMatrix",      "rocblas_get_matrix",       :matrix, false),
  ("hipblasSetVectorAsync", "rocblas_set_vector_async", :vector, true),
  ("hipblasGetVectorAsync", "rocblas_get_vector_async", :vector, true),
  ("hipblasSetMatrixAsync", "rocblas_set_matrix_async", :matrix, true),
  ("hipblasGetMatrixAsync", "rocblas_get_matrix_async", :matrix, true),
]

blas_generic_name(fam, naming) = naming === :camel ? fam[1] : fam[2]

# Vectors: scalar and rank-1. Matrices: rank-2 (ld inferred), scalar and rank-1
# (explicit ld), as in hipfort.
blas_shapes(kind) = kind === :vector ? ["rank_0", "full_rank"] :
                                       ["full_rank", "rank_0", "rank_1"]


# Per family generic, its (per-rank, assumed-rank) overloads. Under USE_ASSUMED_RANK
# one assumed-rank specific per element type replaces the per-rank set.
function blas_aux_procs(naming) :: Dict{String,Tuple{Vector{String},Vector{String}}}
  d = Dict{String,Tuple{Vector{String},Vector{String}}}()
  for fam in BLAS_FAMILIES
    gname = blas_generic_name(fam, naming)
    per = ["$(gname)_$(tag)_$(sh)" for (tag, _, _) in BLAS_GEN_TYPES for sh in blas_shapes(fam[3])]
    d[gname] = (per, ["$(gname)_$(tag)_assumed_rank" for (tag, _, _) in BLAS_GEN_TYPES])
  end
  return d
end

# Wrapper bodies for one family: the per-rank set, or with `assumed=true` one
# dimension(..) specific per element type (taking explicit lda/ldb for matrices).
function emit_blas_impls(io, fam, naming, status; assumed=false)
  gname = blas_generic_name(fam, naming)
  raw   = gname * "_"
  kind  = fam[3]; isasync = fam[4]
  streamarg  = isasync ? ",stream" : ""
  shapes = assumed ? ["assumed_rank"] : blas_shapes(kind)
  for (tag, ftype, bytes) in BLAS_GEN_TYPES, sh in shapes
    fn = "$(gname)_$(tag)_$(sh)"
    if kind === :vector
      dimattr = sh == "rank_0" ? "" :
                sh == "assumed_rank" ? ",dimension(..)" : ",dimension(:)"
      println(io, "    function $(fn)(n,x,incx,y,incy$(streamarg)) result(ret)")
      println(io, "      use iso_c_binding")
      println(io, "      implicit none")
      println(io, "      integer(kind($(status))) :: ret")
      println(io, "      integer(c_int),value :: n")
      println(io, "      $(ftype),target$(dimattr) :: x")
      println(io, "      integer(c_int),value :: incx")
      println(io, "      $(ftype),target$(dimattr) :: y")
      println(io, "      integer(c_int),value :: incy")
      isasync && println(io, "      type(c_ptr),value :: stream")
      println(io, "      !")
      println(io, "      ret = $(raw)(n,$(bytes),c_loc(x),incx,c_loc(y),incy$(streamarg))")
      println(io, "    end function")
      println(io, "")
    else
      fullrank = sh == "full_rank"   # rank-2 form, ld inferred via size()
      dimattr = sh == "rank_0" ? "" :
                sh == "assumed_rank" ? ",dimension(..)" :
                fullrank ? ",dimension(:,:)" : ",dimension(:)"
      argl = fullrank ? "rows,cols,A,B" : "rows,cols,A,lda,B,ldb"
      println(io, "    function $(fn)($(argl)$(streamarg)) result(ret)")
      println(io, "      use iso_c_binding")
      println(io, "      implicit none")
      println(io, "      integer(kind($(status))) :: ret")
      println(io, "      integer(c_int),value :: rows")
      println(io, "      integer(c_int),value :: cols")
      println(io, "      $(ftype),target$(dimattr) :: A")
      fullrank || println(io, "      integer(c_int),value :: lda")
      println(io, "      $(ftype),target$(dimattr) :: B")
      fullrank || println(io, "      integer(c_int),value :: ldb")
      isasync && println(io, "      type(c_ptr),value :: stream")
      println(io, "      !")
      if fullrank
        println(io, "      ret = $(raw)(rows,cols,$(bytes),c_loc(A),size(A,1),c_loc(B),size(B,1)$(streamarg))")
      else
        println(io, "      ret = $(raw)(rows,cols,$(bytes),c_loc(A),lda,c_loc(B),ldb$(streamarg))")
      end
      println(io, "    end function")
      println(io, "")
    end
  end
end

# Wired into gen_files as extra_wrappers by blas_aux_hooks.
function emit_blas_aux_impls(io, naming, status)
  # The same tiers as the generic lists the overloads in (blas_aux_procs, emit_generic).
  # per_rank_is_default: extra_wrappers are already inside
  # `#if defined(USE_ASSUMED_SHAPE) || defined(USE_ASSUMED_RANK)`.
  emit_tier_guard(io,
    o -> for fam in BLAS_FAMILIES; emit_blas_impls(o, fam, naming, status; assumed=true); end,
    o -> for fam in BLAS_FAMILIES; emit_blas_impls(o, fam, naming, status); end;
    per_rank_is_default = true)
end
