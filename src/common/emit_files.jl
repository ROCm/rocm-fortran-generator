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

# The library module and its parts (enum and type declarations, interface blocks,
# check routine), built on the element-level emitters of emit.jl. gen_files
# (assemble.jl) decides what goes in.

# Render a module into `<dir>/<base>.F90` and return the path written. Always .F90
# (preprocessed), even without #ifdef, so the file name does not depend on the
# options. A stale `<base>.f90` is removed so the directory never holds two
# definitions of the same module.
function write_module_file(render, dir::AbstractString, base::AbstractString) :: String
  buf = IOBuffer()
  render(buf)
  txt = String(take!(buf))
  other = joinpath(dir, "$(base).f90")
  isfile(other) && rm(other)
  path = joinpath(dir, "$(base).F90")
  write(path, txt)
  return path
end

function _emit_module_procedure(io, procs::Vector{String})
  if length(procs) == 1
    println(io, "    module procedure $(procs[1])")
  else
    println(io, "    module procedure &")
    for (i, p) in enumerate(procs)
      println(io, "      $(p)" * (i < length(procs) ? ",&" : ""))
    end
  end
end

# A named `interface <fname>` block whose bind(C) specific is `<fname>_`, plus the
# given module procedures. The argument and result types are taken from `f` as is.
function emit_named_interface(io, f::FuncInfo, meta::LibMeta;
                              fname::String = f.name,
                              module_procs::Vector{String} = String[],
                              module_procs_assumed::Vector{String} = String[],
                              module_procs_always::Vector{String} = String[],
                              always_rocm_only::Bool = false,
                              module_procs_always_cuda::Vector{String} = String[],
                              alias_of::Union{Nothing,String} = nothing,
                              raw_in_generic::Bool = true)
  if EMIT_DOCS
    argnames = Set{String}(lowercase(a.name) for a in f.args)
    for l in doc_to_fortran_lines(get(meta.docs, f.name, ""), "  ";
                                  argnames=argnames, deny=meta.doc_deny)
      println(io, l)
    end
  end
  sub    = fname * "_"
  kindw  = f.is_void ? "subroutine" : "function"
  joined = join((a.name for a in f.args), ",")
  csym   = bind_symbol(f.name, meta)   # differs from f.name for a forwarding macro
  # hipfort's NVIDIA backend binds the CUDA symbol under USE_CUDA_NAMES; a routine
  # with none is compiled for ROCm only.
  cu     = get(meta.cuda_names, f.name, nothing)
  guard  = hip_only(f, meta)
  guard && println(io, "#ifndef USE_CUDA_NAMES")

  emit_specific(g, subname) = begin
    head = "    $(kindw) $(subname)($(joined))"
    if cu !== nothing
      println(io, "#ifdef USE_CUDA_NAMES")
      emit_bind_signature(io, head, "bind(c, name=\"$(cu)\")", "        ")
      println(io, "#else")
      emit_bind_signature(io, head, "bind(c, name=\"$(csym)\")", "        ")
      println(io, "#endif")
    else
      emit_bind_signature(io, head, "bind(c, name=\"$(csym)\")", "        ")
    end
    println(io, "      use iso_c_binding")
    if HIPFORT
      for m in hipfort_scope_uses(g, meta); println(io, "      use $(m)"); end
    else
      # The enums, types and handles live in the host module (and sibling names are
      # `use`d there), and an interface body only sees the host through IMPORT
      # (which must follow any USE and precede IMPLICIT NONE).
      println(io, "      import")
    end
    println(io, "      implicit none")
    g.is_void || println(io, "      $(g.ret_ftype) :: $(subname)")
    for a in g.args
      if a.suffix == "(*)"
        println(io, "      $(a.ftype) :: $(a.name)(*)")
      else
        println(io, "      $(a.ftype)$(replace(a.suffix, ", value" => ",value")) :: $(a.name)")
      end
    end
    println(io, "    end $(kindw)")
  end

  if alias_of !== nothing
    # Versioned alias: reuse the target's bind(C) specific, already declared.
    println(io, "  interface $(fname)")
    raw_in_generic && println(io, "    procedure $(alias_of)_")
  elseif raw_in_generic
    println(io, "  interface $(fname)")
    emit_specific(f, sub)
  else
    # The bind(C) specific stays callable as `<fname>_`, but outside the generic: the
    # generic's module procedure has the same arguments (see wants_opt).
    println(io, "  interface")
    emit_specific(f, sub)
    println(io, "  end interface")
    println(io, "")
    println(io, "  interface $(fname)")
  end

  # Plain F2003 forms (_typed, _opt, _devptr), listed outside the array guard.
  # They are module procedures, not second bind(C) specifics: F2018 19.2 allows one
  # interface per binding label.
  # A routine bound to the CUDA driver API keeps only module_procs_always_cuda (its
  # _opt form) under USE_CUDA_NAMES (see maps_to_cuda_driver).
  if !isempty(module_procs_always)
    println(io, "")
    rocm_only = always_rocm_only && module_procs_always_cuda != module_procs_always
    if rocm_only && !isempty(module_procs_always_cuda)
      println(io, "#ifdef USE_CUDA_NAMES")
      _emit_module_procedure(io, module_procs_always_cuda)
      println(io, "#else")
    else
      rocm_only && println(io, "#ifndef USE_CUDA_NAMES")
    end
    _emit_module_procedure(io, module_procs_always)
    rocm_only && println(io, "#endif")
  end
  # Array overloads, guarded by tier: USE_ASSUMED_SHAPE selects the per-rank set
  # (F2008), USE_ASSUMED_RANK the dimension(..) form (F2018). The two cannot coexist
  # in one generic (an assumed-rank dummy is not distinguishable by rank).
  if !isempty(module_procs) && ARRAY_IFACES !== :none
    println(io, "")
    if !isempty(module_procs_assumed) && module_procs_assumed != module_procs
      # Must match the guard of the bodies in emit_wrappers_body, or the generic
      # names procedures the module did not compile.
      emit_tier_guard(io,
        o -> _emit_module_procedure(o, module_procs_assumed),
        o -> _emit_module_procedure(o, module_procs))
    else
      # No distinct assumed-rank form: the same overloads serve both tiers.
      emit_either_tier(io, o -> _emit_module_procedure(o, module_procs))
    end
  end
  println(io, "  end interface")
  guard && println(io, "#endif")
  println(io, "")
end

# One generic per function, `interface X` around its bind(C) specific `X_` (as in
# hipfort), so adding an overload later never changes what X or X_ is. Then the
# versioned aliases, after their target's generic, whose specifics they name.
function emit_interface_body(io, funcs::Vector{FuncInfo}, meta::LibMeta,
                             aliases::Dict{String,String} = Dict{String,String}())
  byname = Dict(f.name => f for f in funcs)

  # Versioned aliases: the short name bound to the versioned C symbol
  # (hipGetDeviceProperties -> hipGetDevicePropertiesR0600).
  alias_pairs = Tuple{String,String}[]
  for (target, short) in sort(collect(aliases))
    haskey(byname, target) || continue
    haskey(byname, short)  && continue
    push!(alias_pairs, (target, short))
  end
  !isempty(alias_pairs) && @info "Added $(length(alias_pairs)) versioned-alias interface(s)"

  for f in funcs
    emit_generic(io, f, meta)
  end
  # An alias is a generic naming its target's procedures, never a second bind(C)
  # interface on the target's binding label (F2018 19.2).
  for (target, short) in alias_pairs
    emit_generic(io, byname[target], meta; alias=short)
  end
end

# The enum declarations of the module's specification part: one `enum, bind(c)`
# block per C enum, plus integer parameters for the #define constants.
function emit_enum_decls(io, enums::Vector{EnumInfo},
                         macros::Vector{Pair{String,Int64}} = Pair{String,Int64}[];
                         meta::LibMeta = LibMeta())
  # Fortran names are case-insensitive: drop the #defines that clash with an enumerator.
  seen = Set{String}()
  for e in enums, (nm, _) in e.constants; push!(seen, lowercase(nm)); end
  fresh = [(nm, val) for (nm, val) in macros if lowercase(nm) ∉ seen]

  # hipfort's CUDA values, keyed by the spelling the module ends up with (the
  # enum_rename applied after emission).
  ren = meta.enum_rename
  cuda_value(nm) = something(get(meta.enum_cuda, nm, nothing),
                             length(ren) == 2 ? get(meta.enum_cuda, replace(nm, ren[1] => ren[2]), nothing) : nothing,
                             Some(nothing))

  for e in enums
    !isempty(e.name) && println(io, "  ! $(e.name)")
    println(io, "  enum, bind(c)")
    for (nm, val) in e.constants
      cv = cuda_value(nm)
      if cv !== nothing
        println(io, "#ifdef USE_CUDA_NAMES")
        println(io, "    enumerator :: $(nm) = $(cv)")
        println(io, "#else")
        println(io, "    enumerator :: $(nm) = $(val)")
        println(io, "#endif")
      else
        println(io, "    enumerator :: $(nm) = $(val)")
      end
    end
    println(io, "  end enum")
    println(io, "")
  end

  if !isempty(fresh)
    for (nm, val) in fresh
      if -2147483647 <= val <= 2147483647
        println(io, "  integer(c_int), parameter :: $(nm) = $(val)")
      elseif 0 < val <= 4294967295
        # An `unsigned int` flag with the top bit set (hipHostMallocNonCoherent, ...):
        # emit the same 32 bits as a signed c_int so it can be passed to the
        # `integer(c_int), value :: flags` dummy. `-2147483648` is not a valid literal
        # (unary minus applied to an out-of-range 2147483648), hence `-2147483647 - 1`.
        signed = val - 4294967296
        lit = signed == -2147483648 ? "-2147483647 - 1" : string(signed)
        println(io, "  integer(c_int), parameter :: $(nm) = $(lit)  ! 0x$(string(val, base=16))")
      else
        println(io, "  integer(c_int64_t), parameter :: $(nm) = $(val)_c_int64_t")
      end
    end
    println(io, "")
  end
end

# The bind(C) derived type declarations of the module's specification part.
function emit_type_decls(io, structs::Vector{StructInfo}; meta::LibMeta = LibMeta())
  emit_struct(s) = begin
    println(io, "  type, bind(c) :: $(s.name)")
    for f in s.fields
      # dim3 components default to 1 (as in hipfort), so dim3(320) is a valid constructor.
      init = (s.name == "dim3" && isempty(f.dims)) ? " = 1" : ""
      line = "    $(f.ftype) :: $(f.name)$(f.dims)$(init)"
      if !isempty(f.doc)
        budget = 128 - length(line) - length(" !< ")   # keep the line ≤ 132 (ifort-safe)
        doc = length(f.doc) <= budget ? f.doc : (budget > 4 ? first(f.doc, budget - 3) * "..." : "")
        isempty(doc) || (line *= " !< $(doc)")
      end
      println(io, line)
    end
    println(io, "  end type $(s.name)")
  end
  for s in structs
    cbody = get(meta.type_cuda, s.name, nothing)
    if cbody !== nothing
      # CUDA's layout of the type, maintained by hand (hipDeviceProp_t).
      println(io, "#ifdef USE_CUDA_NAMES")
      println(io, cbody)
      println(io, "#else")
      emit_struct(s)
      println(io, "#endif")
    else
      emit_struct(s)
    end
    println(io, "")
  end
end

# The library's success status code. Prefer a zero-valued one prefixed by the
# library name (hipSPARSE also sees hipSuccess), then any success code (rocSOLVER
# reuses rocblas_status_success).
function find_success_const(enums::Vector{EnumInfo}, libname::String)
  up = uppercase(libname)
  pref_any = nothing
  any_zero = nothing
  any_one  = nothing
  for e in enums, (nm, val) in e.constants
    endswith(lowercase(nm), "success") || continue
    isown = startswith(uppercase(nm), up)
    isown && val == 0 && return nm
    isown && pref_any === nothing && (pref_any = nm)
    val == 0 && any_zero === nothing && (any_zero = nm)
    any_one === nothing && (any_one = nm)
  end
  return something(pref_any, any_zero, any_one, Some(nothing))
end

# The other enumerators of the status enum holding `success`, one name per value
# (a `select case` value may appear only once; some status enums carry aliases).
# Empty when the success constant is not defined here.
function status_names(enums::Vector{EnumInfo}, success::String)
  for e in enums
    vals = Dict(lowercase(nm) => v for (nm, v) in e.constants)
    haskey(vals, lowercase(success)) || continue
    sval = vals[lowercase(success)]
    seen = Set{Int64}([sval])
    names = String[]
    for (nm, v) in e.constants
      v ∈ seen && continue
      push!(seen, v); push!(names, nm)
    end
    return names
  end
  return String[]
end

# The declaration of the status name of a <lib>Check, as long as the longest
# name. A fixed length rather than `character(len=:), allocatable`: the Cray
# compiler warns that a deferred-length name may be used unallocated (ftn-7206),
# even when an assignment allocates it first.
check_name_decl(names::Vector{String}) =
  "character(len=$(maximum(length, [names; "unknown status"]))) :: name"

# The failure branch of a <lib>Check: print the status name (or just the code
# without names). A `select case` rather than a call to the library's to-string
# function, which not every library provides. `name` is set before the
# `select case` rather than in a `case default`, so it is set on every path.
function emit_check_failure(io, ind::String, label::String, names::Vector{String})
  if isempty(names)
    println(io, "$(ind)write (*, *) \"$(label) ERROR: code = \", status")
    return
  end
  println(io, "$(ind)name = \"unknown status\"")
  println(io, "$(ind)select case (status)")
  for nm in names
    println(io, "$(ind)case ($(nm))")
    println(io, "$(ind)  name = \"$(nm)\"")
  end
  println(io, "$(ind)end select")
  println(io, "$(ind)write (*, \"(a,i0,a)\") \"$(label) ERROR: \" // trim(name) // \" (code \", status, \")\"")
end

# The names of the intrinsic module iso_c_binding (Fortran 2018).
const ISO_C_NAMES = Set{String}([
  "c_int", "c_short", "c_long", "c_long_long", "c_signed_char", "c_size_t",
  "c_int8_t", "c_int16_t", "c_int32_t", "c_int64_t",
  "c_int_least8_t", "c_int_least16_t", "c_int_least32_t", "c_int_least64_t",
  "c_int_fast8_t", "c_int_fast16_t", "c_int_fast32_t", "c_int_fast64_t",
  "c_intmax_t", "c_intptr_t", "c_ptrdiff_t",
  "c_float", "c_double", "c_long_double",
  "c_float_complex", "c_double_complex", "c_long_double_complex",
  "c_bool", "c_char", "c_null_char", "c_alert", "c_backspace", "c_form_feed",
  "c_new_line", "c_carriage_return", "c_horizontal_tab", "c_vertical_tab",
  "c_ptr", "c_funptr", "c_null_ptr", "c_null_funptr",
  "c_associated", "c_f_pointer", "c_f_procpointer", "c_funloc", "c_loc", "c_sizeof"])

const USE_LINE = r"^\s*use\s*(?:,\s*intrinsic\s*::)?\s*(\w+)\s*$"i

# The `use` lines of the interface bodies and module procedures in `body`, moved to
# the module: a module procedure sees the module by host association, and an
# interface body through IMPORT. ftn (HPE Cray) reads a module again for each
# `use`, which made a module of thousands of interfaces and wrappers take an
# hour to compile, against seconds with IMPORT; gfortran is faster too.
#
# Only a `use <module>` of a module that `hoistable(module)` accepts goes; a
# `use ..., only:` stays, before the IMPORT. The `use` lines of a scope are the
# ones just above its `implicit none`, and a preprocessor line ends them, so a
# conditional `use` stays as it was. Returns the new body and the modules whose
# `use` lines went.
function hoist_scope_uses(body::AbstractString, hoistable::Function)
  lines = split(body, '\n')
  keep = trues(length(lines))
  add_import = falses(length(lines))   # an IMPORT before this `implicit none`
  hoisted = Set{String}()
  in_iface = 0
  for (i, l) in enumerate(lines)
    if occursin(r"^\s*(abstract\s+)?interface(\s|$)"i, l)
      in_iface += 1
    elseif occursin(r"^\s*end\s+interface"i, l)
      in_iface -= 1
    end
    occursin(r"^\s*implicit\s+none\s*$"i, l) || continue
    first = i
    while first > 1 && occursin(r"^\s*(use|import)\b"i, lines[first - 1])
      first -= 1
    end
    first == i && continue
    dropped = false
    has_import = false
    for j in first:i-1
      occursin(r"^\s*import\b"i, lines[j]) && (has_import = true; continue)
      m = match(USE_LINE, lines[j])
      if m !== nothing && hoistable(lowercase(m.captures[1]))
        keep[j] = false
        dropped = true
        push!(hoisted, lowercase(m.captures[1]))
      end
    end
    dropped && in_iface > 0 && !has_import && (add_import[i] = true)
  end
  out = String[]
  for (i, l) in enumerate(lines)
    add_import[i] && push!(out, match(r"^\s*", l).match * "import")
    keep[i] && push!(out, l)
  end
  return join(out, '\n'), hoisted
end

# The lowercase identifiers of `text`.
identifiers(text::AbstractString) =
  Set{String}(lowercase(m.match) for m in eachmatch(r"\b[A-Za-z_]\w*\b", text))

# The module-level `use ..., only:` lines that give the module what
# hoist_scope_uses moved out of its scopes, as (use, names) pairs; the caller
# makes the names PRIVATE so that the module exports what it did. The names of
# iso_c_binding, unless the module re-exports it already (`iso_exported`), and
# the constants of each sibling library's enums module that the scopes name.
function hoisted_host_uses(body::AbstractString, hoisted::Set{String},
                           host_mods::Set{String}, iso_exported::Bool,
                           sibling_consts::Dict{String,Set{String}})
  ids = identifiers(body)
  uses = Pair{String,Vector{String}}[]
  add(use, names) = isempty(names) || push!(uses, use => sort(collect(names)))
  ("iso_c_binding" in hoisted && !iso_exported) &&
    add("use, intrinsic :: iso_c_binding", intersect(ids, ISO_C_NAMES))
  for mod in sort(collect(setdiff(hoisted, host_mods, Set(["iso_c_binding"]))))
    consts = get(sibling_consts, mod, Set{String}())
    add("use $(mod)", Set{String}(c for c in consts if lowercase(c) in ids))
  end
  return uses
end

# The library module: the declarations (`decls`), the interfaces and the wrappers,
# with the <lib>Check routine (`check_routine`, if any) among its procedures. The
# hooks are called as `hook(io)`.
function gen_module_file(io, cfg::Dict, meta::LibMeta,
                         funcs::Vector{FuncInfo}, aliases::Dict{String,String};
                         decls::Function,
                         extra_generics::Union{Nothing,Function} = nothing,
                         extra_wrappers::Union{Nothing,Function} = nothing,
                         extra_uses::Vector{String} = String[],
                         extra_modules::Vector{String} = String[],
                         check_routine::Union{Nothing,Function} = nothing,
                         enums_have_iso::Bool = false)
  libname = cfg["general"]["name"]
  mb = modbase(cfg)
  # The body first: the module-level `use` lines depend on what its scopes name.
  bio = IOBuffer()
  gen_module_body(bio, cfg, meta, funcs, aliases; decls, extra_generics,
                  extra_wrappers, check_routine)
  sibling_consts = Dict{String,Set{String}}()
  for (c, m) in meta.sibling_enum_mod; push!(get!(sibling_consts, m, Set{String}()), c); end
  if HIPFORT
    used = ["hipfort_$(u)" for u in meta.uses]
    host_mods = Set{String}(vcat(used, extra_modules))
    meta.has_enums && push!(host_mods, "$(mb)_enums")
    meta.has_types && push!(host_mods, "$(mb)_types")
    # A types module, the HIP families, a used library module and an enums module
    # with parameters re-export iso_c_binding.
    iso_exported = mb == "hipfort" || meta.has_types || !isempty(extra_modules) ||
                   !isempty(used) || (meta.has_enums && enums_have_iso) ||
                   !(meta.has_enums || meta.has_types || !isempty(extra_modules))
  else
    host_mods = Set(["iso_c_binding"])
    iso_exported = true
  end
  hoistable(m) = m == "iso_c_binding" || m in host_mods || haskey(sibling_consts, m)
  body, hoisted = hoist_scope_uses(String(take!(bio)), hoistable)
  host_uses = hoisted_host_uses(body, hoisted, host_mods, iso_exported, sibling_consts)

  emit_license_header(io; years = license_years(cfg))
  println(io, "module $(mb)")
  if HIPFORT
    # The enums and types are modules of their own, re-exported from here; the
    # interface bodies `use` them (and any sibling's) themselves.
    if EMIT_CUDA && mb == "hipfort"
      println(io, "#ifdef USE_CUDA_NAMES")
      println(io, "  use hipfort_cuda_errors")
      println(io, "#endif")
    end
    # A used library module first: `use hipfort_hipfftxt` alone gives hipFFT too.
    for m in used; println(io, "  use $(m)"); end
    meta.has_enums && println(io, "  use $(mb)_enums")
    meta.has_types && println(io, "  use $(mb)_types")
    for m in extra_modules; println(io, "  use $(m)"); end
    # Otherwise an enums or types module brings iso_c_binding.
    (meta.has_enums || meta.has_types || !isempty(extra_modules) || !isempty(used)) ||
      println(io, "  use, intrinsic :: iso_c_binding")
  else
    # The interface bodies IMPORT from this module, so names borrowed from a sibling
    # library (rocSOLVER uses rocBLAS's status) are `use`d here, one narrow
    # `use, only:` per sibling, wrapped to stay within 132 columns.
    for u in sibling_module_uses(funcs, libname, meta; extra=extra_uses); println_wrapped(io, "  use $(u)", "    "); end
    println(io, "  use, intrinsic :: iso_c_binding")
  end
  for (use, names) in host_uses
    println_wrapped(io, "  $(use), only: $(join(names, ", "))", "    ")
  end
  println(io, "  implicit none")
  for (_, names) in host_uses
    println_wrapped(io, "  private :: $(join(names, ", "))", "    ")
  end
  println(io, "")
  print(io, body)
  println(io, "end module $(mb)")
end

# The declarations, interfaces and procedures of the library module, down to
# `end module` (see gen_module_file).
function gen_module_body(io, cfg::Dict, meta::LibMeta, funcs::Vector{FuncInfo},
                         aliases::Dict{String,String}; decls::Function,
                         extra_generics::Union{Nothing,Function},
                         extra_wrappers::Union{Nothing,Function},
                         check_routine::Union{Nothing,Function})
  decls(io)
  emit_interface_body(io, funcs, meta, aliases)
  extra_generics !== nothing && extra_generics(io)
  # The check routine and the _typed bodies are plain F2003: their `contains` sits
  # outside the array guard, as their generics do.
  opened_contains = false
  if check_routine !== nothing || needs_typed(funcs, meta)
    println(io, "")
    println(io, "  contains")
    println(io, "")
    check_routine !== nothing && check_routine(io)
    needs_typed(funcs, meta) && emit_typed_body(io, funcs, meta)
    opened_contains = true
  end
  # Skipped as a whole under ARRAY_IFACES=:none, so no empty `#if` or bare
  # `contains` is left behind. Both tiers resolve to the wrappers emitted here.
  if ARRAY_IFACES !== :none && (needs_wrappers(funcs, meta) || extra_wrappers !== nothing)
    println(io, "")
    GUARDED_IFACES && println(io, "#if defined(USE_ASSUMED_SHAPE) || defined(USE_ASSUMED_RANK)")
    opened_contains || println(io, "  contains")
    println(io, "")
    needs_wrappers(funcs, meta) && emit_wrappers_body(io, funcs, meta)
    extra_wrappers !== nothing && extra_wrappers(io)
    GUARDED_IFACES && println(io, "#endif")
  end
  emit_doxygen_groups(io, cfg)
end

# ---- hipfort layout ----

# Whether <mb>_enums uses (and so re-exports) iso_c_binding: only for the
# #define parameters that are not enum constants, whose kinds name it.
function enums_need_iso(enums::Vector{EnumInfo}, macros::Vector{Pair{String,Int64}})
  seen = Set{String}(lowercase(nm) for e in enums for (nm, _) in e.constants)
  return any(m -> lowercase(m.first) ∉ seen, macros)
end

# <mb>_enums: the library's enum constants and #define parameters, in their own
# module.
function gen_hipfort_enums_file(io, cfg::Dict, enums::Vector{EnumInfo},
                                macros::Vector{Pair{String,Int64}}, meta::LibMeta)
  mb = meta.modbase
  emit_license_header(io; years = license_years(cfg))
  println(io, "module $(mb)_enums")
  enums_need_iso(enums, macros) && println(io, "  use, intrinsic :: iso_c_binding")
  println(io, "  implicit none")
  println(io, "")
  emit_enum_decls(io, enums, macros; meta)
  println(io, "end module $(mb)_enums")
end

# <mb>_types: the library's bind(C) derived types. Only the HIP runtime had a
# types module in hipfort; the others date from 2026.
function gen_hipfort_types_file(io, structs::Vector{StructInfo}, meta::LibMeta)
  mb = meta.modbase
  emit_license_header(io; years = mb == "hipfort" ? "2020-2026" : "2026")
  println(io, "module $(mb)_types")
  println(io, "  use, intrinsic :: iso_c_binding")
  println(io, "  implicit none")
  println(io, "")
  emit_type_decls(io, structs; meta)
  println(io, "end module $(mb)_types")
end

# <lib>.checkmeta, assembled with the other libraries' into hipfort_check by
# generate_all.jl (gen_unified_check_file): the routine name, the success constant,
# the module defining it ([check] module, for a borrowed status), the label of the
# message, then the other status names.
function write_check_meta(output_dir, cfg::Dict, success::String, names::Vector{String},
                          meta::LibMeta)
  libname   = cfg["general"]["name"]
  checkname = get(get(cfg, "check", Dict()), "name", "$(libname)Check")
  checkmod  = get(get(cfg, "check", Dict()), "module", "$(meta.modbase)_enums")
  open(joinpath(output_dir, "$(libname).checkmeta"), "w") do io
    println(io, checkname)
    println(io, success)
    println(io, checkmod)
    println(io, uppercase(libname))
    for nm in names; println(io, nm); end
  end
end

# The .checkmeta files of every generated directory, by file name so the module
# does not depend on directory order.
function collect_metas(dirs, suffix::String)
  paths = String[]
  for d in dirs, f in readdir(d)
    endswith(f, suffix) && push!(paths, joinpath(d, f))
  end
  return sort(paths; by = basename)
end

# hipfort_check: every <lib>Check of the hipfort layout in one module. Each
# subroutine `use`s its constants `only:`, so a constant two enums modules export
# (rocBLAS and rocSOLVER) never clashes. A library reusing another's status
# (rocSOLVER) borrows the names of the library that defines it.
function gen_unified_check_file(dirs, dest_dir::String)
  metas = collect_metas(dirs, ".checkmeta")
  isempty(metas) && return
  entries = Tuple{String,String,String,String,Vector{String}}[]
  for m in metas
    ls = readlines(m)
    length(ls) >= 4 && push!(entries, (ls[1], ls[2], ls[3], ls[4], ls[5:end]))
  end
  isempty(entries) && return
  byok = Dict{String,Vector{String}}()
  for e in entries
    isempty(e[5]) || (byok[lowercase(e[2])] = e[5])
  end
  open(joinpath(dest_dir, "hipfort_check.F90"), "w") do io
    emit_license_header(io; years = "2020-2026")
    println(io, "module hipfort_check")
    println(io, "  implicit none")
    println(io, "contains")
    seen = Set{String}()
    for (checkname, success, mod, label, own) in entries
      lowercase(checkname) ∈ seen && continue   # rocSOLVER shares rocBLAS's success code
      push!(seen, lowercase(checkname))
      names = isempty(own) ? get(byok, lowercase(success), String[]) : own
      named = !isempty(names)
      use_named = "    use $(mod), only: " * join([success; names], ", ")
      println(io, "  subroutine $(checkname)(status)")
      if EMIT_CUDA
        # Under USE_CUDA_NAMES the status is CUDA's, whose values the HIP
        # enumerators do not follow: that build prints the code only, and the HIP
        # runtime compares to cudaSuccess.
        println(io, "#ifdef USE_CUDA_NAMES")
        if checkname == "hipCheck"
          println(io, "    use hipfort_cuda_errors, only: cudaSuccess")
          println(io, "    implicit none")
          println(io, "    integer(kind(cudaSuccess)) :: status")
          println(io, "    if (status /= cudaSuccess) then")
        else
          println(io, "    use $(mod), only: $(success)")
          println(io, "    implicit none")
          println(io, "    integer(kind($(success))) :: status")
          println(io, "    if (status /= $(success)) then")
        end
        println(io, "      write (*, *) \"$(label) ERROR: code = \", status")
        println(io, "#else")
      end
      println_wrapped(io, named ? use_named : "    use $(mod), only: $(success)", "      ")
      println(io, "    implicit none")
      println(io, "    integer(kind($(success))) :: status")
      named && println(io, "    $(check_name_decl(names))")
      println(io, "    if (status /= $(success)) then")
      emit_check_failure(io, "      ", label, names)
      EMIT_CUDA && println(io, "#endif")
      # `stop 1` is valid in both F2003 and F2008, unlike `error stop`.
      println(io, "      stop 1")
      println(io, "    end if")
      println(io, "  end subroutine $(checkname)")
    end
    println(io, "end module hipfort_check")
  end
end

# The `\defgroup`s of the library's `[doxygen] groups`, before `end module`. The
# functions' comments carry `\ingroup <name>`, but the headers define the groups in
# comments attached to no declaration, which libclang never reports: without these
# Doxygen warns "Found non-existing group", fatal in hipfort's docs build.
function emit_doxygen_groups(io, cfg::Dict)
  EMIT_DOCS || return
  groups = get(get(cfg, "doxygen", Dict()), "groups", [])
  isempty(groups) && return
  for g in groups
    println(io, "")
    println(io, "  !>   @defgroup $(g["name"]) $(g["title"])")
    println(io, "  !>")
    if haskey(g, "parent")
      println(io, "  !>   @ingroup $(g["parent"])")
      println(io, "  !>")
    end
    if haskey(g, "brief")
      println_doc_wrapped(io, "  !>   ", g["brief"])
      println(io, "  !>")
    end
    if haskey(g, "note")
      println_doc_wrapped(io, "  !>   ", "@note  " * g["note"])
      println(io, "  !>")
    end
  end
end

# Print `text` as `!>` comment lines starting with `prefix`, wrapped at word
# boundaries to stay within FORTRAN_MAX_COL, as the function docstrings are.
function println_doc_wrapped(io, prefix::String, text::AbstractString)
  cur = prefix
  for w in split(text)
    cand = cur == prefix ? cur * w : cur * " " * w
    if length(cand) > FORTRAN_MAX_COL && cur != prefix
      println(io, cur)
      cur = prefix * w
    else
      cur = cand
    end
  end
  cur != prefix && println(io, cur)
end
