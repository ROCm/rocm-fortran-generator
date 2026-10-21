// Copyright (C) 2026 Advanced Micro Devices, Inc. All rights reserved.
// SPDX-License-Identifier: MIT
/* Richer fixture exercising the deeper branches of the frontend and the type
 * mapper: array parameters, typedefs used by value (canonical scalar/record/
 * pointer/function-pointer), pointers to complex/half structs, struct fields
 * (doc comments, function pointers, nested records), inter-struct dependencies
 * (topological order), versioned-alias dedup, and macro value parsing.
 * Parsed with collect_* in runtests.jl; no system headers needed. */

/* --- typedefs used BY VALUE (cltype_to_fortran elaborated-canonical branches) --- */
typedef int    elab_int_t;
typedef double elab_dbl_t;
typedef void*  elab_vptr_t;
typedef void (*elab_fp_t)(int);
typedef struct rich_byval { int a; } rich_byval_t;

/* --- complex / half structs (pointer-to-record branches) --- */
typedef struct { float  x, y; } rich_float_complex;
typedef struct { double x, y; } rich_double_complex;
typedef struct { short  v;    } rich_half;          /* name ends "half" + rich~ -> half_kind */

/* --- structs with rich fields + dependencies --- */
typedef struct rich_inner { int a; double b; } rich_inner_t;

typedef struct rich_outer {
  int          n;                 ///< the count
  rich_inner_t inner;             /* nested record field -> dependency */
  void       (*callback)(int);    /* function-pointer field */
  float        v[3];              ///< a small vector
} rich_outer_t;

/* versioned-alias dedup: two typedefs for the same tag, shorter name wins */
typedef struct rich_tag { int z; } rich_tag_tR0600;
typedef struct rich_tag rich_tag_t;

/* --- macros: plain, parenthesised, and 64-bit --- */
#define RICH_PLAIN 7
#define RICH_PAREN (42)
#define RICH_BIG   5000000000
#define RICH_HUGE  99999999999999999999   /* > Int64 -> dropped */

/* --- functions exercising the mapper --- */
void rich_arrays(int scal[], void* ptrs[]);
void rich_byvalue(elab_int_t i, elab_dbl_t d, elab_vptr_t p, elab_fp_t f, rich_byval_t s);
void rich_cplx(rich_float_complex* c, rich_double_complex* z, rich_half* h);
void rich_struct(rich_outer_t* o);
