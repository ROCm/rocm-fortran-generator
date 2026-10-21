#!/usr/bin/env bash
###############################################################################
# Copyright (C) 2026 Advanced Micro Devices, Inc. All rights reserved.
#
# SPDX-License-Identifier: MIT
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#
###############################################################################

# gen.sh's command line: its options, the library selection and the --overwrite
# checks. Every case stops before a header is parsed, so this needs neither ROCm
# nor a GPU: the checkouts and the installed include dir are empty skeletons.
#
# Usage (from the repo root, after Pkg.instantiate): bash src/test/gen_sh.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

LIBS="$TMP/rocm-libraries"
INST="$TMP/include"
mkdir -p "$LIBS/projects/rocblas/library/include" "$INST/hip" "$TMP/empty"
# Never the developer's fortran/, even if a check below regressed and generated.
export ROCM_FORTRAN_OUT="$TMP/out"

fail=0
# expect <exit code> <text the output must contain> <command...>
expect() {
  local code="$1" text="$2"; shift 2
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [ "$rc" -eq "$code" ] && grep -qF -- "$text" <<< "$out"; then
    printf 'PASS  %s\n' "$*"
  else
    printf 'FAIL  %s\n      exit %s (expected %s), output:\n%s\n' "$*" "$rc" "$code" "$out"
    fail=1
  fi
}

cd "$ROOT"
expect 0 "--overwrite" ./gen.sh --help
expect 2 "unknown option '--foo'" ./gen.sh --foo
expect 1 "unknown library rocblass" \
  env ROCM_INCLUDE="$INST" ROCM_LIBRARIES="$LIBS" ./gen.sh rocblass
expect 1 "it comes from rocm-systems, so set ROCM_SYSTEMS" \
  env ROCM_INCLUDE="$INST" ROCM_LIBRARIES="$LIBS" ./gen.sh hip
expect 1 "--overwrite needs ROCM_LIBRARIES or ROCM_SYSTEMS" \
  env ROCM_INCLUDE="$INST" ./gen.sh --overwrite rocblas
expect 1 "projects/rocblas/fortran does not exist" \
  env ROCM_INCLUDE="$INST" ROCM_LIBRARIES="$LIBS" ./gen.sh --overwrite rocblas
expect 1 "not a ROCm include dir" env ROCM_INCLUDE="$TMP/empty" ./gen.sh
expect 1 "Include dir not found for rocblas" env ROCM_INCLUDE="$INST" ./gen.sh rocblas
expect 1 "FAILED to generate" env ROCM_INCLUDE="$INST" ./gen.sh   # an empty hip/: no longer exit 0
expect 1 "not a rocm-libraries checkout" env ROCM_LIBRARIES="$TMP/empty" bash refresh_ptrmode.sh
[ ! -e "$ROCM_FORTRAN_OUT/rocm-libraries/rocblas" ] || { echo "FAIL  a failed run left a module"; fail=1; }

exit "$fail"
