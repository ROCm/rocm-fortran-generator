#!/usr/bin/env julia
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

# rocm-fortran/tools/gen_cuda_errors.jl
# Opt-in regenerator for hipfort's lib/hipfort/hipfort_cuda_errors.f90 — the
# CUDA-backend cudaError_t enum used under USE_CUDA_NAMES by hipCheck & co.
#
# This is deliberately NOT part of the main generator: it targets the CUDA
# headers (not ROCm), and the only source is CUDA_SDK_jll — a multi-GB artifact.
# To keep that heavy dependency out of everyone's `Pkg.instantiate`, this script
# adds Clang + CUDA_SDK_jll to a THROWAWAY environment, so the download only
# happens when you actually run it. cudaError_t is very stable, so this rarely
# needs to run.
#
# Usage (from the rocm-fortran repo root):
#   julia src/tools/gen_cuda_errors.jl [output_file]
# Default output: ../hipfort/lib/hipfort/hipfort_cuda_errors.f90 (sibling checkout).

import Pkg
Pkg.activate(mktempdir())
# Pin Clang to the same 0.19 series the main generator uses, for a stable API.
Pkg.add([Pkg.PackageSpec(name = "Clang", version = "0.19"),
         Pkg.PackageSpec(name = "CUDA_SDK_jll")])

using Clang
using Clang.Generators
using CUDA_SDK_jll

const OUT = length(ARGS) >= 1 ? ARGS[1] :
            abspath(joinpath(@__DIR__, "..", "..", "hipfort", "lib", "hipfort",
                             "hipfort_cuda_errors.f90"))

# ---- locate driver_types.h (defines `enum cudaError`) inside the JLL artifact ----
function find_header(root::String, name::String)
  for (dir, _, files) in walkdir(root)
    name in files && return joinpath(dir, name)
  end
  error("$(name) not found under $(root)")
end

header = find_header(CUDA_SDK_jll.artifact_dir, "driver_types.h")
incdir = dirname(header)
@info "CUDA header: $(header)"

# ---- parse and collect the cudaError enum ----
args = get_default_args()
push!(args, "-I$(incdir)")                     # resolve sibling includes
push!(args, "-I$(dirname(incdir))")            # e.g. .../include for crt/… headers

ctx  = create_context([header], args)
tu   = ctx.trans_units[1]
root = Clang.getTranslationUnitCursor(tu)

# The cudaError enum (typedef'd to cudaError_t). Preserve declaration order and
# dedup case-insensitively, matching the main generator's collect_enums.
consts = Pair{String,Int64}[]
seen   = Set{String}()
for c in Clang.children(root)
  Clang.kind(c) == Clang.CXCursor_EnumDecl || continue
  Clang.spelling(c) == "cudaError" || continue
  for ec in Clang.children(c)
    Clang.kind(ec) == Clang.CXCursor_EnumConstantDecl || continue
    nm = Clang.spelling(ec)
    isempty(nm) && continue
    key = lowercase(nm)
    key in seen && continue
    push!(seen, key)
    val = Clang.LibClang.clang_getEnumConstantDeclValue(ec.cursor)
    push!(consts, nm => Int64(val))
  end
end
isempty(consts) && error("no cudaError enumerators found in $(header)")
@info "Collected $(length(consts)) cudaError enumerators"

# ---- emit the Fortran module (the shared MIT banner + a bind(c) enum) ----
include(joinpath(@__DIR__, "..", "common", "license.jl"))

open(OUT, "w") do io
  emit_license_header(io; years = "2020-2026")
  println(io, "module hipfort_cuda_errors")
  println(io, "")
  println(io, "  implicit none")
  println(io, "")
  println(io, "  enum, bind(c)")
  for (nm, v) in consts
    println(io, "    enumerator :: $(nm) = $(v)")
  end
  println(io, "  end enum")
  println(io, "")
  println(io, "end module hipfort_cuda_errors")
end
@info "Wrote $(OUT) ($(length(consts)) enumerators)"
