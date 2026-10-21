// Copyright (C) 2026 Advanced Micro Devices, Inc. All rights reserved.
// SPDX-License-Identifier: MIT
/* Fixture for collect_funcs' three skip paths and the *_batched pointer-array
   rewrite. No #include, so the parse is deterministic and platform-free.

   Parse this one with -std=gnu17: in C23 an empty parameter list means (void),
   which would quietly turn the no-prototype assertion below into a vacuous one. */

/* Variadic: Fortran cannot declare `...`, and a fixed-arity binding is ABI-wrong
   (an x86-64 SysV variadic callee reads AL, left undefined). Dropped. */
int skips_log(const char* fmt, ...);

/* K&R empty parameter list -> CXType_FunctionNoProto, for which
   clang_isFunctionTypeVariadic also answers true. Must be kept (hipProfilerStart
   and other zero-argument HIP entry points have this shape). */
int skips_start();

/* Its prototyped twin. */
int skips_stop(void);

/* static inline: no symbol in the shared library to bind against. */
static inline int skips_inline(int n) { return n + 1; }

/* Batched, in both spellings of a T** device array of pointers (rocBLAS uses
   `T* const* A` for trmv/tpmv). Both go by value: the array's device address. */
int skips_sgemm_batched(float* const A[], float* const* B, float* C, int n);

/* The same two shapes in a NON-batched routine stay by reference: there they are
   host-side pointer arrays (rocfft_execute). */
int skips_sgemm(float* const A[], float* const* B, float* C, int n);
