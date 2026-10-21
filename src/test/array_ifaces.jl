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

# Tests for ROCM_FORTRAN_ARRAY_INTERFACES. The invariant:
#
#     generating with mode M  ==  generating with `all` and preprocessing with M's macro
#
# Comparing cpp output catches an arm emitted under the wrong macro, a misplaced
# guard, or a `module procedure` list naming a tier whose bodies were not emitted.
#
# Run:  julia --project=src src/test/array_ifaces.jl        (needs gfortran on PATH)

# Child mode. The generator freezes its knobs into `const`s at include time, so each
# mode is generated in its own process: ROCM_FORTRAN_ARRAY_INTERFACES in the
# environment, the output directory as ARGS[1].
if !isempty(ARGS)
    include(joinpath(@__DIR__, "gen_mini.jl"))
    include(joinpath(COMMON, "hip_generics.jl"))
    # The typed HIP memory families are not in the mini fixture: fold them into the
    # mini module through the hooks src/hip/generator.jl uses for `module hip`.
    gen_mini(ARGS[1];
             extra_generics = io -> (hipmemcpy_spec(io); hipmalloc_spec(io); hiphostregister_spec(io)),
             extra_wrappers = io -> (hipmemcpy_body(io); hipmalloc_body(io); hiphostregister_body(io)))
    exit(0)
end

using Test

include(joinpath(@__DIR__, "gen_mini.jl"))

const PROJECT  = normpath(joinpath(@__DIR__, ".."))
const MINI_F90 = "mini.F90"

# Generate the whole fixture under one mode, in its own process.
function generate(mode::AbstractString)
    dir = mktempdir()
    cmd = `$(Base.julia_cmd()) --project=$(PROJECT) $(@__FILE__) $dir`
    run(setenv(cmd, merge(ENV, Dict("ROCM_FORTRAN_ARRAY_INTERFACES" => mode))))
    return dir
end

# Run the source through cpp. -P drops the linemarkers; blank lines are stripped
# because dropping a `#ifdef` line and dropping a guarded region differ only there.
function preprocessed(file::AbstractString, defs::Vector{String})
    src = read(`gfortran -cpp -E -P $defs $file`, String)
    return join(filter(!isempty, strip.(split(src, '\n'))), '\n')
end

@testset "ROCM_FORTRAN_ARRAY_INTERFACES" begin

    # Each mode costs a full Clang parse: generate each one once.
    TIERS = (("assumed-shape", ["-DUSE_ASSUMED_SHAPE"]),
             ("assumed-rank",  ["-DUSE_ASSUMED_RANK"]),
             ("none",          String[]))
    all_dir = generate("all")
    dirs    = Dict(mode => generate(mode) for (mode, _) in TIERS)

    # The mode's own output, preprocessed with no macro, must equal the `all`
    # output preprocessed with that mode's macro.
    @testset "materializing tier $(mode) == compiling `all` with $(isempty(defs) ? "no macro" : join(defs, " "))" for
            (mode, defs) in TIERS
        @test preprocessed(joinpath(all_dir, MINI_F90), defs) ==
              preprocessed(joinpath(dirs[mode], MINI_F90), String[])
    end

    @testset "a materialized tier leaves no preprocessor guard behind" begin
        for (mode, _) in TIERS
            src = read(joinpath(dirs[mode], MINI_F90), String)
            @test !occursin("USE_ASSUMED_SHAPE", src)
            @test !occursin("USE_ASSUMED_RANK", src)
        end
    end

    # `none` drops every array wrapper and keeps the bind(C) specifics. The typed
    # HIP specifics are named <generic>_<type tag>_<rank>, not _rank_N.
    @testset "none drops the wrappers, typed HIP families included" begin
        src = read(joinpath(dirs["none"], MINI_F90), String)
        @test !occursin("_rank_0", src)
        @test !occursin("_assumed_rank", src)
        @test occursin("interface", src)           # the raw bind(C) generics remain
        @test !occursin(r"contains\s*end module", src)   # no empty contains left behind

        for (raw, typed) in (("hipMemcpy_",       "hipMemcpy_c4_1"),
                             ("hipMalloc_",       "hipMalloc_c4_1"),
                             ("hipHostRegister_", "hipHostRegister_c4_1"))
            @test occursin("function $(raw)(", src)
            @test !occursin(typed, src)
        end
    end

    # hipMalloc and hipHostRegister have no assumed-rank form, so their per-rank
    # specifics must survive an assumed-rank build, in the generic and the bodies.
    @testset "assumed-rank keeps the per-rank-only HIP families" begin
        src = read(joinpath(dirs["assumed-rank"], MINI_F90), String)
        @test occursin("module procedure hipMalloc_r8_2", src)
        @test occursin("function hipMalloc_r8_2(", src)
        @test occursin("hipMemcpy_r8_assumed_rank", src)
        @test !occursin("hipMemcpy_r8_2", src)
    end

    # Every tier decision goes through emit_tier_guard; `mode` is a parameter so
    # all four arms can be driven in-process.
    @testset "emit_tier_guard arms" begin
        render(mode, per_rank_default) = sprint() do io
            emit_tier_guard(io, o -> println(o, "AR"), o -> println(o, "PR");
                            per_rank_is_default = per_rank_default, mode = mode)
        end

        # :all defers to the preprocessor and must emit both arms.
        for d in (false, true)
            out = render(:all, d)
            @test occursin("AR", out) && occursin("PR", out)
            @test occursin("#ifdef USE_ASSUMED_RANK", out)
        end
        # The per-rank arm carries its own #ifdef only when it is not the default.
        @test occursin("#ifdef USE_ASSUMED_SHAPE", render(:all, false))
        @test !occursin("#ifdef USE_ASSUMED_SHAPE", render(:all, true))

        # A materialized tier emits exactly one arm and no directive at all.
        for d in (false, true)
            @test render(:assumed_rank, d)  == "AR\n"
            @test render(:assumed_shape, d) == "PR\n"
        end

        @test render(:none, true)  == ""
        @test render(:none, false) == ""
    end

    @testset "emit_either_tier arms" begin
        render(mode) = sprint(io -> emit_either_tier(io, o -> println(o, "X"); mode = mode))
        @test render(:all) ==
              "#if defined(USE_ASSUMED_SHAPE) || defined(USE_ASSUMED_RANK)\nX\n#endif\n"
        @test render(:assumed_shape) == "X\n"
        @test render(:assumed_rank)  == "X\n"
        @test render(:none)          == ""
    end
end
