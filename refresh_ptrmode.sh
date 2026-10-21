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

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts/common.sh"

usage_spec() { cat <<'SPEC'
name:  refresh_ptrmode.sh
brief: rebuild <lib>.ptrmode (and .devonly) from <lib>.argkinds in each library's metadata/
usage: bash refresh_ptrmode.sh
env:   ROCM_LIBRARIES | - | rocm-libraries checkout: refresh its projects/<lib>/fortran/metadata/ where present, instead of src/<lib>/metadata/
exit:  0 | the .ptrmode (and .devonly) of every pointer-mode library was rewritten
exit:  1 | ROCM_LIBRARIES is not a rocm-libraries checkout
note:  .argkinds marks pointer arguments that are scalars, not buffers. .ptrmode
note:  is the subset read from host OR device memory per <lib>_set_pointer_mode:
note:  a routine with both kinds of scalar also gets a _devptr specific
note:  (pointer-mode scalars as pointers, the others typed). It is .argkinds minus
note:  the host-only arguments listed in this script, filtered argument-wise.
note:
note:  Re-run after curating .argkinds, then regenerate.
SPEC
}
usage_peek "$@"

# Resolved before the cd below, so a relative path names the caller's checkout.
if [ -n "${ROCM_LIBRARIES:-}" ]; then
  ROCM_LIBRARIES="$(cd "$ROCM_LIBRARIES" 2>/dev/null && pwd)" ||
    die 1 "ROCM_LIBRARIES: no such directory"
  [ -d "$ROCM_LIBRARIES/projects" ] ||
    die 1 "ROCM_LIBRARIES=$ROCM_LIBRARIES is not a rocm-libraries checkout (no projects/)"
fi

cd "$(dirname "$0")/src"

# Host-only scalar out-parameters, per library: they are typed in _devptr, where
# the pointer-mode scalars are not.
exclude_hipblas="version mode atomics_mode value alpha_stride beta_stride myInfo"
exclude_rocblas="mySize len atomics_mode math_mode metric pointer_mode alpha_stride beta_stride"
exclude_hipsolver="lwork lworkOnHost lworkOnDevice nev singularity residual executed_sweeps zero boost nnzM h_nnzM h_nnzL h_nnzU mode myFormat diag report fastMode fact_alg solve_alg niters hInfo"
exclude_hipsparse="fractionToColor ncolors pBufferSizeInBytes pBufferSize bufferSize bufferSize1 bufferSize2 bufferSize3 bufferSize4 bufferSize5 rows cols nnz version mode myFormat order idxBase idxType ellIdxType cscColOffsetsType cscRowIndType csrRowOffsetsType csrColIndType valueType size ld batchCount batchStride ellBlockSize ellCols"
exclude_rocsolver="len nev mode"
exclude_rocsparse="fraction_to_color ncolors buffer_size buffer_size_in_bytes p_buffer_size p_buffer_size_in_bytes rows cols nnz version pointer_mode tolerance data_status myFormat order idx_base idx_type data_type block_dir ell_block_dir row_ptr_type col_ind_type col_ptr_type row_ind_type sell_slice_offsets_type sell_col_ind_type size ld batch_count batch_stride brows bcols bnnz block_dim ell_width ell_block_dim ell_cols sell_slice_size sell_colval_size host_nmaxiter"

# <function>:<arg> kept although the name is excluded: csr2ell_width computes
# ell_width per the pointer mode, while ell_get reads it out of a descriptor.
keep_rocsparse="rocsparse_csr2ell_width:ell_width"

# The filter matches argument NAMES exactly, so every spelling of a host output
# is listed (buffer_size, buffer_size_in_bytes, p_buffer_size, ...). Notably:
# - myInfo (hipBLAS) is the host int* of getrs/geqrf/gels.
# - fraction_to_color/ncolors are host scalars csrcolor reads and writes itself.
# - lworkOnDevice is a host size_t* (the size of the device workspace).
# - rows/cols/nnz/size/ld/... are descriptor fields read back on the host; the
#   sparse routines that compute a dual-mode count name it *DevHostPtr instead.
#   A future DEVICE `size` or `ld` in these libraries must not inherit this.
#
# .devonly: scalars the library writes from the kernel (hipSOLVER devInfo;
# rocSOLVER larf/larfg alpha and tau, under a forced device pointer mode). They
# stay in .ptrmode, which keeps the c_ptr binding; .devonly only withholds _typed.
devonly_hipsolver="devInfo"
devonly_rocsolver="alpha tau"

for lib in hipblas hipsolver hipsparse rocblas rocsolver rocsparse; do
  dir="$lib/metadata"
  ck="${ROCM_LIBRARIES:-}/projects/$lib/fortran/metadata"
  [ -n "${ROCM_LIBRARIES:-}" ] && [ -d "$ck" ] && dir="$ck"
  src="$dir/$lib.argkinds"
  out="$dir/$lib.ptrmode"
  [ -f "$src" ] || { echo "skip $lib (no .argkinds)"; continue; }
  echo "$lib: $dir"

  eval "drop=\${exclude_$lib}"
  eval "keepx=\${keep_$lib:-}"

  {
    echo "# <function> <dual-mode-scalar-arg> ...   GENERATED by refresh_ptrmode.sh"
    echo "# Scalars read from host OR device memory per the handle's pointer mode."
    DROP="$drop" KEEPX="$keepx" awk '
      /^#/ || /^[[:space:]]*$/ { next }
      BEGIN { n = split(ENVIRON["DROP"], d, " "); for (i = 1; i <= n; i++) bad[d[i]] = 1
              n = split(ENVIRON["KEEPX"], k, " "); for (i = 1; i <= n; i++) keepx[k[i]] = 1 }
      {
        line = $1; kept = 0
        for (i = 2; i <= NF; i++) if (!($i in bad) || (($1 ":" $i) in keepx)) { line = line " " $i; kept++ }
        if (kept) print line
      }' "$src"
  } > "$out"

  before=$(grep -vc '^#' "$src" || true)
  after=$(grep -vc '^#' "$out" || true)
  echo "$lib: $before .argkinds lines -> $after .ptrmode lines (dropped: $drop)"

  eval "devonly=\${devonly_$lib:-}"
  [ -n "$devonly" ] || continue
  {
    echo "# <function> <device-only-arg> ...   GENERATED by refresh_ptrmode.sh"
    echo "# Scalars ${lib} writes from the kernel: also in .ptrmode, but no _typed form."
    DROP="$devonly" awk '
      /^#/ || /^[[:space:]]*$/ { next }
      BEGIN { n = split(ENVIRON["DROP"], d, " "); for (i = 1; i <= n; i++) keep[d[i]] = 1 }
      {
        line = $1; n = 0
        for (i = 2; i <= NF; i++) if ($i in keep) { line = line " " $i; n++ }
        if (n) print line
      }' "$src"
  } > "$dir/$lib.devonly"
  echo "$lib: $(grep -vc '^#' "$dir/$lib.devonly") .devonly lines ($devonly)"
done

echo
echo "HIP, ROCTx and the FFT/RAND libraries ship no .ptrmode: none of their scalars is dual-mode."
