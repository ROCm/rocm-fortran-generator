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

# Fortran bindings for hipFFT.
#
# Usage (from the repo root):
#   julia --project=src src/hipfft/generator.jl [include_dir] [output_dir]

include("../common/fortran_gen.jl")

# `run` is run_library_generator, or library_funcs to parse without generating
# (explain_metadata.jl).
function main(run = run_library_generator)
  run(@__DIR__;
    # hipfftMp.h uses hipfftXtSubFormat without including hipfftXt.h, and only one
    # translation unit is walked: force-include hipfftXt.h ahead of it.
    # hipfftXt.h includes <cstddef>, a C++ header: src/hipfft/cstddef stands in.
    argshook = function (args, include_dir, hdrs)
      xt = joinpath(dirname(hdrs[1]), "hipfftXt.h")
      isfile(xt) || error("Header not found: $xt")
      push!(args, "-I$(dirname(hdrs[1]))")
      push!(args, "-I$(@__DIR__)")
      push!(args, "-include", xt)
    end)
end

if abspath(PROGRAM_FILE) == @__FILE__
  main()
end
