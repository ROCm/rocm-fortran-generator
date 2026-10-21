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

# Fortran bindings for rocSOLVER. Its headers include <rocblas/rocblas.h>, so the
# rocBLAS include dir is needed too; only rocsolver_* functions are emitted.
#
# Usage (from the repo root):
#   julia --project=src src/rocsolver/generator.jl [include_dir] [output_dir]
# The rocBLAS headers are found next to rocSOLVER's (see resolve_rocblas_include).

include("../common/fortran_gen.jl")

function resolve_rocblas_include(rocsolver_include::String) :: String
  candidate = rocsolver_include
  isdir(joinpath(candidate, "rocblas")) && return candidate

  # Monorepo: projects/rocsolver/library/include -> projects/rocblas/library/include.
  mono_rocblas = normpath(joinpath(rocsolver_include, "..", "..", "..", "rocblas", "library", "include"))
  isdir(mono_rocblas) && return mono_rocblas

  @warn "Could not locate rocblas include dir; <rocblas/rocblas.h> may not resolve"
  return rocsolver_include
end

# Flat source layout: <rocblas/rocblas.h> resolves through a rocblas/ symlink to
# rocblas_include, made in a scratch dir rather than in the checkout. Returns the
# dir to add with -I, or nothing when rocblas/ is already there.
function rocblas_link_dir(rocblas_include::String) :: Union{String,Nothing}
  ispath(joinpath(rocblas_include, "rocblas")) && return nothing
  dir = mktempdir(; prefix = "rocm-fortran-generator-rocblas-")
  symlink(rocblas_include, joinpath(dir, "rocblas"))
  return dir
end

function main()
  run_library_generator(@__DIR__;
    # <rocblas/rocblas.h> and rocBLAS's internal/ headers, from the installed
    # include dir or the sibling project of a rocm-libraries checkout.
    argshook = function (args, include_dir, hdrs)
      rocblas_include = resolve_rocblas_include(include_dir)
      @info "rocblas include: $rocblas_include"
      push!(args, "-I$(rocblas_include)")
      link = rocblas_link_dir(rocblas_include)
      link === nothing || push!(args, "-I$(link)")
      for d in (joinpath(rocblas_include, "rocblas", "internal"), joinpath(rocblas_include, "internal"))
        isdir(d) && push!(args, "-I$(d)")
      end
    end)
end

main()
