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
name:  build_vecadd.sh
brief: build the vecadd test, a Fortran driver plus a HIP C++ kernel built with hipcc
usage: bash tests/build_vecadd.sh
env:   FORTRAN_DIR | fortran   | the generated modules to build against
env:   FC          | gfortran  | Fortran compiler
env:   ROCM_PATH   | /opt/rocm | ROCm install to link against
env:   HIPCC       | $ROCM_PATH/bin/hipcc | HIP C++ compiler for the kernel
exit:  0 | binary at tests/build/vecadd/vecadd
exit:  1 | fortran/ not generated, or a compile or link step failed
note:  Only the HIP module (rocm-systems/fortran/hip.F90) is linked: the driver calls no library.
note:
note:  -DUSE_ASSUMED_SHAPE=1 enables the pointer-shaped hipMalloc/hipMemcpy the
note:  driver calls.
SPEC
}
usage_peek "$@"

DIR="${FORTRAN_DIR:-$ROOT/fortran}"
BUILD="$ROOT/tests/build/vecadd"; rm -rf "$BUILD"; mkdir -p "$BUILD"
FC=${FC:-gfortran}
# f2018: amdflang accepts no other -std value.
FFLAGS="-std=f2018"
GUARDS="-DUSE_ASSUMED_SHAPE=1"
ROCM=${ROCM_PATH:-/opt/rocm}
HIPCC=${HIPCC:-$ROCM/bin/hipcc}

fort_scan_srcdirs "$DIR/rocm-systems/fortran" || die_need_gen "No Fortran sources under $DIR"

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

$FC -c $FFLAGS -I"$BUILD" -o "$BUILD/vecadd_main.o" "$ROOT/tests/vecadd_main.f90"
echo "COMPILE OK: vecadd_main (Fortran)"

$HIPCC -c "$ROOT/tests/vecadd_kernel.cpp" -o "$BUILD/vecadd_kernel.o"
echo "COMPILE OK: vecadd_kernel (hipcc)"

if $FC -no-pie -o "$BUILD/vecadd" "$BUILD/vecadd_main.o" "$BUILD/vecadd_kernel.o" "$BUILD/hip.o" \
       -L"$ROCM/lib" -lamdhip64 -lstdc++ 2>"$BUILD/link.err"; then
  echo "LINK OK: $BUILD/vecadd"
else
  echo "LINK FAILED:"; sed -n '1,10s/^/    /p' "$BUILD/link.err"
  exit 1
fi
