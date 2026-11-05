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

. "$(cd "$(dirname "$0")" && pwd)/scripts/hipfort_common.sh"

usage_spec() { cat <<'SPEC'
name:  refresh_doxygen_denylist.sh
brief: regenerate src/common/doxygen_denylist.txt from a Doxygen run
usage: bash refresh_doxygen_denylist.sh <dir-with-generated-.f90>
arg:   dir | the ONE tree of generated modules to harvest from
env:   DOXYGEN | /usr/bin/doxygen, else the first in PATH | doxygen binary to use
exit:  0 | denylist merged and rewritten
exit:  2 | no directory given
exit:  127 | doxygen or gfortran not installed
note:  The generator turns denylisted Doxygen cross-ref targets into inline code
note:  so hipfort's docs build passes with WARN_AS_ERROR=YES, WITHOUT dropping the
note:  thousands of links that DO resolve. The denylist is the set of targets
note:  Doxygen cannot resolve, discoverable only by running Doxygen. Run this
note:  after a ROCm header bump, on freshly generated modules, then regenerate so
note:  the new denylist takes effect. Merges into, never shrinks, the existing list.
note:
note:  THE DOXYGEN VERSION IS PART OF THE ANSWER. Whether a link resolves is a
note:  property of that version's resolver, not of the source: 1.9.8 fails on
note:  ::rocfft_execution_info_set_load_callback_data while 1.18 resolves it, even
note:  though both register the interface as a compound. Run a newer Doxygen than
note:  CI and this script reports a fixed point while the docs build fails.
note:  CI is Read the Docs, and .readthedocs.yaml installs Ubuntu 24.04's apt
note:  doxygen, so /usr/bin/doxygen is preferred over whatever is first in PATH.
SPEC
}
usage_peek "$@"

[ $# -ge 1 ] || usage_error "need the directory holding the generated modules"
SRC="$(cd "$1" && pwd)"
DENY="$(cd "$(dirname "$0")" && pwd)/src/common/doxygen_denylist.txt"

require_cmd gfortran
DOXY="$(doxygen_bin)" || die 127 "doxygen not installed"
echo "using $DOXY ($("$DOXY" --version 2>/dev/null | head -1)); CI uses Ubuntu 24.04's apt doxygen"

make_tmpdir
doxygen_preprocess "$SRC" "$TMP/input"
# GENERATE_HTML stays on: Doxygen reports an unresolved \ref ("explicit link
# request ... could not be resolved") only while writing the output, so a run
# without it misses targets that then break the docs build.
doxyfile_write "$TMP/Doxyfile" "$TMP" "$TMP/input" "$TMP/warn.txt" YES
doxygen_run "$DOXY" "$TMP/Doxyfile"

# No match means the denylist already covers every unresolved target, the normal
# outcome on a re-run. grep exits 1 there, which under `set -o pipefail` would
# abort the script, so absorb it and keep new.txt empty.
{ grep -oE "to '[^']+' for .ref command|explicit link request to '[^']+'" "$TMP/warn.txt" 2>/dev/null || true; } \
  | sed -E "s/.*'([^']+)'.*/\1/; s/\(\)$//" | sort -u > "$TMP/new.txt"
before=$( [ -f "$DENY" ] && wc -l < "$DENY" || echo 0 )
sort -u <([ -f "$DENY" ] && cat "$DENY") "$TMP/new.txt" > "$TMP/merged" && mv "$TMP/merged" "$DENY"
echo "denylist: $before -> $(wc -l < "$DENY") targets ($DENY)"
