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

# Shared engine of the per-library generators (src/<lib>/generator.jl).
#
# Files, in dependency order:
#   ir.jl             intermediate representation (ArgInfo, FuncInfo, EnumInfo, ...)
#   settings.jl       generation settings from the environment, output constants
#   metadata.jl       LibMeta, per-library metadata loaders (.argkinds, ...)
#   config.jl         collectors filled by the Clang frontend, small IR helpers
#   format.jl         Fortran line formatting (continuations, import lists)
#   type_mapping.jl   C -> Fortran type mapping
#   clang_frontend.jl libclang walk filling the IR (collect_funcs, collect_enums, ...)
#   emit.jl           bind(C) interfaces and typed/rank/string wrappers
#   license.jl        license banner
#   emit_files.jl     whole-module emitters
#   assemble.jl       gen_files, the per-library pipeline
#   clang_args.jl     header discovery, Clang arguments, run_library_generator

using Clang
using Clang.Generators

include(joinpath(@__DIR__, "ir.jl"))
include(joinpath(@__DIR__, "settings.jl"))
include(joinpath(@__DIR__, "metadata.jl"))
include(joinpath(@__DIR__, "config.jl"))
include(joinpath(@__DIR__, "format.jl"))
include(joinpath(@__DIR__, "type_mapping.jl"))
include(joinpath(@__DIR__, "clang_frontend.jl"))
include(joinpath(@__DIR__, "emit.jl"))
include(joinpath(@__DIR__, "license.jl"))
include(joinpath(@__DIR__, "emit_files.jl"))
include(joinpath(@__DIR__, "assemble.jl"))
include(joinpath(@__DIR__, "clang_args.jl"))
