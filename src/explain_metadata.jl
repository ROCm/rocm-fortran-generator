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
# names it, after brace expansion, or inherited by a _64/_spt variant. Then what
# the C signature decides beyond the table (signature_defaults, the workspace
# names), from the function as declared in the headers a gen.sh run reads: the
# installed ROCM_INCLUDE (default /opt/rocm/include), or the ROCM_SYSTEMS /
# ROCM_LIBRARIES checkouts, whose metadata is read too.
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

# The header sources of a gen.sh run: ROCM_INCLUDE (default /opt/rocm/include) is
# read unless ROCM_SYSTEMS is set. An invalid combination leaves the tables
# explained, and the reason the headers are not read.
function explain_sources(env)
  systems = get(env, "ROCM_SYSTEMS", "")
  args = isempty(systems) ? [get(env, "ROCM_INCLUDE", DEFAULT_INCLUDE)] : String[]
  try
    return header_sources(env, args)[1], ""
  catch e
    e isa ArgumentError || rethrow()
    return HeaderSources("", get(env, "ROCM_LIBRARIES", ""), systems), e.msg
  end
end

"""
    parse_owner(lib, s) -> (parsed, module) or an error message

`lib`'s functions as its generator parses them, from the include dir a gen.sh run
gives it: src/<lib>/generator.jl is evaluated in a module of its own (as each
generator runs in its own process) and its `main` is handed `library_funcs`, so
its own Clang hooks apply and nothing is generated.
"""
function parse_owner(lib, s::HeaderSources)
  lib in selected_libs(s) ||
    return "$(lib) comes from $(repo_of(lib)), which this run does not read: set " *
           (repo_of(lib) == "rocm-systems" ? "ROCM_SYSTEMS" : "ROCM_LIBRARIES")
  inc = lib_include(s, lib)
  inc === nothing && return "no include dir for $(lib) in $(describe_sources(s))"
  ENV["ROCM_FORTRAN_HIP_INCLUDE"] = hip_installed_include(s)
  m = Module(Symbol("explain_", lib))
  Core.eval(m, :(include(p) = Base.include($m, p)))
  try
    Base.include(m, joinpath(@__DIR__, lib, "generator.jl"))
    # Warnings and Clang errors only: not the generator's progress lines.
    L = Base.CoreLogging
    _, _, parsed = L.with_logger(L.SimpleLogger(stderr, L.Warn)) do
      # The latest world: the module's bindings are newer than this function.
      Base.invokelatest() do
        m.main((dir; kw...) -> m.library_funcs(dir; include_dir = inc, kw...))
      end
    end
    return parsed, m
  catch e
    return "parsing $(lib)'s headers from $(inc) failed: " * sprint(showerror, e)
  end
end

function explain(io, name, s::HeaderSources, parse)
  # The library binding `name`: the longest prefix that matches (hipfft before hip).
  owners = [lib for lib in LIBS if !isempty(lib_prefix(lib)) && startswith(name, lib_prefix(lib))]
  owner = isempty(owners) ? "" : owners[argmax(length.(lib_prefix.(owners)))]
  found = false
  for lib in LIBS
    path = joinpath(lib_metadata(s, lib), "$(lib).toml")
    md = load_metadata(path)
    hit = applying_table(md, name)
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
    # The latest world, for the bindings of the module parse_owner made.
    owns && Base.invokelatest(explain_signature, io, name, path, parse(lib))
  end
  found || println(io, "$(name): no library binds it (no prefix matches)")
end

# What the C declaration decides beyond the table, after it.
function explain_signature(io, name, path, owner)
  if owner isa AbstractString
    println(io, "  C signature: headers not read; ", owner)
    return
  end
  p, m = owner
  where = join(p.headers, ", ")
  i = findfirst(f -> f.name == name, p.funcs)
  if i === nothing
    println(io, "  C signature: ", name in p.filtered ?
      "declared in $(where), but emitted by the generator itself, not through the metadata" :
      "$(name) is not declared in $(where)")
    return
  end
  lines = m.explain_defaults(p.funcs[i], m.load_metadata(path), m.DefaultRules(p.cfg))
  if isempty(lines)
    println(io, "  C signature ($(where)): no default applies")
  else
    println(io, "  C signature ($(where)):")
    foreach(l -> println(io, "    ", l), lines)
  end
end

function main(args)
  isempty(args) && (println(stderr, "usage: explain_metadata.jl <c-function> ..."); exit(2))
  s, why = explain_sources(ENV)
  # Parsing takes seconds: each library once, however many of its functions are named.
  parsed = Dict{String,Any}()
  parse(lib) = isempty(why) ? get!(() -> parse_owner(lib, s), parsed, lib) : why
  for (i, name) in enumerate(args)
    i > 1 && println()
    explain(stdout, name, s, parse)
  end
end

main(ARGS)
