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
                              alias_of::Union{Nothing,String} = nothing,
                              raw_in_generic::Bool = true)
  sub    = fname * "_"
  kindw  = f.is_void ? "subroutine" : "function"
  joined = join((a.name for a in f.args), ",")
  csym   = bind_symbol(f.name, meta)   # differs from f.name for a forwarding macro

  emit_specific(g, subname) = begin
    emit_bind_signature(io, "    $(kindw) $(subname)($(joined))", "bind(c, name=\"$(csym)\")", "        ")
    println(io, "      use iso_c_binding")
    # The enums, types and handles live in the host module (and sibling names are
    # `use`d there), and an interface body only sees the host through IMPORT
    # (which must follow any USE and precede IMPLICIT NONE).
    println(io, "      import")
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
  if !isempty(module_procs_always)
    println(io, "")
    _emit_module_procedure(io, module_procs_always)
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
                         macros::Vector{Pair{String,Int64}} = Pair{String,Int64}[])
  # Fortran names are case-insensitive: drop the #defines that clash with an enumerator.
  seen = Set{String}()
  for e in enums, (nm, _) in e.constants; push!(seen, lowercase(nm)); end
  fresh = [(nm, val) for (nm, val) in macros if lowercase(nm) ∉ seen]

  for e in enums
    !isempty(e.name) && println(io, "  ! $(e.name)")
    println(io, "  enum, bind(c)")
    for (nm, val) in e.constants
      println(io, "    enumerator :: $(nm) = $(val)")
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
function emit_type_decls(io, structs::Vector{StructInfo})
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
    emit_struct(s)
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

# The failure branch of a <lib>Check: print the status name (or just the code
# without names). A `select case` rather than a call to the library's to-string
# function, which not every library provides.
function emit_check_failure(io, ind::String, label::String, names::Vector{String})
  if isempty(names)
    println(io, "$(ind)write (*, *) \"$(label) ERROR: code = \", status")
    return
  end
  println(io, "$(ind)select case (status)")
  for nm in names
    println(io, "$(ind)case ($(nm))")
    println(io, "$(ind)  name = \"$(nm)\"")
  end
  println(io, "$(ind)case default")
  println(io, "$(ind)  name = \"unknown status\"")
  println(io, "$(ind)end select")
  println(io, "$(ind)write (*, \"(a,i0,a)\") \"$(label) ERROR: \" // name // \" (code \", status, \")\"")
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
                         check_routine::Union{Nothing,Function} = nothing)
  libname = cfg["general"]["name"]
  emit_license_header(io)
  println(io, "module $(libname)")
  # The interface bodies IMPORT from this module, so names borrowed from a sibling
  # library (rocSOLVER uses rocBLAS's status) are `use`d here, one narrow
  # `use, only:` per sibling, wrapped to stay within 132 columns.
  for u in sibling_module_uses(funcs, libname, meta; extra=extra_uses); println_wrapped(io, "  use $(u)", "    "); end
  println(io, "  use, intrinsic :: iso_c_binding")
  println(io, "  implicit none")
  println(io, "")
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
  println(io, "end module $(libname)")
end
