// Copyright (C) 2026 Advanced Micro Devices, Inc. All rights reserved.
// SPDX-License-Identifier: MIT
/* The `nullable` fixture of the hipfort layout: nullable by-reference arguments
   (metadata/nlib.toml) in routines the NVIDIA backend binds to the CUDA driver API
   (cu*) or runtime (cuda*), as hipModuleGetGlobal and hipGraphGetNodes. */
#ifndef NLIB_H
#define NLIB_H

typedef __SIZE_TYPE__ size_t;
typedef struct nlib_module_s* nlibModule;

typedef enum nlib_status_t {
  NLIB_SUCCESS = 0,
  NLIB_FAILURE = 1
} nlibStatus;

/* As hipModuleGetGlobal: cuNlibGetGlobal, a driver entry point. */
nlibStatus nlibGetGlobal(void** dptr, size_t* bytes, nlibModule hmod, const char* name);
/* As hipGraphGetNodes: cudaNlibGetNodes, a runtime entry point. */
nlibStatus nlibGetNodes(nlibModule graph, void** nodes, size_t* numNodes);

#endif
