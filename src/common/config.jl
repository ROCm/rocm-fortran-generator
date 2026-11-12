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

# Collectors filled by the Clang frontend, and small helpers over the IR.

# Fortran routine name => C symbol for `bind(C, name=...)` when they differ: the
# documented API name is a forwarding macro over another ABI symbol (ROCTx:
# roctxMark => roctxMarkA). Global because the frontend fills it before gen_files,
# which copies it into LibMeta.bind_names.
const BIND_NAMES = Ref(Dict{String,String}())
bind_symbol(name::AbstractString, meta::LibMeta) = get(meta.bind_names, name, String(name))

# Rename each function to its forwarding-macro name (`fwd`: C symbol => macro name)
# and record the C symbol to bind against.
function apply_bind_renames!(funcs::Vector{FuncInfo}, fwd::Dict{String,String}) :: Vector{FuncInfo}
  isempty(fwd) && return funcs
  out = FuncInfo[]
  for f in funcs
    short = get(fwd, f.name, nothing)
    if short === nothing
      push!(out, f)
    else
      BIND_NAMES[][short] = f.name
      haskey(DOCS[], f.name) && (DOCS[][short] = DOCS[][f.name])
      push!(out, FuncInfo(short, f.ret_ftype, f.is_void, f.args))
    end
  end
  return out
end

# typedef name => emitted derived-type name, set by collect_structs, so that
# revert_unknown_structs renames an argument spelled with another typedef of an
# emitted struct (fftwf_iodim => fftw_iodim) instead of reverting it to c_ptr.
# Global because the frontend fills it before gen_files, its only reader, runs.
const RECORD_ALIASES = Ref(Dict{String,String}())

# C types that cltype_to_fortran could not map and fell back to an opaque
# type(c_ptr) (deliberate c_ptr cases are not counted). Reset per library in
# collect_funcs and reported by gen_files. Global because it is a diagnostics
# collector filled deep inside the type mapping.
const UNMAPPED_CPTR = Ref(Dict{String,Int}())

reset_unmapped_cptr!() = (UNMAPPED_CPTR[] = Dict{String,Int}(); nothing)

# Keyed by clean_type_name (defined in type_mapping.jl, included later) so
# `const foo *` and `foo*` group together.
function record_unmapped_cptr!(spelling::AbstractString)
  key = clean_type_name(spelling)
  isempty(strip(key)) && (key = "<anonymous>")
  d = UNMAPPED_CPTR[]
  d[key] = get(d, key, 0) + 1
  return nothing
end

# "type ×count" lines, most frequent first.
function unmapped_cptr_summary() :: Vector{String}
  d = UNMAPPED_CPTR[]
  isempty(d) && return String[]
  return ["$(k) ×$(d[k])" for k in sort!(collect(keys(d)); by = k -> (-d[k], k))]
end


# True if the routine references a derived type other than c_ptr/c_funptr, i.e.
# the module needs the library's type declarations.
function refs_derived_type(f::FuncInfo) :: Bool
  isderiv(ft) = (m = match(r"^type\((\w+)\)", ft); m !== nothing && !(m.captures[1] in ("c_ptr", "c_funptr")))
  any(a -> isderiv(a.ftype), f.args) || (!f.is_void && isderiv(f.ret_ftype))
end

# Spell a kind borrowed from the HIP runtime as `integer(c_int)` (ABI-identical to
# an `enum, bind(c)` kind), so hipBLAS, hipSOLVER and hipSPARSE do not depend on the
# `hip` module for one enumerator. Own and sibling kinds are kept.
function neutralize_foreign_kinds(ft::AbstractString, meta::LibMeta) :: String
  occursin("integer(kind(", ft) || return String(ft)
  return replace(String(ft), r"integer\(kind\((\w+)\)\)" => function (m)
    c = match(r"kind\((\w+)\)", m).captures[1]
    (c in meta.own_consts || haskey(meta.sibling_enum_mod, c)) ? m : "integer(c_int)"
  end)
end

neutralize_funcs(funcs::Vector{FuncInfo}, meta::LibMeta) = [
  FuncInfo(f.name, neutralize_foreign_kinds(f.ret_ftype, meta), f.is_void,
           [ArgInfo(a.name, neutralize_foreign_kinds(a.ftype, meta), a.suffix, a.is_string)
            for a in f.args]) for f in funcs]

# One module-level `use <sib>, only: ...` per sibling, naming the union of what
# this library borrows. A bare `use rocblas` makes every interface's IMPORT copy
# all of rocBLAS (>5.9 GB on rocsolver); a per-routine `use, only` makes gfortran
# re-read rocblas.mod thousands of times. The `uses` modules come first, bare, so
# that the module re-exports them.
function sibling_module_uses(funcs::Vector{FuncInfo}, libname::String, meta::LibMeta;
                             extra::Vector{String} = String[]) :: Vector{String}
  isempty(meta.sibling_enum_mod) && return copy(meta.uses)
  bymod = Dict{String,Set{String}}()
  for f in funcs, u in sibling_use_onlys(f, libname, meta)
    mod, names = split(u, ", only: "; limit = 2)
    union!(get!(bymod, String(mod), Set{String}()), String.(split(names, ", ")))
  end
  # Constants named outside the interfaces (the check routine's status names).
  for c in extra
    (c in meta.own_consts || !haskey(meta.sibling_enum_mod, c)) && continue
    push!(get!(bymod, meta.sibling_enum_mod[c], Set{String}()), c)
  end
  return vcat(meta.uses,
              [ "$(mod), only: " * join(sort(collect(names)), ", ")
                for (mod, names) in sort(collect(bymod); by = first) if !(mod in meta.uses) ])
end

function sibling_use_onlys(f::FuncInfo, libname::String, meta::LibMeta) :: Vector{String}
  isempty(meta.sibling_enum_mod) && return String[]
  sibs = unique(values(meta.sibling_enum_mod))
  bymod = Dict{String,Set{String}}()
  take(mod, nm) = push!(get!(bymod, mod, Set{String}()), nm)
  scan(ft) = begin
    for m in eachmatch(r"kind\((\w+)\)", ft)
      c = m.captures[1]
      c in meta.own_consts && continue
      haskey(meta.sibling_enum_mod, c) && take(meta.sibling_enum_mod[c], c)
    end
    for m in eachmatch(r"type\((\w+)\)", ft)
      t = m.captures[1]
      for sib in sibs
        (sib != libname && startswith(t, sib * "_")) && (take(sib, t); break)
      end
    end
  end
  for a in f.args; scan(a.ftype); end
  f.is_void || scan(f.ret_ftype)
  return [ "$(mod), only: " * join(sort(collect(names)), ", ")
           for (mod, names) in sort(collect(bymod); by = first) ]
end

# ---- hipfort layout ----

# C function => its Doxygen comment, filled by collect_funcs when EMIT_DOCS and
# copied into LibMeta.docs by gen_files. Global like BIND_NAMES: the frontend fills
# it before gen_files runs.
const DOCS = Ref(Dict{String,String}())

# Module base name: `hipfort` for the HIP runtime and `hipfort_<lib>` otherwise in
# the hipfort layout, the library name in the packaged one.
modbase(cfg::Dict) = (name = cfg["general"]["name"];
                      !HIPFORT ? name : name == "hip" ? "hipfort" : "hipfort_$(name)")

# The `use` lines of an interface body or a module procedure in the hipfort layout,
# where the enums and types are separate modules: the library's own, and for a
# borrowed kind the sibling's enums module (rocSOLVER's rocblas_operation) or the
# HIP runtime's (hipDataType). The HIP runtime defines its enums itself.
function hipfort_scope_uses(f::FuncInfo, meta::LibMeta) :: Vector{String}
  mb = meta.modbase
  uses = String[]
  meta.has_enums && push!(uses, "$(mb)_enums")
  (meta.has_types && refs_derived_type(f)) && push!(uses, "$(mb)_types")
  mb == "hipfort" && return uses
  mods = String[]
  scan(ft) = for m in eachmatch(r"kind\((\w+)\)", ft)
    c = m.captures[1]
    c in meta.own_consts && continue
    push!(mods, get(meta.sibling_enum_mod, c, "hipfort_enums"))
  end
  for a in f.args; scan(a.ftype); end
  f.is_void || scan(f.ret_ftype)
  return vcat(uses, unique(mods))
end

# On the NVIDIA backend a HIP routine may map to the CUDA driver API (cu[A-Z]...,
# libcuda) rather than the runtime. Under USE_CUDA_NAMES such a routine has no
# _typed or _devptr form, but keeps its _opt form: its generic needs it to mean
# the same as on ROCm. hipfort's CMake package links libcuda (CUDA::cuda_driver).
maps_to_cuda_driver(f::FuncInfo, meta::LibMeta) =
  (cu = get(meta.cuda_names, f.name, nothing); cu !== nothing && occursin(r"^cu[A-Z]", cu))

# A routine of a HIP library with no CUDA counterpart: compiled for ROCm only.
hip_only(f::FuncInfo, meta::LibMeta) =
  !isempty(meta.cuda_names) && !haskey(meta.cuda_names, f.name)

# Empty the per-library collectors above (BIND_NAMES, RECORD_ALIASES,
# UNMAPPED_CPTR, DOCS) and FUNC_DOCS (doc_check.jl). run_library_generator calls
# it before each library, so that
# several libraries generated in one process (as the tests do) never see each
# other's names; generate_all.jl runs each library in a process of its own anyway.
function reset_generator_state!()
  BIND_NAMES[] = Dict{String,String}()
  RECORD_ALIASES[] = Dict{String,String}()
  reset_unmapped_cptr!()
  DOCS[] = Dict{String,String}()   # the hipfort layout's docstrings
  reset_func_docs!()
  return nothing
end
