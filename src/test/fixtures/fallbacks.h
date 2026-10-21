// Copyright (C) 2026 Advanced Micro Devices, Inc. All rights reserved.
// SPDX-License-Identifier: MIT
/* Cases the frontend used to map silently and wrongly. */
struct fb_fwd;                          /* forward declaration, defined below */
struct fb_fwd { int a; double b; };
struct fb_flex { int n; double v[]; };  /* flexible array member */
struct fb_byval { int x; };
void fb_case(int N, int n);             /* dummy names equal but for case */
void fb_takes(struct fb_byval v);       /* a struct by value */
#define FB_OCT 010
#define FB_DEC 10
#define FB_HEX 0x10
