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

# No -e: the subshell below is allowed to fail and its $? is inspected right after.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
. "$ROOT/scripts/common.sh"

usage_spec() { cat <<'SPEC'
name:  check_compilers.sh
brief: compile the generated modules with every Fortran compiler on the machine
usage: bash check_compilers.sh [dir]
arg:   dir | the directory to compile (default: fortran/rocm-systems and fortran/rocm-libraries)
exit:  0 | every available compiler built the modules
exit:  1 | an installed compiler failed
exit:  2 | no such directory
exit:  127 | no Fortran compiler found at all
note:  Tries gfortran, amdflang, LLVM flang, nvfortran, ifx, ifort, lfortran,
note:  nagfor and the Cray compiler (crayftn or ftn). Compilers that are not
note:  installed, or cannot compile an empty module, are skipped.
SPEC
}
usage_peek "$@"

BASE="$ROOT/fortran"

if [ $# -ge 1 ]; then
  d="$(cd "$1" 2>/dev/null && pwd)" || die 2 "no such directory: $1"
  ROOTS=("$d")
else
  ROOTS=("$BASE/rocm-systems" "$BASE/rocm-libraries")
fi

fort_scan_srcdirs "${ROOTS[@]}" || die_need_gen "No Fortran sources under: ${ROOTS[*]}"

# Extra ROCm locations to look for amdflang / flang beyond $PATH.
EXTRA_PATHS=(
  /opt/rocm/bin /opt/rocm/llvm/bin /opt/rocm/lib/llvm/bin
)
find_bin() {
  local name="$1" p
  p="$(command -v "$name" 2>/dev/null || true)"; [ -n "$p" ] && { echo "$p"; return; }
  for d in "${EXTRA_PATHS[@]}"; do
    [ -x "$d/$name" ] && { echo "$d/$name"; return; }
  done
}

# compiler | extra flags
COMPILERS=(
  "gfortran|-ffree-line-length-none"
  "amdflang|"
  "amdflang-new|"
  "flang|"
  "flang-new|"
  "nvfortran|"
  "ifx|"
  "ifort|"
  "lfortran|"
  "nagfor|"
  "crayftn|"
  "ftn|"
)

# No -cpp: the guards live in .F90 sources, which every compiler preprocesses on
# the extension alone, and the flag is GNU/LLVM-only (nvfortran spells it
# -Mpreprocess, ifx -fpp).
# Each compiler builds the modules under both array-interface tiers.
compile_all() {   # $1 = compiler bin, $2 = extra flags; compiles into the cwd
  local guard
  for guard in -DUSE_ASSUMED_SHAPE=1 -DUSE_ASSUMED_RANK=1; do
    rm -f ./*.mod ./*.o
    fort_session --fc "$1" --flags "$2 $guard" --errdir . \
                 --on-pass fort_quiet_pass --on-fail fort_report_fail
    fort_build_tree || return 1
  done
}

rc=0; any=0
for entry in "${COMPILERS[@]}"; do
  name="${entry%%|*}"; flags="${entry#*|}"
  bin="$(find_bin "$name")"
  if [ -z "$bin" ]; then printf "  SKIP  %-10s (not installed)\n" "$name"; continue; fi
  TMP="$(mktemp -d)"
  printf 'module smoke_m\nend module smoke_m\n' > "$TMP/smoke.f90"
  if ! ( cd "$TMP" && "$bin" -c $flags smoke.f90 ) >"$TMP/smoke.log" 2>&1; then
    printf "  SKIP  %-10s (installed but not usable)\n" "$name"; rm -rf "$TMP"; continue
  fi
  any=1
  # A subdir, so build artifacts can never clobber $TMP/log.
  BUILD="$TMP/build"; mkdir -p "$BUILD"
  ( cd "$BUILD" && compile_all "$bin" "$flags" ) >"$TMP/log" 2>&1
  if [ $? -eq 0 ]; then
    printf "  PASS  %-10s %s\n" "$name" "$("$bin" --version 2>/dev/null | head -1 | cut -c1-48)"
  else
    printf "  FAIL  %-10s\n" "$name"; sed 's/^/      /' "$TMP/log" | tail -12; rc=1
  fi
  rm -rf "$TMP"
done
[ "$any" -eq 0 ] && { echo "No Fortran compiler found."; exit 127; }
exit $rc
