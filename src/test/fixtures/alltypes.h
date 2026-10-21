// Copyright (C) 2026 Advanced Micro Devices, Inc. All rights reserved.
// SPDX-License-Identifier: MIT
/* Exhaustive type coverage for the C -> Fortran mapper (cltype_to_fortran and
 * its helpers): every C type shape a ROCm/HIP header can present, by value and
 * by pointer. Self-contained, no system headers. */

/* width-exact / stdint typedefs (typedef_ckind matches by name) */
typedef unsigned long size_t;
typedef long          int64_t;
typedef int           int32_t;
typedef short         int16_t;
typedef signed char   int8_t;
typedef unsigned long uint64_t;
typedef unsigned int  uint32_t;

/* typedefs canonicalizing to each scalar, used BY VALUE (elaborated-canonical) */
typedef _Bool         at_bool_t;
typedef short         at_short_t;
typedef unsigned short at_ushort_t;
typedef int           at_int_t;
typedef unsigned int  at_uint_t;
typedef long          at_long_t;
typedef unsigned long at_ulong_t;
typedef long long     at_ll_t;
typedef unsigned long long at_ull_t;
typedef float         at_float_t;
typedef double        at_double_t;
typedef char          at_char_t;      /* canonical Char -> character(c_char) by value */
typedef void*         at_vptr_t;      /* canonical Pointer (non-funcproto) */
typedef void (*at_fp_t)(int);         /* canonical Pointer -> FunctionProto */
typedef struct { int a; } at_rec_t;   /* canonical Record (by value) */
typedef enum { AT_A = 0, AT_B } at_enum_t;

/* direct tagged structs, used through struct X* rather than a typedef */
struct at_plain              { int a; };
struct at_hip_half           { short v; };     /* half_kind: ends "half" + hip */
struct at_bare_float_complex { float x, y; };  /* complex_kind */

/* --- builtin scalars, by value --- */
void at_scalars(_Bool b, char c, signed char sc, unsigned char uc,
                short s, unsigned short us, int i, unsigned u,
                long l, unsigned long ul, long long ll, unsigned long long ull,
                float f, double d);

/* --- pointers to builtin scalars (short and ushort deliberately fall through) --- */
void at_ptrs(_Bool* bp, short* sp, unsigned short* usp, int* ip, unsigned* up,
             long* lp, unsigned long* ulp, long long* llp, unsigned long long* ullp,
             float* fp, double* dp, void* vp, void** vpp, char* cp, const char* ccp);

/* long double* -> unhandled pointee kind -> pointer fallthrough */
void at_longdouble(long double* p);

/* long double by value -> unhandled top-level kind -> dispatcher fallthrough */
void at_oddscalar(long double ld);

/* width typedefs, by value and by pointer */
void at_widths(size_t n, int64_t s64, int32_t s32, int16_t s16, int8_t s8,
               uint64_t u64, uint32_t u32);
void at_widthptrs(size_t* np, int64_t* s64p, int32_t* s32p);

/* char typedef by value and by pointer (elaborated Char fallthrough branches) */
void at_chartd(at_char_t c, at_char_t* p);

/* typedefs used by value (elaborated-canonical scalar/pointer/record/enum) */
void at_byval(at_bool_t b, at_short_t s, at_ushort_t us, at_int_t i, at_uint_t u,
              at_long_t l, at_ulong_t ul, at_ll_t ll, at_ull_t ull,
              at_float_t f, at_double_t d, at_vptr_t vp, at_fp_t fp,
              at_rec_t r, at_enum_t e);

/* direct tagged-struct pointers: plain / half / complex (Elaborated pointee, canonical Record) */
void at_directrecs(struct at_plain* p, struct at_hip_half* h,
                   struct at_bare_float_complex* c);

/* typedef'd struct pointer (elaborated -> Record sub-block) */
void at_tdrec(at_rec_t* r);

/* enum by value and by pointer */
void at_enums(at_enum_t e, at_enum_t* ep);

/* arrays: scalar element, array-of-pointers, fixed-size */
void at_arrays(int scal[], void* ptrs[], int fixed[4]);

/* function pointer by value */
void at_fptr(void (*cb)(int));
