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

# Shared mini-fixture bootstrap for runtests.jl, compile_golden.jl and
# array_ifaces.jl, so they all exercise the same module. The mini metadata
# (metadata/mini.toml) is read from fixtures/mini/ through the config's
# metadata_dir.

const COMMON = normpath(joinpath(@__DIR__, "..", "common"))
include(joinpath(COMMON, "fortran_gen.jl"))

const MINI_HDR = joinpath(@__DIR__, "fixtures", "mini.h")
const MINI_CFG = Dict(
  "general" => Dict("name" => "mini"),
  "library" => Dict("prefix" => "mini", "opaque_handles" => ["mini_handle_t"],
                    "metadata_dir" => joinpath(@__DIR__, "fixtures", "mini")),
  "clang"   => Dict("defines" => String[], "extra_include_dirs" => String[]))

# Parse fixtures/mini.h (libclang is bundled by Clang.jl, no ROCm needed).
function parse_mini()
  args = make_clang_args(MINI_CFG, dirname(MINI_HDR))
  ctx  = create_context([MINI_HDR], args)
  tu   = ctx.trans_units[1]
  root = Clang.getTranslationUnitCursor(tu)
  funcs   = GC.@preserve ctx tu collect_funcs(root, "mini")
  enums   = GC.@preserve ctx tu collect_enums(root; own = ["mini"])
  macros  = GC.@preserve ctx tu collect_macros(root; own = ["mini"])
  aliases = GC.@preserve ctx tu collect_name_aliases(root; own = ["mini"])
  structs = GC.@preserve ctx tu collect_structs(root; skip = ["mini_handle_t"], own = ["mini"])
  return (; funcs, enums, macros, aliases, structs)
end

# Parse + run the FULL gen_files pipeline into `out`, writing `out`/mini.F90.
# Returns (out, ir) so a caller can assert on the IR as well as on the emitted
# module. The hooks are passed to gen_files.
function gen_mini(out::String = mktempdir(); extra_generics = nothing, extra_wrappers = nothing)
  ir = parse_mini()
  gen_files(out, MINI_CFG, ir.funcs, ir.enums, ir.structs;
            macros = ir.macros, aliases = ir.aliases, extra_generics, extra_wrappers)
  return (out, ir)
end
