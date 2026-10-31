/* Copyright (C) 2026 Advanced Micro Devices, Inc. All rights reserved.
 * SPDX-License-Identifier: MIT
 *
 * A rocblas.h for `gen.sh --explain` (src/test/gen_sh.sh): one function per
 * signature default, and one whose table overrides them. */
typedef struct _rocblas_handle* rocblas_handle;
typedef enum rocblas_status_ { rocblas_status_success = 0 } rocblas_status;

rocblas_status rocblas_daxpy(rocblas_handle handle, int n, const double* alpha,
                             const double* x, int incx, double* y, int incy);
rocblas_status rocblas_dfoo_buffer_size(rocblas_handle handle, int n, int* lwork);
rocblas_status rocblas_dbar(rocblas_handle handle, int n, const double* alpha,
                            const double* beta, double* work, double* scratch);
