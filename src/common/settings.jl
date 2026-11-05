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

# Generation settings read from the environment, and output constants.

const FORTRAN_MAX_COL = 100

# Array-interface tiers materialized in the generated source:
#   all            both tiers, each behind its #ifdef (USE_ASSUMED_SHAPE /
#                  USE_ASSUMED_RANK), chosen at compile time. Default.
#   assumed-shape  only the rank_0..rank_N set (F2008), no #ifdef.
#   assumed-rank   only the dimension(..) form (F2018), no #ifdef.
#   none           no array wrappers, only the bind(C) specifics.
# Invariant (src/test/array_ifaces.jl): mode M yields the same API as `all`
# compiled under M's macro.
const ARRAY_IFACES = let a = lowercase(get(ENV, "ROCM_FORTRAN_ARRAY_INTERFACES", "all"))
  a in ("all", "assumed-shape", "assumed-rank", "none") ||
    error("ROCM_FORTRAN_ARRAY_INTERFACES must be all, assumed-shape, assumed-rank " *
          "or none, got \"$(a)\"")
  Symbol(replace(a, "-" => "_"))
end

# True when the tier choice is deferred to the preprocessor.
const GUARDED_IFACES = ARRAY_IFACES === :all

const GEN_ROOT = normpath(joinpath(@__DIR__, ".."))

# Output layout, ROCM_FORTRAN_LAYOUT:
#   packaged  one module per library (`use hip`, `use rocblas`), committed next to
#             the C headers in rocm-systems and rocm-libraries. Default.
#   hipfort   hipfort's lib/hipfort/: `hipfort` and `hipfort_<lib>` modules with
#             separate `_enums` / `_types` modules, one `hipfort_check` for every
#             library, CUDA branches under USE_CUDA_NAMES and Doxygen docstrings.
#             What regenerate.sh writes into a hipfort checkout.
const LAYOUT = let l = lowercase(get(ENV, "ROCM_FORTRAN_LAYOUT", "packaged"))
  l in ("packaged", "hipfort") ||
    error("ROCM_FORTRAN_LAYOUT must be packaged or hipfort, got \"$(l)\"")
  l
end
const HIPFORT = LAYOUT == "hipfort"

# Opt-out flags of the hipfort layout (on unless set to 0/false/no/off). The
# packaged layout has neither docstrings nor CUDA branches.
_flag(name) = lowercase(get(ENV, name, "1")) ∉ ("0", "false", "no", "off")
# Doxygen comments of the C headers as `!>` docstrings.
const EMIT_DOCS = HIPFORT && _flag("ROCM_FORTRAN_DOCSTRINGS")
# The NVIDIA backend: `#ifdef USE_CUDA_NAMES` bind pairs, enum values and types.
const EMIT_CUDA = HIPFORT && _flag("ROCM_FORTRAN_CUDA")
