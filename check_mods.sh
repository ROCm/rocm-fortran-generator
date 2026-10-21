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

. "$(cd "$(dirname "$0")" && pwd)/scripts/common.sh"

usage_spec() { cat <<'SPEC'
name:  check_mods.sh
brief: compile the generated Fortran modules with gfortran to verify they are valid
usage: bash check_mods.sh [--mod]
flag:  --mod | keep the .mod files, all in the first source directory (fortran/rocm-systems/fortran/), instead of a throwaway dir
env:   ROCM_FORTRAN_DIR | - | compile this directory instead of fortran/rocm-systems/ and fortran/rocm-libraries/ (e.g. an out-of-tree generation)
exit:  0 | every module compiled
exit:  1 | a module failed, or fortran/ has not been generated yet
exit:  2 | unknown flag
note:  Targets Fortran 2018 and does not link against ROCm. Every module is compiled
note:  three times: with neither array-interface macro, with USE_ASSUMED_SHAPE and
note:  with USE_ASSUMED_RANK, so both tiers of array overloads are checked.
note:  For the other compilers, see check_compilers.sh.
SPEC
}
usage_peek "$@"

BASE="$(cd "$(dirname "$0")" && pwd)/fortran"

WRITE_MOD=false
for a in "$@"; do
  case "$a" in
    --mod) WRITE_MOD=true ;;
    *) usage_error "unknown flag '$a'" ;;
  esac
done

if [ -n "${ROCM_FORTRAN_DIR:-}" ]; then
  ROOTS=("$ROCM_FORTRAN_DIR")
else
  ROOTS=("$BASE/rocm-systems" "$BASE/rocm-libraries")
fi

fort_scan_srcdirs "${ROOTS[@]}" || die_need_gen "No Fortran sources under: ${ROOTS[*]}"

make_tmpdir
MODDIR="$TMP"; $WRITE_MOD && MODDIR="${FORT_SRCDIRS[0]}"

echo "${#FORT_SRCDIRS[@]} source dirs"

# -cpp also preprocesses .f90, so a guard emitted into a .f90 cannot slip through.
# The configuration without a macro runs last, so --mod keeps its .mod files.
fails=0
for guard in -DUSE_ASSUMED_SHAPE=1 -DUSE_ASSUMED_RANK=1 ""; do
  echo ""
  echo "== ${guard:-no array-interface macro}"
  fort_session --fc gfortran --flags "-std=f2018 -cpp $guard" \
               --moddir "$MODDIR" --objdir "$TMP" --errdir "$TMP"
  fort_build_tree || true   # the summary below is the report, not the exit status
  echo "${guard:-no macro}: $FORT_PASS passed, $FORT_FAIL failed"
  fails=$((fails + FORT_FAIL))
done

echo ""
echo "Results: $fails failed across the three configurations"
[ "$fails" -eq 0 ]
