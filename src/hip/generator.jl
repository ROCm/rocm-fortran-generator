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

# Fortran bindings for the HIP runtime API (hip/hip_runtime_api.h).
#
# Usage (from the repo root):
#   julia --project=src src/hip/generator.jl [include_dir] [output_dir]

include("../common/fortran_gen.jl")
include("../common/hip_generics.jl")

function main()
  run_library_generator(@__DIR__;
    funcfilter = funcs -> filter(funcs) do f
      # The typed memory families are emitted by hip_generics.jl, and
      # hipGetDeviceProperties by hip_auxiliary_spec (dropping its R0600 target also
      # drops the #define alias): keep them out of the main module.
      !(f.name in HIP_TYPED_FAMILIES) && f.name != "hipGetDevicePropertiesR0600"
    end,
    # `module hip` also holds the typed memory families and the auxiliary interface.
    extra_generics = io -> begin
      hipmemcpy_spec(io)
      hipmalloc_spec(io)
      hiphostregister_spec(io)
      hip_auxiliary_spec(io)
    end,
    extra_wrappers = io -> begin
      hipmemcpy_body(io)
      hipmalloc_body(io)
      hiphostregister_body(io)
    end)
end

main()
