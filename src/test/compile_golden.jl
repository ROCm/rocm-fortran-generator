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

# Syntax-check the generated Fortran: regenerate the mini fixture and run
# `gfortran -fsyntax-only` on its module under each guard configuration.
#
# Run:  julia --project=src src/test/compile_golden.jl      (needs gfortran on PATH)

using Test

include(joinpath(@__DIR__, "gen_mini.jl"))

out, _ = gen_mini()
const MINI_F90 = "mini.F90"

@testset "no generated line exceeds 132 columns" begin
    # Preprocessor directives are consumed by cpp and exempt.
    bad = [(i, length(l)) for (i, l) in enumerate(eachline(joinpath(out, MINI_F90)))
           if length(l) > 132 && !startswith(lstrip(l), "#")]
    for (i, n) in bad
        @info "line >132 cols in $(MINI_F90)" line=i cols=n
    end
    @test isempty(bad)
end

# With no guard defined the rank wrappers are preprocessed away (only the _typed
# bodies remain), so they are only checked by the guarded configurations.
configs = [String[],
           ["-DUSE_ASSUMED_SHAPE"],
           ["-DUSE_ASSUMED_SHAPE", "-DUSE_ASSUMED_RANK"]]

@testset "generated Fortran compiles (gfortran -fsyntax-only)" begin
    cd(out) do
        for defs in configs
            label = isempty(defs) ? "(no guards)" : join(defs, " ")
            # Standard 132-column limit, truncation promoted to an error.
            run(`gfortran -cpp $defs -Werror=line-truncation -fsyntax-only $(MINI_F90)`)
            @test true   # run() throws on a nonzero exit
            @info "gfortran -fsyntax-only OK: $(MINI_F90)  $label"
            foreach(rm, filter(endswith(".mod"), readdir()))   # next config recompiles
        end
    end
end
