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

# No -e: the build and run loops below count failures instead of aborting.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "$ROOT/scripts/common.sh"

usage_spec() { cat <<'SPEC'
name:  run_all.sh
brief: build, and if a GPU is visible run, every end-to-end test
usage: bash tests/run_all.sh
env:   ROCM_PATH | /opt/rocm | ROCm install; its lib/ is prepended to LD_LIBRARY_PATH
exit:  0 | everything built, and ran if a GPU was visible
exit:  1 | a build failed, an executable was missing, or a test did not print PASSED
note:  Building needs a Fortran compiler ($FC, gfortran by default) and a ROCm
note:  install. Without a visible AMD GPU the tests are built and linked but not run.
SPEC
}
usage_peek "$@"

ROCM=${ROCM_PATH:-/opt/rocm}
export LD_LIBRARY_PATH="$ROCM/lib:${LD_LIBRARY_PATH:-}"

# test_name:library (empty for vecadd, which has its own build script)
TESTS=(
  "rocblas_saxpy:rocblas"
  "hipblas_dgemm:hipblas"
  "vecadd:"
)

have_gpu=false
rocm_have_gpu "$ROCM" && have_gpu=true

echo "=== Building tests ==="
fail=0
for entry in "${TESTS[@]}"; do
  name="${entry%%:*}"; lib="${entry##*:}"
  if [ "$name" = "vecadd" ]; then
    bash "$ROOT/tests/build_vecadd.sh" >/dev/null 2>&1 \
      && echo "  build OK : $name" || { echo "  build FAIL: $name"; fail=1; }
  else
    bash "$ROOT/tests/build.sh" "$ROOT/tests/$name.f90" "$lib" >/dev/null 2>&1 \
      && echo "  build OK : $name" || { echo "  build FAIL: $name"; fail=1; }
  fi
done

echo ""
if ! $have_gpu; then
  echo "No AMD GPU visible (rocminfo), skipping execution."
  echo "Executables are in tests/build/<name>/. Run them on a GPU host:"
  echo "  export LD_LIBRARY_PATH=$ROCM/lib:\$LD_LIBRARY_PATH; tests/build/<name>/<name>"
  exit $fail
fi

echo "=== Running tests (GPU detected) ==="
for entry in "${TESTS[@]}"; do
  name="${entry%%:*}"
  exe="$ROOT/tests/build/$name/$name"
  [ -x "$exe" ] || { echo "  MISSING : $name"; fail=1; continue; }
  if out="$("$exe" 2>&1)" && grep -q "PASSED" <<<"$out"; then
    echo "  PASS : $name"
  else
    echo "  FAIL : $name: $out"; fail=1
  fi
done
exit $fail
