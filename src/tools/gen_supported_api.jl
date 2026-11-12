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

# src/tools/gen_supported_api.jl
#
# Regenerate hipfort's docs/doxygen/input/supported_api_<lib>.md tables: one
# Markdown table per library listing every public generic interface and, in a
# second column, the variants it resolves to.
#
# Each row links to the interface's Doxygen page. The link is RELATIVE and
# same-directory: Doxygen renders this Markdown page and the interface pages side
# by side in doxygen/html/, so a relative link stays on whatever version site the
# reader is on (develop/latest/tagged) and never 404s for symbols that exist in
# that version -- an absolute en/latest URL 404s for develop-only symbols (e.g.
# rocsparse_spildlt0). The link embeds the Doxygen page name, mangled '_' -> '__'
# after lower-casing (Fortran is case-insensitive), which is version-dependent, so
# regenerate the tables when the Doxygen version changes (the scheduled regen
# workflow does this automatically).
#
# The variants column is derived from each generic's module-procedure suffixes
# (full_rank / rank_N / typed / cstr).
#
# Usage (from a hipfort checkout root):
#     julia src/tools/gen_supported_api.jl [hipfort_root] [output_dir]
# Defaults: hipfort_root = pwd(), output_dir = <hipfort_root>/docs/doxygen/input

# Doxygen mangles compound (interface) file names. Fortran is case-insensitive,
# so Doxygen lower-cases the identifier first, then escapes each '_' as '__'.
# (Do NOT insert '_' before uppercase letters: that is the C++ rule and would
# break camelCase names like hipblasSgemm.)
dox(s) = replace(lowercase(s), "_" => "__")

# md file -> (title, [modules in order])
const MD = [
  ("hip",       "# HIP API Support",       ["hipfort_hipmalloc", "hipfort_hipmemcpy", "hipfort_hiphostregister", "hipfort_auxiliary", "hipfort"]),
  ("hipblas",   "# hipBLAS API support",   ["hipfort_hipblas"]),
  ("hipfft",    "# hipFFT API Support",    ["hipfort_hipfft"]),
  ("hipfftxt",  "# hipFFT Xt API Support", ["hipfort_hipfftxt"]),
  ("hipfftw",   "# hipFFTW API Support",   ["hipfort_hipfftw"]),
  ("hiprand",   "# hipRAND API Support",   ["hipfort_hiprand"]),
  ("hipsolver", "# hipSOLVER API support", ["hipfort_hipsolver"]),
  ("hipsparse", "# hipSPARSE API support", ["hipfort_hipsparse"]),
  ("rocblas",   "# rocBLAS API Support",   ["hipfort_rocblas"]),
  ("rocfft",    "# rocFFT API Support",    ["hipfort_rocfft"]),
  ("rocrand",   "# rocRAND API Support",   ["hipfort_rocrand"]),
  ("rocsolver", "# rocSOLVER API Support", ["hipfort_rocsolver"]),
  ("rocsparse", "# rocSPARSE API Support", ["hipfort_rocsparse"]),
  # ROCTx, not rocTX: that is the spelling hipfort uses in its README link and in
  # the page title this table replaces. The file used to be hand-written, so the
  # first generated run silently renamed the page.
  ("roctx",     "# ROCTx API Support",      ["hipfort_roctx"]),
]

# Names declared `private` are module-local helpers (e.g. byte_size); Doxygen
# does not emit a page for them, so they must not be listed (dead links).
function private_names(libfiles)
  priv = Set{String}()
  for path in libfiles
    for ln in split(read(path, String), '\n')
      m = match(r"^\s*private\s*::\s*(.+)$", ln)
      m === nothing && continue
      for n in split(m.captures[1], ",")
        s = strip(n)
        isempty(s) || push!(priv, String(s))
      end
    end
  end
  return priv
end

# module name -> ordered list of (interface_name, variants_str)
function parse_interfaces(libfiles, priv)
  mods = Dict{String,Vector{Tuple{String,String}}}()
  for path in libfiles
    lines = split(read(path, String), '\n')
    n = length(lines)
    cur = nothing
    i = 1
    while i <= n
      ln = lines[i]
      m = match(r"^module (hipfort[a-z_]*)\s*$", ln)
      if m !== nothing
        cur = String(m.captures[1])
        get!(mods, cur, Tuple{String,String}[])
      elseif match(r"^end module", ln) !== nothing
        cur = nothing
      elseif cur !== nothing
        mi = match(r"^  interface ([a-zA-Z0-9_]+)\s*$", ln)
        if mi !== nothing && !(String(mi.captures[1]) in priv)
          name = String(mi.captures[1])
          sufs = Set{String}()
          j = i + 1
          while j <= n && match(r"^  end interface", lines[j]) === nothing
            for mm in eachmatch(r"([a-zA-Z0-9_]+?)_(assumed_rank|full_rank|rank_\d+|typed|devptr)\b", lines[j])
              push!(sufs, String(mm.captures[2]))
            end
            j += 1
          end
          parts = ["C binding"]
          "full_rank" in sufs && push!(parts, "full_rank")
          for r in sort([parse(Int, split(s, '_')[2]) for s in sufs if startswith(s, "rank_")])
            push!(parts, "rank_$(r)")
          end
          "assumed_rank" in sufs && push!(parts, "assumed_rank")
          for extra in ("typed", "devptr")
            extra in sufs && push!(parts, extra)
          end
          push!(mods[cur], (name, join(parts, ", ")))
          i = j
        end
      end
      i += 1
    end
  end
  return mods
end

function main()
  hipfort_root = isempty(ARGS) ? pwd() : ARGS[1]
  libdir = joinpath(hipfort_root, "lib", "hipfort")
  outdir = length(ARGS) >= 2 ? ARGS[2] : joinpath(hipfort_root, "docs", "doxygen", "input")
  isdir(libdir) || error("$(libdir) not found (pass the hipfort checkout root as arg 1)")

  libfiles = sort(filter(f -> endswith(f, ".F90"), readdir(libdir; join = true)))
  priv = private_names(libfiles)
  mods = parse_interfaces(libfiles, priv)

  mkpath(outdir)
  for (lib, title, modlist) in MD
    rows = Tuple{String,String,String}[]   # (name, url, variants)
    for M in modlist
      for (name, var) in get(mods, M, Tuple{String,String}[])
        url = "interface$(dox(M))_1_1$(dox(name)).html"
        push!(rows, (name, url, var))
      end
    end
    open(joinpath(outdir, "supported_api_$(lib).md"), "w") do io
      println(io, title)
      println(io)
      println(io, "\\# | API Name | Variants")
      println(io, "----|---------------|---------")
      # Plain Markdown links so the tables render as clickable links in the docs.
      for (idx, (name, url, var)) in enumerate(rows)
        println(io, "$(idx) | [$(name)]($(url) \"Interface documentation\") | $(var)")
      end
    end
    println("  $(lib): $(length(rows)) interfaces")
  end
end

main()
