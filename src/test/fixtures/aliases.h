// Copyright (C) 2026 Advanced Micro Devices, Inc. All rights reserved.
// SPDX-License-Identifier: MIT
// Fixture for collect_typedef_aliases: a struct typedef'd under its own tag AND
// under a second name. Both directions occur in ROCm headers, so the rule is
// "shortest spelling wins", the identity included.

// Pattern A (hipDeviceProp_t): the identity is shorter than the ABI-versioned
// typedef of the R0600 entry points and must win.
typedef struct aliasesA_t
{
    int x;
} aliasesA_t;
typedef aliasesA_t aliasesA_tR0600;

// Pattern B (hipFFTW's fftw_iodim): the identity is longer than the
// FFTW3-compatible alias the public signatures use and must lose.
typedef struct aliasesB_iodim
{
    int n;
} aliasesB_iodim;
typedef aliasesB_iodim aliasesB_io;
// A third, longer spelling (fftwf_iodim): never emitted, so an argument spelled
// with it takes the emitted name.
typedef aliasesB_iodim aliasesBf_io;

// Referenced through the spelling each pattern's public API uses.
void aliases_use(const aliasesA_tR0600 *a, const aliasesB_io *b);
void aliases_usef(const aliasesBf_io *b);
