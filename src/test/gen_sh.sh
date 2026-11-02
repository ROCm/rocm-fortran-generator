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
# checks. Every case stops before a header is parsed, but --explain, which parses
# a fixture rocblas.h, so this needs neither ROCm nor a GPU: the checkouts and the
# installed include dir are skeletons.
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
expect 0 "C signature: headers not read; no HIP headers" \
  env ROCM_INCLUDE="$TMP/empty" ./gen.sh --explain rocblas_srot_64
expect 2 "needs a C function name" ./gen.sh --explain
expect 1 "not a ROCm include dir" env ROCM_INCLUDE="$TMP/empty" ./gen.sh
expect 1 "Include dir not found for rocblas" env ROCM_INCLUDE="$INST" ./gen.sh rocblas
expect 1 "FAILED to generate" env ROCM_INCLUDE="$INST" ./gen.sh   # an empty hip/: no longer exit 0
# --explain, from a rocm-libraries checkout holding the fixture rocblas.h and its
# metadata: one parse, whatever the number of functions named.
CK="$TMP/ck/projects/rocblas"
mkdir -p "$CK/library/include" "$CK/fortran/metadata"
cp src/test/fixtures/explain/rocblas.h "$CK/library/include/"
cp src/test/fixtures/explain/rocblas.toml "$CK/fortran/metadata/"
out="$(env ROCM_INCLUDE="$INST" ROCM_LIBRARIES="$TMP/ck" \
         ./gen.sh --explain rocblas_daxpy rocblas_dfoo_buffer_size rocblas_dbar rocblas_dnope 2>&1)"
for text in \
  'alpha = "scalar-pointer-mode"   (default: pointer mode: a const alpha or beta)' \
  'lwork = "scalar-host"   (default: size query: its last integer output)' \
  '  [rocblas_dbar]' \
  'alpha: the table only repeats the default "scalar-pointer-mode"' \
  'beta: the table ("scalar-host") overrides the default "scalar-pointer-mode"' \
  'work   (default: workspace, type(c_ptr))' \
  'scratch: the table ("1d") overrides the default (workspace, type(c_ptr))' \
  'rocblas_dnope is not declared in'; do
  if grep -qF -- "$text" <<< "$out"; then
    printf 'PASS  --explain: %s\n' "$text"
  else
    printf 'FAIL  --explain: %s\n      output:\n%s\n' "$text" "$out"; fail=1
  fi
done

[ ! -e "$ROCM_FORTRAN_OUT/rocm-libraries/rocblas" ] || { echo "FAIL  a failed run left a module"; fail=1; }

exit "$fail"
