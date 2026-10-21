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

# Fortran bindings for hipBLAS.
#
# Usage (from the repo root):
#   julia --project=src src/hipblas/generator.jl [include_dir] [output_dir]

include("../common/fortran_gen.jl")
include("../common/blas_generics.jl")

function main()
  run_library_generator(@__DIR__;
    argshook = function (args, include_dir, hdrs)
      push!(args, "-I$(dirname(hdrs[1]))")
      # <hipblas-common/hipblas-common.h> is a separate project in the monorepo.
      mono_common = abspath(joinpath(include_dir, "..", "..", "..",
                                     "hipblas-common", "library", "include"))
      isdir(mono_common) && push!(args, "-I$(mono_common)")
    end,
    blas_aux_hooks(:camel, "HIPBLAS_STATUS_SUCCESS")...)
end

main()
