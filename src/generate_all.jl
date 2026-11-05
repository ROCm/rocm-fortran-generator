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

# Run every selected library generator, each in its own Julia process. Each module
# goes under the output root (default ../fortran), by upstream repository:
#   <root>/rocm-systems/<lib>/<lib>.F90 (hip, roctx)   <root>/rocm-libraries/<lib>/<lib>.F90
# and <root>/.provenance records what was generated, from which headers.
#
# The library set and the header sources are decided in common/header_sources.jl,
# from ROCM_SYSTEMS and ROCM_LIBRARIES (checkouts) and the include dir argument.
#
# Usage (from the repo root):
#   julia --project=src src/generate_all.jl [include_dir] [output_root]                  # all, installed
#   ROCM_SYSTEMS=<checkout> julia --project=src src/generate_all.jl [output_root]          # hip, roctx
#   ROCM_LIBRARIES=<checkout> julia --project=src src/generate_all.jl [include_dir] [output_root]
#                                                     # math libraries, HIP from include_dir
#   ROCM_SYSTEMS=<checkout> ROCM_LIBRARIES=<checkout> julia --project=src src/generate_all.jl [output_root]
#
# Options, before the positional arguments:
#   --libs=<lib>[,<lib>...]  generate only these libraries (each must be one the run selects)
#   --overwrite              also copy each generated module into its checkout, as
#                            <rocm-libraries>/bindings/fortran/<proj>/<lib>.F90 or
#                            <rocm-systems>/bindings/fortran/<lib>/<lib>.F90; needs a checkout,
#                            and that directory must already exist
#
# Each library's metadata files come from its checkout's bindings/fortran/<proj>/metadata/
# (rocm-libraries) or bindings/fortran/<lib>/metadata/ (rocm-systems) when the run
# reads that checkout and the directory exists, else from src/<lib>/metadata/.
#
# ROCM_FORTRAN_LAYOUT=hipfort writes hipfort's lib/hipfort/ instead, flat into the
# output root, with the shared hipfort_check module (see regenerate.sh). There,
# --libs regenerates those libraries' modules and leaves hipfort_check as it was,
# and --overwrite is refused.

if any(in(("-h", "--help")), ARGS)
  # The usage is the comment block after the license, which ends at the second rule.
  lines = readlines(@__FILE__)
  rules = findall(l -> startswith(l, "#####"), lines)
  for ln in lines[(length(rules) >= 2 ? rules[2] : 0) + 1:end]
    isempty(ln) && continue
    startswith(ln, "#") || break
    println(replace(ln, r"^# ?" => ""))
  end
  exit(0)
end

using TOML
include(joinpath(@__DIR__, "common", "header_sources.jl"))

const GENERATOR_VERSION = TOML.parsefile(joinpath(@__DIR__, "Project.toml"))["version"]
@info "rocm-fortran-generator $(GENERATOR_VERSION)"

const HIPFORT_LAYOUT = lowercase(get(ENV, "ROCM_FORTRAN_LAYOUT", "packaged")) == "hipfort"

const SOURCES, REST, LIBS_RUN, OVERWRITE, NAMED = try
  only, overwrite, positional = run_options(ARGS)
  overwrite && HIPFORT_LAYOUT &&
    throw(ArgumentError("--overwrite writes into rocm-libraries and rocm-systems checkouts; " *
                        "with ROCM_FORTRAN_LAYOUT=hipfort the output dir is already hipfort's lib/hipfort"))
  sources, rest = header_sources(ENV, positional)
  libs = run_libs(sources, only)
  # Before generating anything, so a run that cannot write every module writes none.
  overwrite && check_overwrite(sources, libs)
  sources, rest, libs, overwrite, only !== nothing
catch e
  e isa ArgumentError || rethrow()
  println(stderr, "generate_all.jl: ", e.msg)
  exit(1)
end
const OUTPUT_ROOT = abspath(isempty(REST) ? joinpath(@__DIR__, "..", "fortran") : REST[1])
const HIP_VERSION = hip_version(SOURCES)

# One directory per library, under its upstream repository; hipfort's lib/hipfort/ is flat.
outdir_of(lib) = HIPFORT_LAYOUT ? OUTPUT_ROOT : joinpath(OUTPUT_ROOT, repo_of(lib), lib)

@info "Headers: $(describe_sources(SOURCES)) (HIP $(HIP_VERSION))"
mkpath(OUTPUT_ROOT)

# A failed generator leaves its previous output in place: report it and exit non-zero.
failed = String[]
generated = String[]

for lib in LIBS_RUN
  inc = lib_include(SOURCES, lib)
  if inc === nothing
    if from_checkouts(SOURCES) || NAMED
      # A checkout holds every library: a missing one is a moved or renamed project.
      # A library named on the command line was asked for: missing, it fails too.
      @error "Include dir not found for $lib in $(describe_sources(SOURCES))"
      push!(failed, lib)
    else
      # Not in this include tree: drop any module left from an earlier run.
      @warn "Include dir not found for $lib, skipping"
      if !HIPFORT_LAYOUT
        rm(joinpath(outdir_of(lib), "$(lib).F90"); force=true)
        isdir(outdir_of(lib)) && isempty(readdir(outdir_of(lib))) && rm(outdir_of(lib))
      end
    end
    continue
  end

  gen = joinpath(@__DIR__, lib, "generator.jl")
  out = outdir_of(lib); mkpath(out)

  @info "=" ^ 60
  @info "Generating $lib …"
  @info "  include : $inc"
  @info "  output  : $out"

  try
    # One process per library avoids leaking Clang contexts between libraries.
    cmd = `$(Base.julia_cmd()) --project=$(@__DIR__) $gen $inc $out`
    run(addenv(cmd, "ROCM_FORTRAN_HIP_INCLUDE"  => hip_installed_include(SOURCES),
                    "ROCM_FORTRAN_METADATA_DIR" => lib_metadata(SOURCES, lib)))
    push!(generated, lib)
    # Earlier runs wrote rocm-systems' modules to one shared rocm-systems/fortran/:
    # drop that copy, which check_mods.sh would compile as a second module.
    if repo_of(lib) == "rocm-systems"
      flat = joinpath(OUTPUT_ROOT, "rocm-systems", "fortran")
      rm(joinpath(flat, "$(lib).F90"); force=true)
      isdir(flat) && isempty(readdir(flat)) && rm(flat)
    end
    # Copied only once generated, so a failure leaves the checkout's module as it was.
    if OVERWRITE
      cp(joinpath(out, "$(lib).F90"), overwrite_target(SOURCES, lib); force=true)
      @info "  copied  : $(overwrite_target(SOURCES, lib))"
    end
  catch e
    # A ProcessFailedException prints the child's full environment (CI secrets included).
    @error "Failed to generate $lib: " * (e isa ProcessFailedException ? "exit code $(e.procs[1].exitcode)" : sprint(showerror, e))
    push!(failed, lib)
  end
end

@info "=" ^ 60
if !isempty(failed)
  @error "$(length(failed)) library/libraries FAILED to generate; their previous output in $OUTPUT_ROOT is STALE" failed
  exit(1)
end
if isempty(generated)
  @error "No library was generated: none of their include dirs exists in $(describe_sources(SOURCES))"
  exit(1)
end

if HIPFORT_LAYOUT
  # Every <lib>Check in one hipfort_check module, from the generators' .checkmeta.
  # A run of some libraries only has their .checkmeta, so it leaves hipfort_check as
  # it was rather than write one that lacks the other libraries' helpers.
  if LIBS_RUN == selected_libs(SOURCES)
    include(joinpath(@__DIR__, "common", "fortran_gen.jl"))
    gen_unified_check_file([OUTPUT_ROOT], OUTPUT_ROOT)
  else
    @warn "hipfort_check.F90 left as it was: only $(join(LIBS_RUN, " ")) regenerated. " *
          "Regenerate every library to update it, for example when a status enum changes."
  end
  for f in readdir(OUTPUT_ROOT)
    endswith(f, ".checkmeta") && rm(joinpath(OUTPUT_ROOT, f))
  end
  @info "Done. hipfort modules written to $OUTPUT_ROOT"
  exit(0)
end

commit = try
  readchomp(pipeline(`git -C $(@__DIR__) rev-parse --short HEAD`; stderr=devnull))
catch
  "not a git checkout"
end
write(joinpath(OUTPUT_ROOT, ".provenance"), """
  libraries:  $(join(generated, " "))
  headers:    $(describe_sources(SOURCES))
  hip:        $(HIP_VERSION)
  metadata:   $(let ck = filter(l -> !startswith(lib_metadata(SOURCES, l), normpath(@__DIR__)), generated)
                  isempty(ck) ? "generator (src/<lib>/metadata/)" :
                  "checkout metadata/ for $(join(ck, " ")), generator for the others"
                end)
  arrays:     $(get(ENV, "ROCM_FORTRAN_ARRAY_INTERFACES", "all"))
  generator:  $(GENERATOR_VERSION) ($(commit))
  """)
@info "Done. Modules written to $OUTPUT_ROOT"
