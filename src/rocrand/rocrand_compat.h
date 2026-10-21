///////////////////////////////////////////////////////////////////////////////
// Copyright (C) 2026 Advanced Micro Devices, Inc. All rights reserved.
//
// SPDX-License-Identifier: MIT
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
//
///////////////////////////////////////////////////////////////////////////////

/* Force-included before rocrand.h, which includes C++ HIP headers (hip_fp16.h,
 * hip_runtime.h, hip_vector_types.h) that libclang cannot parse as C: their
 * include guards are pre-defined and the few types the public API uses are
 * stubbed. __half is `unsigned short`, so half values map to integer(c_short) as
 * in hipfort.
 */
#ifndef ROCRAND_COMPAT_H
#define ROCRAND_COMPAT_H

#include <stddef.h>   /* size_t, otherwise lost by blocking hip_runtime.h */

#define HIP_INCLUDE_HIP_HIP_FP16_H
#define HIP_INCLUDE_HIP_HIP_RUNTIME_H
#define HIP_INCLUDE_HIP_HIP_VECTOR_TYPES_H

typedef unsigned short __half;
typedef struct { unsigned short x, y; } __half2;
typedef void *hipStream_t;
typedef struct { unsigned int x, y, z, w; } uint4;

#endif /* ROCRAND_COMPAT_H */
