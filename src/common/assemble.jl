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

# Write the module of one library to output_dir: loads the per-library metadata
# into a LibMeta and decides what the module holds. The
# extra_generics/extra_wrappers hooks are called as `hook(io)`.
function gen_files(output_dir::String, cfg::Dict, funcs::Vector{FuncInfo},
                   enums::Vector{EnumInfo}     = EnumInfo[],
                   structs::Vector{StructInfo} = StructInfo[];
                   macros::Vector{Pair{String,Int64}} = Pair{String,Int64}[],
                   aliases::Dict{String,String} = Dict{String,String}(),
                   sibling_enum_mod::Dict{String,String} = Dict{String,String}(),
                   sibling_enums::Vector{EnumInfo} = EnumInfo[],
                   extra_generics::Union{Nothing,Function} = nothing,
                   extra_wrappers::Union{Nothing,Function} = nothing,
                   extra_procs::Dict{String,Tuple{Vector{String},Vector{String}}} =
                     Dict{String,Tuple{Vector{String},Vector{String}}}())
  libname = cfg["general"]["name"]
  mkpath(output_dir)

  if any(f -> f.name == libname, funcs)
    @warn "Module name \"$libname\" collides with a same-named function (Fortran forbids a module and its procedure sharing a name)."
  end

  # generate_all.jl passes the checkout's metadata dir when it has one.
  libdir = get(cfg["library"], "metadata_dir",
               get(ENV, "ROCM_FORTRAN_METADATA_DIR", joinpath(GEN_ROOT, libname, "metadata")))
  md = load_metadata(joinpath(libdir, "$(libname).toml"))
  @info "  metadata: $(md.path)$(isfile(md.path) ? "" : " (none)")"
  check_metadata_names(funcs, md)
  funcs, scalar_ptrs, ptrmode = apply_argkinds(funcs, md)
  funcs = revert_unknown_structs(funcs, structs)
  # After revert_unknown_structs, so the overrides have the last word.
  funcs = apply_arg_overrides(funcs, md)
  macros = drop_clashing_macros(macros, funcs)

  own_consts = Set{String}(nm for e in enums for (nm, _) in e.constants)
  for (nm, _) in macros; push!(own_consts, nm); end

  meta = LibMeta(; dims = md.dims, no_arrays = md.no_arrays, scalar_ptrs, ptrmode,
                 cptr_args = md.cptr,
                 # `device` scalars are also scalar_ptrs (so stay type(c_ptr)); this
                 # only withholds their _typed form.
                 devonly = md.devonly,
                 string_args = get(cfg["library"], "string_args", false),
                 own_consts, sibling_enum_mod,
                 bind_names = copy(BIND_NAMES[]), extra_procs)

  # Must precede all emission.
  funcs = neutralize_funcs(funcs, meta)

  has_enums = !isempty(enums) || !isempty(macros)

  # [check] success names a status borrowed from a sibling (rocSOLVER uses rocBLAS's).
  success = let cs = get(get(cfg, "check", Dict()), "success", nothing)
    cs !== nothing ? String(cs) : (isempty(enums) ? nothing : find_success_const(enums, libname))
  end
  # The status names the check routine reports, from the sibling's enums when the
  # status is borrowed (they are then `use`d from the sibling).
  check_names = success === nothing ? String[] : status_names(vcat(enums, sibling_enums), success)

  # Types are emitted only if some binding references one (complex/half structs map
  # to intrinsics or c_ptr); then all of them are, so shared types are never dropped.
  emit_types = !isempty(structs) && any(refs_derived_type, funcs)

  content = ModuleContent(; cfg, meta, funcs, enums, structs, macros, aliases,
                          has_enums, emit_types, success, check_names,
                          extra_generics, extra_wrappers)
  module_path = write_library_module(output_dir, content)
  apply_enum_rename(cfg, module_path)

  success === nothing && @warn "No success constant found for $(libname), no check helper"

  # Surface C types that fell back to an opaque type(c_ptr).
  let unmapped = unmapped_cptr_summary()
    isempty(unmapped) ||
      @info "  $(sum(values(UNMAPPED_CPTR[]))) arg/return/field(s) fell back to opaque type(c_ptr) for $(length(unmapped)) unmapped C type(s):" unmapped
  end

  @info "Wrote $(basename(module_path)) to $(output_dir)"
end

# Fortran is case-insensitive: a #define differing from a function only in case
# (ROCTx's ROCTX_VERSION_MAJOR vs roctx_version_major()) clashes. Drop the constant.
function drop_clashing_macros(macros::Vector{Pair{String,Int64}}, funcs::Vector{FuncInfo})
  fnames = Set{String}(lowercase(f.name) for f in funcs)
  clash = [nm for (nm, _) in macros if lowercase(nm) in fnames]
  isempty(clash) && return macros
  @info "Dropped $(length(clash)) #define constant(s) clashing case-insensitively with a function of the same name:" clash
  return Pair{String,Int64}[p for p in macros if !(lowercase(p.first) in fnames)]
end

# What one library's module is written from.
Base.@kwdef struct ModuleContent
  cfg::Dict
  meta::LibMeta
  funcs::Vector{FuncInfo}
  enums::Vector{EnumInfo}
  structs::Vector{StructInfo}
  macros::Vector{Pair{String,Int64}}
  aliases::Dict{String,String}
  has_enums::Bool
  emit_types::Bool
  success::Union{Nothing,String}           # the status success constant, if any
  check_names::Vector{String}              # the other status names, for the check routine
  extra_generics::Union{Nothing,Function}
  extra_wrappers::Union{Nothing,Function}
end

# One module named after the library, with the enums and types in its
# specification part and the check routine among its procedures. Returns the
# module path.
function write_library_module(output_dir::String, c::ModuleContent)
  (; cfg, meta, funcs, enums, structs, macros, aliases,
     has_enums, emit_types, success, check_names, extra_generics, extra_wrappers) = c
  libname = cfg["general"]["name"]
  write_module_file(output_dir, libname) do io
    gen_module_file(io, cfg, meta, funcs, aliases;
                    extra_generics=extra_generics,
                    extra_wrappers=extra_wrappers,
                    extra_uses=check_names,
                    decls = function (dio)
      has_enums && (emit_enum_decls(dio, enums, macros); println(dio, ""))
      # Sibling-owned types come from the sibling's `use`; redeclaring them
      # (rocblas_bfloat16 in rocsolver) would be a duplicate definition.
      sibs = unique(values(meta.sibling_enum_mod))
      own_structs = [s for s in structs
                     if !any(sib -> sib != libname && startswith(s.name, sib * "_"), sibs)]
      emit_types && !isempty(own_structs) &&
        (emit_type_decls(dio, own_structs); println(dio, ""))
    end,
    check_routine = success === nothing ? nothing :
                    cio -> write_check_routine(cio, cfg, check_names, success))
  end
end

# The <lib>Check subroutine of the library module. The success constant is
# host-associated, so no `use … only:` is needed.
function write_check_routine(cio::IO, cfg::Dict, names::Vector{String}, success::String)
  libname   = cfg["general"]["name"]
  checkname = get(get(cfg, "check", Dict()), "name", "$(libname)Check")
  println(cio, "    subroutine $(checkname)(status)")
  println(cio, "      implicit none")
  println(cio, "      integer(kind($(success))) :: status")
  isempty(names) || println(cio, "      character(len=:), allocatable :: name")
  println(cio, "      if (status /= $(success)) then")
  emit_check_failure(cio, "        ", uppercase(libname), names)
  # `stop 1` is valid in both F2003 and F2008, unlike `error stop`.
  println(cio, "        stop 1")
  println(cio, "      end if")
  println(cio, "    end subroutine $(checkname)")
end

# [library] enum_rename = ["FROM_", "TO_"]: hipSOLVER #defines its enums as
# hipBLAS ones; respelling them HIPSOLVER_* avoids clashing with hipblas when a
# program uses both.
function apply_enum_rename(cfg::Dict, module_path::String)
  ren = get(get(cfg, "library", Dict{String,Any}()), "enum_rename", String[])
  length(ren) == 2 || return
  # When a header already declares both names (HIPSOLVER_DIRECT_FORWARD =
  # HIPBLAS_DIRECT_FORWARD), renaming would duplicate it: drop the FROM_ twin.
  txt  = read(module_path, String)
  have = Set{String}(m.captures[1] for m in
         eachmatch(Regex("(?:enumerator|parameter)\\s*::\\s*($(ren[2])\\w+)"), txt))
  dropped = String[]
  keep = filter(collect(eachline(IOBuffer(txt)))) do ln
    m = match(Regex("(?:enumerator|parameter)\\s*::\\s*($(ren[1])\\w+)"), ln)
    m === nothing && return true
    renamed = replace(m.captures[1], ren[1] => ren[2])
    renamed in have ? (push!(dropped, m.captures[1]); false) : true
  end
  if !isempty(dropped)
    txt = join(keep, "\n") * "\n"
    @info "  Dropped $(length(dropped)) $(ren[1])* declaration(s) the header already aliases as $(ren[2])*:" dropped
  end
  write(module_path, replace(txt, ren[1] => ren[2]))
end
