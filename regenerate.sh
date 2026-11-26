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

GEN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$GEN_ROOT/scripts/hipfort_common.sh"

usage_spec() { cat <<'SPEC'
name:  regenerate.sh
brief: regenerate everything hipfort ships, into a hipfort checkout, ready to PR
usage: ./regenerate.sh [path-to-hipfort-checkout [library ...]]
arg:   path-to-hipfort-checkout | where to write (default: ./hipfort)
arg:   library | regenerate only these libraries' bindings in step 1 (hip, rocblas, ...)
env:   ROCM_INCLUDE  | /opt/rocm/include | HIP and math library headers to parse
exit:  0 | all four steps ran; review with git -C <checkout> diff
exit:  1 | <checkout>/lib/hipfort not found
exit:  2 | bad argument
note:  Steps, in order:
note:    1. the Fortran bindings                 -> lib/hipfort
note:    2. the bind(C) symbol tests             -> test/f2003/<lib>/test_<lib>.F03
note:    3. the supported-API doc tables         -> docs/doxygen/input
note:    4. the Doxygen cross-reference denylist -> src/common/doxygen_denylist.txt
note:
note:  Naming libraries shortens step 1 only: their modules are regenerated and
note:  hipfort_check is left as it was (it needs every library). Steps 2-4 read the
note:  whole lib/hipfort, as after a full run.
note:
note:  Files are overwritten in place, including hipfort_auxiliary, hipfort_roctx
note:  and the typed memory families (hipfort_hipmalloc, hipfort_hipmemcpy,
note:  hipfort_hiphostregister): all five are generator output, so a hand edit to
note:  any of them is silently reverted by the next run. The one module left alone
note:  is hipfort_cuda_errors, which comes from src/tools/gen_cuda_errors.jl, an
note:  offline tool that is not a step here. Rerun it deliberately when a CUDA
note:  release adds an error code.
note:
note:  Everything is generated from ROCM_INCLUDE (the installed ROCm), so a run
note:  reproduces the RELEASE API, which is what hipfort ships against. Build-time
note:  feature flags (<LIB>_WITH_*) are auto-detected from each library's
note:  version.h.in and CMake option defaults, so new guarded APIs need no config.
SPEC
}
usage_peek "$@"

HIPFORT="${1:-$GEN_ROOT/hipfort}"
[ $# -gt 0 ] && shift
LIBS_OPT=()
for a in "$@"; do
  case "$a" in -*) usage_error "unknown option '$a'" ;; esac
done
[ $# -gt 0 ] && LIBS_OPT=("--libs=$(IFS=,; echo "$*")")
ROCM="${ROCM_INCLUDE:-/opt/rocm/include}"

LIB="$HIPFORT/lib/hipfort"
DOCS="$HIPFORT/docs/doxygen/input"
[ -d "$LIB" ] || die 1 "$LIB not found (pass the hipfort checkout as arg 1)"
mkdir -p "$DOCS"

# The installed headers only: ROCM_SYSTEMS / ROCM_LIBRARIES would switch to checkouts.
# DOCSTRINGS=1 and CUDA=1 are the hipfort layout's defaults, spelled out so the
# command is self-documenting.
echo "==> [1/4] Regenerating Fortran bindings into $LIB"
env -u ROCM_SYSTEMS -u ROCM_LIBRARIES \
  ROCM_FORTRAN_LAYOUT=hipfort ROCM_FORTRAN_DOCSTRINGS=1 ROCM_FORTRAN_CUDA=1 \
  julia --project="$GEN_ROOT/src" "$GEN_ROOT/src/generate_all.jl" ${LIBS_OPT[@]+"${LIBS_OPT[@]}"} "$ROCM" "$LIB"

# Each test references every bind(C) routine of a library, guarded so nothing
# runs: the interfaces compile and the C symbols link. Wired into hipfort's CTest
# behind -DHIPFORT_EXTENDED_TESTS=ON. Parses the modules written in step 1.
echo "==> [2/4] Regenerating bind(C) symbol tests into $HIPFORT/test/f2003"
ROCM_FORTRAN_LAYOUT=hipfort HIPFORT="$HIPFORT" \
  julia "$GEN_ROOT/src/tools/gen_symbol_tests.jl"

# Rows are relative Markdown links to each interface's Doxygen page (same
# directory once rendered), so they resolve on any version site and never 404.
echo "==> [3/4] Regenerating supported-API doc tables into $DOCS"
julia "$GEN_ROOT/src/tools/gen_supported_api.jl" "$HIPFORT" "$DOCS"

# New docstrings can reference C-only entities (\ref foo) that have no Fortran
# page; those are neutralized to inline code so the WARN_AS_ERROR docs build passes.
echo "==> [4/4] Refreshing the Doxygen denylist"
bash "$GEN_ROOT/refresh_doxygen_denylist.sh" "$LIB"

echo "==> Done. Review with: git -C \"$HIPFORT\" diff"
