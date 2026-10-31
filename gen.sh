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

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$ROOT/scripts/common.sh"

usage_spec() { cat <<'SPEC'
name:  gen.sh
brief: generate the Fortran bindings into fortran/, a build artifact of this repo
usage: ./gen.sh [--overwrite] [library ...] | --explain <c-function> ...
env:   ROCM_INCLUDE | /opt/rocm/include | installed ROCm headers, read unless ROCM_SYSTEMS is set
env:   ROCM_SYSTEMS | - | rocm-systems checkout: generate HIP and ROCTx from it
env:   ROCM_LIBRARIES | - | rocm-libraries checkout: generate the math libraries from it
env:   ROCM_FORTRAN_OUT | fortran/ | the directory to generate into
env:   ROCM_FORTRAN_STRICT | - | 1: a metadata entry the headers make inapplicable stops the run (otherwise: a warning, the entry ignored)
exit:  0 | generated; fortran/.provenance records the libraries, header sources and HIP version
exit:  1 | bad header source, or a library failed to generate
exit:  2 | unknown option
note:  --explain prints the metadata that applies to each C function named, and the
note:  table it comes from (brace expansion, _64/_spt inheritance); with
note:  ROCM_SYSTEMS/ROCM_LIBRARIES, from the checkouts' metadata. Then the defaults its
note:  C signature gives the arguments the table does not name, from the headers the
note:  run would read (each library parsed once).
note:  Neither checkout set: all libraries, from ROCM_INCLUDE.
note:  ROCM_SYSTEMS alone: HIP and ROCTx, from the checkout only (no ROCm installation).
note:  ROCM_LIBRARIES alone: the math libraries, from the checkout, with only the
note:  HIP headers taken from ROCM_INCLUDE.
note:  Both: all libraries, from the two checkouts only (no ROCm installation).
note:  Libraries named on the command line (hip, roctx, rocblas, hipfft, ...) are the
note:  only ones generated; each must come from a header source the run reads.
note:  --overwrite also copies each generated module into its checkout:
note:  <ROCM_LIBRARIES>/projects/<proj>/fortran/<lib>.F90, or
note:  <ROCM_SYSTEMS>/projects/fortran/<lib>.F90. It needs a checkout, the fortran/
note:  directory must already exist there, and a library that fails is not copied.
note:  A run rewrites only the modules it generates: fortran/rocm-systems/fortran/
note:  (HIP, ROCTx) and fortran/rocm-libraries/<lib>/ (the math libraries).
note:  A checkout's fortran/metadata/<lib>.toml (rocm-systems: projects/fortran/metadata/;
note:  rocm-libraries: projects/<proj>/fortran/metadata/), when present, replaces the
note:  generator's src/<lib>/metadata/ for that library.
note:  The Julia dependencies are installed on the first run (Pkg.instantiate).
note:  fortran/ is gitignored: the bindings are committed upstream, next to the
note:  C headers in rocm-systems/ and rocm-libraries/.
SPEC
}
usage_peek "$@"

[ -z "${ROCM_SYSTEMS:-}" ] || [ -z "${ROCM_INCLUDE:-}" ] ||
  die 1 "ROCM_INCLUDE cannot be combined with ROCM_SYSTEMS (HIP comes from the checkout)"

if [ "${1:-}" = --explain ]; then
  shift
  [ $# -gt 0 ] || usage_error "--explain needs a C function name"
  exec julia --project="$ROOT/src" "$ROOT/src/explain_metadata.jl" "$@"
fi

OUT="${ROCM_FORTRAN_OUT:-$ROOT/fortran}"

OPTS=()
LIBS=()
for a in "$@"; do
  case "$a" in
    --overwrite) OPTS+=(--overwrite) ;;
    -*) usage_error "unknown option '$a'" ;;
    *) LIBS+=("$a") ;;
  esac
done
if [ ${#LIBS[@]} -gt 0 ]; then
  OPTS+=("--libs=$(IFS=,; echo "${LIBS[*]}")")
fi

# generate_all.jl validates the checkouts and selects the libraries.
if [ -n "${ROCM_SYSTEMS:-}" ]; then
  GEN_ARGS=("$OUT")
else
  GEN_ARGS=("${ROCM_INCLUDE:-/opt/rocm/include}" "$OUT")
fi

command -v julia > /dev/null ||
  die 1 "julia not found: install it, e.g. with juliaup (https://julialang.org/install/)"
julia --project="$ROOT/src" -e 'using Pkg; Pkg.instantiate()'

echo "==> generating into $OUT"
julia --project="$ROOT/src" "$ROOT/src/generate_all.jl" ${OPTS[@]+"${OPTS[@]}"} "${GEN_ARGS[@]}"

echo
echo "==> done. $OUT is a build artifact; see $OUT/.provenance"
echo "    compile it with: bash check_mods.sh"
