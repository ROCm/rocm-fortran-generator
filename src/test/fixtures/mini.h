// Copyright (C) 2026 Advanced Micro Devices, Inc. All rights reserved.
// SPDX-License-Identifier: MIT
/* Rich, self-contained fixture for the generator golden tests. Exercises the
   parse + type-mapping paths: opaque handle, enum (return + argument), complex
   buffers, a struct with scalar/array/enum fields, a #define constant, and a
   #define alias. No #include so the parse is deterministic and platform-free. */

#define MINI_VERSION 42

typedef void* mini_handle_t;

typedef enum {
  MINI_STATUS_SUCCESS = 0,
  MINI_STATUS_FAILURE = 1
} mini_status_t;

typedef enum {
  MINI_OP_N = 0,
  MINI_OP_T = 1
} mini_op_t;

typedef struct { float  x; float  y; } mini_float_complex;
typedef struct { double x; double y; } mini_double_complex;

typedef struct {
  int       count;
  float     scale;
  double    tol;
  int       dims[3];
  mini_op_t op;
} mini_params_t;

/** @brief Create a mini handle. */
mini_status_t mini_create(mini_handle_t* handle);

/** @brief Single-precision complex scale. */
mini_status_t mini_cscal(mini_handle_t handle, int n, mini_float_complex* x, mini_op_t op);

/** @brief Double scale with a tag and a host output. */
mini_status_t mini_dscal(mini_handle_t handle, int n, double* x, const char* tag, int* info);

mini_status_t mini_destroy(mini_handle_t handle);

/** @brief Read the handle's parameters into a struct. */
mini_status_t mini_get_params(mini_handle_t handle, mini_params_t* params);

/* The one void entry point, for the subroutine form of every emitter, with a
   handle, a buffer and a string. */

/** @brief Record a tagged sample (returns nothing). */
void mini_record(mini_handle_t handle, double* x, const char* tag);

/* Aliasable target (the hipGetDevicePropertiesR0600 shape): no handle, buffer or
   string, so needs_generic() is false and the alias loop emits the short name. */
mini_status_t mini_set_mode_v2(int mode);

mini_status_t mini_reset(void);

#define miniScale mini_dscal

/* Emitted: `interface mini_set_mode` whose specific binds to mini_set_mode_v2. */
#define mini_set_mode mini_set_mode_v2

/* NOT emitted: the short name is itself an entry point, so the alias would
   declare `interface mini_destroy` twice. */
#define mini_destroy mini_reset

/* The newer HIP spelling of a versioned name (hipChooseDevice): an inline function
   forwarding its parameters unchanged is an alias of its target. */
mini_status_t mini_choose_R0600(int device);
static inline mini_status_t mini_choose(int device) { return mini_choose_R0600(device); }

/* NOT an alias: the arguments are not passed through unchanged. */
static inline mini_status_t mini_choose_next(int device) { return mini_choose_R0600(device + 1); }
