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

# The hipfort layout (ROCM_FORTRAN_LAYOUT=hipfort): the mini fixture generated into
# hipfort's separate modules, against golden files, with its CUDA branches
# (fixtures/mini/mini.txt, mini_enums_cuda.txt) and docstrings, then compiled.
# Set ROCM_FORTRAN_REFRESH_GOLDEN to rewrite the golden files on purpose.
#
#   julia --project=src src/test/hipfort_layout.jl

# The layout is read when the generator is included.
ENV["ROCM_FORTRAN_LAYOUT"] = "hipfort"
using Test
include(joinpath(@__DIR__, "gen_mini.jl"))

const GOLDEN = joinpath(@__DIR__, "fixtures", "hipfort")

@testset "hipfort layout" begin
  out, _ = gen_mini()
  files = ["hipfort_mini_enums.F90", "hipfort_mini_types.F90", "hipfort_mini.F90"]
  @test all(f -> isfile(joinpath(out, f)), files)
  @test !isfile(joinpath(out, "mini.F90"))

  for f in files
    txt = read(joinpath(out, f), String)
    golden = joinpath(GOLDEN, f)
    haskey(ENV, "ROCM_FORTRAN_REFRESH_GOLDEN") && write(golden, txt)
    @test txt == read(golden, String)
  end

  mod   = read(joinpath(out, "hipfort_mini.F90"), String)
  enums = read(joinpath(out, "hipfort_mini_enums.F90"), String)
  # The module re-exports its enums and types; each interface body IMPORTs them,
  # and no scope `use`s a module the module has (ftn reads it again each time).
  @test occursin("module hipfort_mini\n  use hipfort_mini_enums\n  use hipfort_mini_types\n", mod)
  @test occursin("bind(c, name=\"mini_cscal\")\n      import\n      implicit none", mod)
  @test !occursin(r"^ {6}use "m, mod)
  # hipfort's copyright span.
  @test occursin("Copyright (C) 2020-2026", mod)
  # A mapped routine binds its CUDA twin under USE_CUDA_NAMES; an unmapped one is
  # ROCm-only.
  @test occursin("#ifdef USE_CUDA_NAMES\n    function mini_create_(handle) bind(c, name=\"cuminiCreate\")\n#else", mod)
  @test occursin("#ifndef USE_CUDA_NAMES\n  interface mini_destroy\n", mod)
  @test occursin("#ifdef USE_CUDA_NAMES\n    enumerator :: MINI_OP_T = 2\n#else\n    enumerator :: MINI_OP_T = 1\n#endif", enums)
  # The headers' Doxygen comments as docstrings.
  @test occursin("  !> ", mod)
  # A versioned symbol documented only on its inline forwarder takes its comment.
  @test occursin("  !>  @brief Choose a device (documented on the forwarder only).\n#ifndef USE_CUDA_NAMES\n  interface mini_choose_R0600\n", mod)

  # The check routine goes to hipfort_check, assembled from the .checkmeta.
  @test !occursin("miniCheck", mod)
  @test readlines(joinpath(out, "mini.checkmeta"))[1:4] ==
        ["miniCheck", "MINI_STATUS_SUCCESS", "hipfort_mini_enums", "MINI"]
  gen_unified_check_file([out], out)
  check = read(joinpath(out, "hipfort_check.F90"), String)
  @test occursin("  subroutine miniCheck(status)", check)
  @test occursin("    use hipfort_mini_enums, only: MINI_STATUS_SUCCESS, MINI_STATUS_FAILURE", check)

  # The modules compile, in both backends' configuration (the ROCm and the CUDA one).
  fc = get(ENV, "FC", "gfortran")
  if Sys.which(fc) === nothing
    @info "$(fc) not found, skipping the compile check"
  else
    for defs in ([], ["-DUSE_CUDA_NAMES"], ["-DUSE_ASSUMED_SHAPE"], ["-DUSE_ASSUMED_RANK"])
      dir = mktempdir()
      ok = all(files) do f
        success(pipeline(`$fc -cpp $defs -fsyntax-only -J$dir -I$dir $(joinpath(out, f))`;
                         stdout=devnull, stderr=devnull))
      end
      @test ok
    end
  end
end
