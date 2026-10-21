// Copyright (C) 2026 Advanced Micro Devices, Inc. All rights reserved.
// SPDX-License-Identifier: MIT
/* Fixture for the C -> Fortran type mapper (cltype_to_fortran and its
 * _ftype_of_array/_elaborated/_pointer helpers). Each tm_* function exercises a
 * distinct branch. Parsed directly with collect_funcs; the resulting ArgInfo
 * ftype/suffix pairs are asserted in runtests.jl. Width-exact typedefs are
 * declared by name (typedef_ckind matches on the name, not the canonical type),
 * so no system headers are needed. */

typedef unsigned long size_t;
typedef long          int64_t;
typedef int           int32_t;

typedef struct tm_params { int x; } tm_params_t;
typedef enum { TM_A = 0, TM_B = 1 } tm_op_t;

void tm_scalars(size_t n, int64_t s, int32_t w);
void tm_ptrs(size_t* np, int64_t* sp, double* buf, char* str, void** pp);
void tm_enums(tm_op_t op, tm_op_t* opp);
void tm_struct(tm_params_t* p);
void tm_funptr(void (*cb)(int));
