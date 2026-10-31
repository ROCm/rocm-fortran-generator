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

# The one place that decides which libraries a generate_all.jl run generates and
# where each reads its headers from. Each upstream repository generates its own
# modules from its own checkout:
#
#   ROCM_SYSTEMS  ROCM_LIBRARIES  generated            headers
#   -             -               all 13               the installed include dir
#   set           -               hip, roctx           the rocm-systems checkout
#   -             set             the math libraries   the rocm-libraries checkout; HIP
#                                                      from the installed include dir
#   set           set             all 13               the two checkouts
#
# The installed include dir is a positional argument, read only when ROCM_SYSTEMS
# is unset: with it, HIP comes from the checkout.

const LIBS = [
  "hip",
  "rocsparse",
  "hipsparse",
  "rocblas",
  "hipblas",
  "rocsolver",
  "hipsolver",
  "rocfft",
  "hipfft",
  "hipfftw",
  "rocrand",
  "hiprand",
  "roctx",
]

const DEFAULT_INCLUDE = "/opt/rocm/include"

# Header subdirectory (installed) / project (checkout) of a library.
proj_of(lib) = lib == "hipfftw" ? "hipfft"                :
               lib == "roctx"   ? "rocprofiler-sdk-roctx" : lib

# Upstream repository each module is committed to, next to its C headers.
repo_of(lib) = lib in ("hip", "roctx") ? "rocm-systems" : "rocm-libraries"

# Each field is an absolute path, or "" when not used by the run.
struct HeaderSources
  installed::String   # installed ROCm include dir
  libraries::String   # rocm-libraries checkout
  systems::String     # rocm-systems checkout
end

"""
    header_sources(env, args) -> (sources, args_left)

The header sources selected by `ROCM_LIBRARIES`/`ROCM_SYSTEMS` in `env` and the
leading include-dir argument of `args`, which is consumed only when
`ROCM_SYSTEMS` is unset. Throws an `ArgumentError` for a bad combination.
"""
function header_sources(env, args::Vector{String})
  libraries = get(env, "ROCM_LIBRARIES", "")
  systems   = get(env, "ROCM_SYSTEMS", "")
  for d in (libraries, systems)
    isempty(d) || isdir(joinpath(d, "projects")) ||
      throw(ArgumentError("not a rocm-libraries/rocm-systems checkout (no projects/): $d"))
  end
  installed, rest = if isempty(systems)
    isempty(args) ? (DEFAULT_INCLUDE, args) : (args[1], args[2:end])
  else
    ("", args)
  end
  isempty(installed) || isdir(installed) ||
    throw(ArgumentError("no such header directory: $installed"))
  # Whenever the installed dir is read, it must be a ROCm include dir: every library
  # reads HIP's headers from it. A wrong path would otherwise skip every library.
  !isempty(systems) || isdir(joinpath(installed, "hip")) ||
    throw(ArgumentError("no HIP headers (hip/) in $installed: not a ROCm include dir"))
  length(rest) <= 1 ||
    throw(ArgumentError(isempty(systems) ? "usage: generate_all.jl [include_dir] [output_root]" :
                        "no include dir is read with ROCM_SYSTEMS; usage: generate_all.jl [output_root]"))
  absp(d) = isempty(d) ? d : abspath(d)
  return HeaderSources(absp(installed), absp(libraries), absp(systems)), rest
end

from_checkouts(s::HeaderSources) = !isempty(s.libraries) || !isempty(s.systems)

checkout_of(s::HeaderSources, lib) = repo_of(lib) == "rocm-systems" ? s.systems : s.libraries

# With a checkout, a run generates only the libraries of the checkouts it has.
selected_libs(s::HeaderSources) =
  from_checkouts(s) ? filter(lib -> !isempty(checkout_of(s, lib)), LIBS) : LIBS

# The include dir a selected library's generator reads, or nothing when absent.
function lib_include(s::HeaderSources, lib)
  inc = if !from_checkouts(s)
    joinpath(s.installed, proj_of(lib))
  elseif lib == "hip"
    joinpath(s.systems, "projects", "hip", "include")
  elseif lib == "roctx"
    joinpath(s.systems, "projects", "rocprofiler-sdk", "source", "include")
  else
    joinpath(s.libraries, "projects", proj_of(lib), "library", "include")
  end
  isdir(inc) || return nothing
  return from_checkouts(s) ? inc : s.installed
end

# The directory of a library's Fortran module in its checkout: one shared
# projects/fortran/ in rocm-systems, projects/<proj>/fortran/ in rocm-libraries.
fortran_dir(s::HeaderSources, lib) =
  repo_of(lib) == "rocm-systems" ? joinpath(s.systems, "projects", "fortran") :
                                   joinpath(s.libraries, "projects", proj_of(lib), "fortran")

# The path --overwrite writes a library's module to, in its checkout.
overwrite_target(s::HeaderSources, lib) = joinpath(fortran_dir(s, lib), "$(lib).F90")

"""
    run_options(args) -> (only, overwrite, positional)

Split generate_all.jl's arguments into the libraries of `--libs=<lib>[,<lib>...]`
(`nothing` without it), the `--overwrite` flag, and the positional arguments.
Throws an `ArgumentError` for any other `--` option, or an empty `--libs=`.
"""
function run_options(args::Vector{String})
  only, overwrite, positional = nothing, false, String[]
  for a in args
    if a == "--overwrite"
      overwrite = true
    elseif startswith(a, "--libs=")
      only = String.(filter(!isempty, split(a[length("--libs=")+1:end], ",")))
      isempty(only) && throw(ArgumentError("--libs= names no library"))
    elseif startswith(a, "--")
      throw(ArgumentError("unknown option $a"))
    else
      push!(positional, a)
    end
  end
  return only, overwrite, positional
end

"""
    run_libs(s, only) -> libraries

The libraries a run generates: those `s` selects, narrowed to `only` when it is
not `nothing`. Throws an `ArgumentError` for a name that is not a library, or a
library the header sources do not select (the checkout of its repository is not set).
"""
function run_libs(s::HeaderSources, only)
  sel = selected_libs(s)
  only === nothing && return sel
  for lib in only
    lib in LIBS ||
      throw(ArgumentError("unknown library $lib (one of: $(join(LIBS, " ")))"))
    lib in sel ||
      throw(ArgumentError("$lib is not generated by this run: it comes from $(repo_of(lib)), " *
                          "so set $(repo_of(lib) == "rocm-systems" ? "ROCM_SYSTEMS" : "ROCM_LIBRARIES")"))
  end
  return filter(in(only), sel)
end

"""
    check_overwrite(s, libs)

Throws an `ArgumentError` unless --overwrite can write every module of `libs`: the
run reads a checkout, and each library's fortran/ directory already exists in it.
Called before generating anything, so a run that cannot finish writes nothing.
"""
function check_overwrite(s::HeaderSources, libs)
  from_checkouts(s) ||
    throw(ArgumentError("--overwrite needs ROCM_LIBRARIES or ROCM_SYSTEMS (a checkout to write into)"))
  for lib in libs
    d = fortran_dir(s, lib)
    isdir(d) ||
      throw(ArgumentError("--overwrite: $d does not exist; this checkout has no Fortran binding for $lib yet"))
  end
end

# A library's metadata file (metadata/<lib>.toml): the checkout's
# <fortran_dir>/metadata/ when it exists, else the generator's own
# src/<lib>/metadata/. The file names carry the library name, so the modules sharing
# a fortran/ directory (hip and roctx, hipfft and hipfftw) share one metadata/.
function lib_metadata(s::HeaderSources, lib)
  if from_checkouts(s)
    d = joinpath(fortran_dir(s, lib), "metadata")
    isdir(d) && return d
  end
  return normpath(joinpath(@__DIR__, "..", lib, "metadata"))
end

# The installed include dir the math libraries take only their HIP headers from,
# in a rocm-libraries-only run; "" otherwise.
hip_installed_include(s::HeaderSources) =
  isempty(s.systems) && !isempty(s.libraries) ? s.installed : ""

# Version of the HIP headers read: from the rocm-systems VERSION file (a
# "#HIP_VERSION_MAJOR" line, then the value), else from installed hip/hip_version.h.
function hip_version(s::HeaderSources)
  parts = if !isempty(s.systems)
    f = joinpath(s.systems, "projects", "hip", "VERSION")
    isfile(f) || return "unknown"
    lines = strip.(readlines(f))
    [let i = findfirst(==("#HIP_VERSION_$k"), lines)
       i === nothing || i == length(lines) ? nothing : lines[i + 1]
     end for k in ("MAJOR", "MINOR", "PATCH")]
  else
    f = joinpath(s.installed, "hip", "hip_version.h")
    isfile(f) || return "unknown"
    text = read(f, String)
    [let m = match(Regex("#define HIP_VERSION_$k\\s+(\\d+)"), text)
       m === nothing ? nothing : m[1]
     end for k in ("MAJOR", "MINOR", "PATCH")]
  end
  return any(isnothing, parts) ? "unknown" : join(parts, ".")
end

function describe_sources(s::HeaderSources)
  from_checkouts(s) || return "installed $(s.installed)"
  srcs = String[]
  isempty(s.systems)   || push!(srcs, "rocm-systems checkout $(s.systems)")
  isempty(s.libraries) || push!(srcs, "rocm-libraries checkout $(s.libraries)")
  h = hip_installed_include(s)
  isempty(h) || push!(srcs, "HIP headers from installed $h")
  return join(srcs, ", ")
end
