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

# Which metadata applies to a C function, and where it comes from: the table that
# names it (after brace expansion, or inherited by a _64/_spt variant) and the
# `["*"]` entries. Reads the checkouts' metadata like gen.sh does.
#
#   ROCM_LIBRARIES=<checkout> julia --project=src src/explain_metadata.jl rocblas_ddot_64

using TOML
include(joinpath(@__DIR__, "common", "header_sources.jl"))
include(joinpath(@__DIR__, "common", "fortran_gen.jl"))

function fmt_values(v)
  v isa AbstractString && return repr(v)
  v isa AbstractVector && return "[" * join(repr.(v), ", ") * "]"
  return repr(v)
end

lib_prefix(lib) =
  get(get(TOML.parsefile(joinpath(@__DIR__, lib, "$(lib).toml")), "library", Dict()), "prefix", "")

function explain(io, name, s::HeaderSources)
  # The library binding `name`: the longest prefix that matches (hipfft before hip).
  owners = [lib for lib in LIBS if !isempty(lib_prefix(lib)) && startswith(name, lib_prefix(lib))]
  owner = isempty(owners) ? "" : owners[argmax(length.(lib_prefix.(owners)))]
  found = false
  for lib in LIBS
    path = joinpath(lib_metadata(s, lib), "$(lib).toml")
    md = load_metadata(path)
    hit = applying_table(md, name)
    star = get(md.tables, "*", nothing)
    owns = lib == owner
    hit === nothing && !owns && continue
    found = true
    println(io, "$(name): $(path)")
    if hit === nothing
      println(io, "  no table: the C declaration alone")
    else
      fn, tbl = hit
      key = md.origin[fn]
      via = fn == name ? "" : " (inherited from $(fn))"
      println(io, "  [$(key == fn ? fn : repr(key))]$(via)")
      for (a, v) in sort!(collect(tbl); by = first)
        println(io, "    $(a) = $(fmt_values(v))")
      end
    end
    if star !== nothing && owns
      println(io, "  [\"*\"], every function:")
      for (a, v) in sort!(collect(star); by = first)
        println(io, "    $(a) = $(fmt_values(v))")
      end
    end
  end
  found || println(io, "$(name): no library binds it (no prefix matches)")
end

function main(args)
  isempty(args) && (println(stderr, "usage: explain_metadata.jl <c-function> ..."); exit(2))
  s = HeaderSources("", get(ENV, "ROCM_LIBRARIES", ""), get(ENV, "ROCM_SYSTEMS", ""))
  for (i, name) in enumerate(args)
    i > 1 && println()
    explain(stdout, name, s)
  end
end

main(ARGS)
