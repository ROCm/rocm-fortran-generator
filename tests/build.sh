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

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/common.sh"

usage_spec() { cat <<'SPEC'
name:  build.sh
brief: build one end-to-end test against the generated modules in fortran/
usage: bash tests/build.sh <test.f90> <lib>
arg:   test.f90 | the test program to build
arg:   lib      | the library module it uses: rocblas, hipblas, rocsolver, ...
env:   FORTRAN_DIR | fortran   | the generated modules to build against
env:   FC          | gfortran  | Fortran compiler
env:   ROCM_PATH   | /opt/rocm | ROCm install to link against
exit:  0 | binary at tests/build/<test>/<test>
exit:  1 | fortran/ not generated, or a compile or link step failed
exit:  2 | missing argument
note:  -DUSE_ASSUMED_SHAPE=1 enables the typed array interfaces the tests call
note:  (pointer-shaped hipMalloc/hipMemcpy, the BLAS array generics).
note:
note:  Only the HIP module, the requested library's module and the library modules
note:  it uses (rocsolver uses rocblas) are built, and linked.
SPEC
}
usage_peek "$@"

[ $# -ge 2 ] || usage_error "need <test.f90> and <lib>"
TEST="$1"; LIB="$2"

DIR="${FORTRAN_DIR:-$ROOT/fortran}"
base="$(basename "$TEST" .f90)"
BUILD="$ROOT/tests/build/$base"; rm -rf "$BUILD"; mkdir -p "$BUILD"
FC=${FC:-gfortran}
FFLAGS="-std=f2018"
GUARDS="-DUSE_ASSUMED_SHAPE=1"
ROCM=${ROCM_PATH:-/opt/rocm}

# The library modules $LIB itself uses (rocsolver uses rocblas).
DEPS=()
if [ -f "$DIR/rocm-libraries/$LIB/$LIB.F90" ]; then
  for m in $(grep -oE '^ *use [a-z_]+' "$DIR/rocm-libraries/$LIB/$LIB.F90" | awk '{print $2}' | sort -u); do
    [ -d "$DIR/rocm-libraries/$m" ] && [ "$m" != "$LIB" ] && DEPS+=("$m")
  done
fi
DEP_DIRS=(); DEP_LIBS=()
for m in ${DEPS[@]+"${DEPS[@]}"}; do DEP_DIRS+=("$DIR/rocm-libraries/$m"); DEP_LIBS+=("-l$m"); done

fort_scan_srcdirs "$DIR/rocm-systems/fortran" "$DIR/rocm-libraries/$LIB" \
                  ${DEP_DIRS[@]+"${DEP_DIRS[@]}"} || die_need_gen "No Fortran sources under $DIR"

on_fail() {
  printf 'COMPILE FAILED: %s\n' "$(fort_modname "$1")"
  sed -n '1,8s/^/    /p' "$(fort_errfile "$1")"
  exit 1
}

# -cpp: the modules carry #ifdef guards.
fort_session --fc "$FC" --flags "$FFLAGS -cpp $GUARDS" \
             --moddir "$BUILD" --objdir "$BUILD" --errdir "$BUILD" \
             --on-pass fort_quiet_pass --on-fail on_fail
fort_build_tree

$FC -c $FFLAGS -I"$BUILD" -o "$BUILD/$base.o" "$TEST"
echo "COMPILE OK: $base"

# Only the objects the test needs: rocm-systems/fortran/ also holds roctx.
OBJS=("$BUILD/$base.o" "$BUILD/hip.o" "$BUILD/$LIB.o")
for m in ${DEPS[@]+"${DEPS[@]}"}; do OBJS+=("$BUILD/$m.o"); done
if $FC -no-pie -o "$BUILD/$base" "${OBJS[@]}" -L"$ROCM/lib" -l"$LIB" ${DEP_LIBS[@]+"${DEP_LIBS[@]}"} -lamdhip64 2>"$BUILD/link.err"; then
  echo "LINK OK: $BUILD/$base"
else
  echo "LINK FAILED:"; sed -n '1,8s/^/    /p' "$BUILD/link.err"
  exit 1
fi
