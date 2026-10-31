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

# Fortran bindings for hipFFTW, the FFTW3-compatible API of hipFFT (hipfft/hipfftw.h).
#
# Usage (from the repo root):
#   julia --project=src src/hipfftw/generator.jl [include_dir] [output_dir]

include("../common/fortran_gen.jl")

# `run` is run_library_generator, or library_funcs to parse without generating
# (explain_metadata.jl).
function main(run = run_library_generator)
  run(@__DIR__;
    argshook = (args, include_dir, hdrs) -> push!(args, "-I$(dirname(hdrs[1]))"))
end

if abspath(PROGRAM_FILE) == @__FILE__
  main()
end
