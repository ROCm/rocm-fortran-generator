// Copyright (C) 2026 Advanced Micro Devices, Inc. All rights reserved.
// SPDX-License-Identifier: MIT
// Fixture source-checkout header for synth_generated_headers: it includes the
// headers a build would generate, as the ROCm libraries spell them.
#include "verlib/verlib_version.h"   // from verlib_version.h.in
#include "verlib/verlib-config.h"    // from the flat ../verlib-config.h.in
#include "internal/verlib-export.h"  // generate_export_header output
#include <hip/hip_runtime_api.h>     // includes <hip/hip_version.h>
#include <stdint.h>                  // a system header: not synthesized

VERLIB_EXPORT int verlib_answer(void);
