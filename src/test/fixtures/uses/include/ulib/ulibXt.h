// Copyright (C) 2026 Advanced Micro Devices, Inc. All rights reserved.
// SPDX-License-Identifier: MIT
/* The extension header of the `uses` fixture, as hipfftXt.h: the ulibXt module,
   which uses ulib. */
#ifndef ULIBXT_H
#define ULIBXT_H

#include "ulib/ulib.h"

#define ULIB_XT_MAX_GPUS 8

typedef enum ulib_xt_format_t {
  ULIB_XT_FORMAT_INPUT  = 0,
  ULIB_XT_FORMAT_OUTPUT = 1
} ulibXtFormat;

typedef struct ulibXtDesc_t {
  int   nGPUs;
  void* data[8];
} ulibXtDesc;

ulibStatus ulibXtMalloc(ulibHandle plan, ulibXtDesc** desc, ulibXtFormat format);
ulibStatus ulibXtFree(ulibXtDesc* desc);

#endif
