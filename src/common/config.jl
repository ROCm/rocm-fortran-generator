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
# re-read rocblas.mod thousands of times.
function sibling_module_uses(funcs::Vector{FuncInfo}, libname::String, meta::LibMeta;
                             extra::Vector{String} = String[]) :: Vector{String}
  isempty(meta.sibling_enum_mod) && return String[]
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
  return [ "$(mod), only: " * join(sort(collect(names)), ", ")
           for (mod, names) in sort(collect(bymod); by = first) ]
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

# Empty the per-library collectors above (BIND_NAMES, RECORD_ALIASES,
# UNMAPPED_CPTR) and FUNC_DOCS (doc_check.jl). run_library_generator calls it before each library, so that
# several libraries generated in one process (as the tests do) never see each
# other's names; generate_all.jl runs each library in a process of its own anyway.
function reset_generator_state!()
  BIND_NAMES[] = Dict{String,String}()
  RECORD_ALIASES[] = Dict{String,String}()
  reset_unmapped_cptr!()
  reset_func_docs!()
  return nothing
end
