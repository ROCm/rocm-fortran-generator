// Copyright (C) 2026 Advanced Micro Devices, Inc. All rights reserved.
// SPDX-License-Identifier: MIT
/* The base header of the `uses` fixture, as hipfft.h: the ulib module. */
#ifndef ULIB_H
#define ULIB_H

#define ULIB_FORWARD -1

typedef struct ulib_plan_s* ulibHandle;

typedef enum ulib_status_t {
  ULIB_SUCCESS = 0,
  ULIB_FAILURE = 1
} ulibStatus;

ulibStatus ulibCreate(ulibHandle* plan);
ulibStatus ulibExec(ulibHandle plan, float* data, int direction);
/* An Xt function the base header declares, as hipfft.h's hipfftXtSetWorkArea. */
ulibStatus ulibXtSetArea(ulibHandle plan, void* area);

#endif
