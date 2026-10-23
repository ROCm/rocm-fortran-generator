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

# Dummy names renamed to hipfort's "my<Name>" form. Required for `kind` (shadows
# the kind() intrinsic used in enum types) and `type`; the rest match hipfort's
# hand-written dummy names.
const DUMMY_RENAMES = Dict{String,String}(
  "info"     => "myInfo",   "kind"   => "myKind",   "result"    => "myResult",
  "type"     => "myType",   "direct" => "myDirect", "size"      => "mySize",
  "value"    => "myValue",  "data"   => "myData",   "precision" => "myPrecision",
  "module"   => "myModule", "format" => "myFormat", "stop"      => "myStop",
  "function" => "myFunction",
)
# Other Fortran statement keywords that would be invalid dummy names: suffixed "_".
const KEYWORD_DUMMIES = Set([
  "subroutine", "procedure", "program", "interface",
  "block", "contains", "common", "equivalence", "namelist", "submodule",
])
# A Fortran identifier must start with a letter, but C names may lead with an
# underscore (hipDevResource's `_internal_padding`): strip them, prefix "x" if
# nothing usable is left.
function safe_ident(n::AbstractString)
  s = lstrip(String(n), '_')
  (isempty(s) || !isletter(first(s))) && (s = "x" * s)
  return s
end

function safe_argname(n::AbstractString)
  ln = lowercase(n)
  haskey(DUMMY_RENAMES, ln) && return DUMMY_RENAMES[ln]
  ln in KEYWORD_DUMMIES     && return n * "_"
  return safe_ident(n)
end

# Workspace arguments (e.g. double* work) are raw device scratch buffers that
# callers pass as type(c_ptr), as in hipfort; keeping them c_ptr lets a call mixing
# native data arrays with a c_ptr workspace still resolve.
is_workspace_name(n::AbstractString) =
  occursin(r"^(d_?)?(work|workspace|buffer|pbuffer|externalbuffer|temp_?buffer|scratch)$"i, n)

function make_arg_info(cursor, t, idx::Int = 0)
  aname = let s = Clang.spelling(cursor); safe_argname(isempty(s) ? "arg$(idx)" : s) end
  is_str = is_string_arg(t)

  ftype, by_value = cltype_to_fortran(t)
  # An enum, or a pointer to one (descriptor getters' out-parameters), becomes
  # integer(kind(<first enumerator>)) rather than integer(c_int). An enum is never
  # an array in these APIs, so the pointer case cannot mistype a data buffer.
  ec = enum_first_const(by_value ? t : Clang.getPointeeType(t))
  ec !== nothing && (ftype = "integer(kind($(ec)))")

  suffix = if ftype == "void" || by_value
    ", value"
  elseif startswith(ftype, "type(")
    ""     # pointer-to-pointer or handle slot: scalar, by reference
  else
    "(*)"  # pointer to data: assumed-size array
  end

  if suffix == "(*)" && is_workspace_name(aname)
    ftype  = "type(c_ptr)"
    suffix = ", value"
  end

  ArgInfo(aname, ftype, suffix, is_str)
end

# First enumerator of an enum type, or nothing if `t` is not (and does not
# canonicalize to) an enum. Enums are typed as `integer(kind(<const>))`.
function enum_first_const(t)
  k = Clang.kind(t)
  et = if k == Clang.CXType_Enum
         t
       elseif k == Clang.CXType_Elaborated && Clang.kind(Clang.getCanonicalType(t)) == Clang.CXType_Enum
         Clang.getCanonicalType(t)
       else
         nothing
       end
  et === nothing && return nothing
  decl = Clang.CLCursor(Clang.LibClang.clang_getTypeDeclaration(et.type))
  for c in Clang.children(decl)
    Clang.kind(c) == Clang.CXCursor_EnumConstantDecl && return Clang.spelling(c)
  end
  return nothing
end
enum_ret_kind(t) = (c = enum_first_const(t); c === nothing ? nothing : "integer(kind($(c)))")

# A struct returned BY VALUE must bind to that derived type, not type(c_ptr),
# whose result ABI differs. Complex records are left to cltype_to_fortran.
# Returns "type(<name>)" or nothing.
function record_ret_ftype(t)
  Clang.kind(Clang.getCanonicalType(t)) == Clang.CXType_Record || return nothing
  complex_kind(Clang.spelling(t)) === nothing || return nothing
  return "type($(clean_type_name(Clang.spelling(t))))"
end

# True for an array of pointers written with an explicit `*`: `T* X[]` or
# `T* const* X` (rocBLAS spells the same batched argument both ways). A plain `T**`
# is an output (hipMalloc's pointer, a created handle), and an array of a pointer
# typedef (`const hipGraphNode_t* deps`) is an array of handles on the host: both
# stay by reference.
function is_ptr_array(t) :: Bool
  k = Clang.kind(t)
  k in (Clang.CXType_IncompleteArray, Clang.CXType_ConstantArray) &&
    return Clang.kind(Clang.getElementType(t)) == Clang.CXType_Pointer
  k == Clang.CXType_Pointer || return false
  pt = Clang.getPointeeType(t)
  return Clang.kind(pt) == Clang.CXType_Pointer && Clang.LibClang.clang_isConstQualifiedType(pt.type) != 0
end

function collect_funcs(root, prefix::String) :: Vector{FuncInfo}
  reset_unmapped_cptr!()
  funcs = FuncInfo[]
  seen  = Set{String}()
  skipped_variadic = String[]
  # Also match the bare prefix itself (prefix minus its trailing "_").
  bare = endswith(prefix, "_") ? prefix[1:prevind(prefix, lastindex(prefix))] : prefix
  for child in Clang.children(root)
    Clang.kind(child) == Clang.CXCursor_FunctionDecl || continue
    name = Clang.spelling(child)
    (startswith(name, prefix) || name == bare) || continue
    # `static inline` has no exported symbol: binding it is a link error.
    Clang.LibClang.clang_Cursor_isFunctionInlined(child.cursor) != 0 && continue
    # Skip (and log) variadic functions: Fortran cannot declare `...`, and calling
    # a variadic callee through a fixed-arity prototype is undefined (x86-64 SysV
    # leaves AL unset). The FunctionProto guard is required because
    # clang_isFunctionTypeVariadic is also true for K&R `f()` (FunctionNoProto),
    # e.g. hipProfilerStart().
    let ct = Clang.getCursorType(child)
      if Clang.kind(ct) == Clang.CXType_FunctionProto &&
         Clang.LibClang.clang_isFunctionTypeVariadic(ct.type) != 0
        push!(skipped_variadic, name)
        continue
      end
    end
    name ∈ seen && continue
    push!(seen, name)

    ret_ct  = Clang.getCursorResultType(child)
    is_void = Clang.kind(ret_ct) == Clang.CXType_Void
    # Every pointer return is type(c_ptr), `const char*` included
    # (cltype_to_fortran would give the pointee type).
    ret_ft  = is_void ? "void" :
              Clang.kind(ret_ct) == Clang.CXType_Pointer ? "type(c_ptr)" :
              something(enum_ret_kind(ret_ct), record_ret_ftype(ret_ct),
                        first(cltype_to_fortran(ret_ct)))

    clang_args  = Clang.get_function_args(child)
    clang_types = [Clang.getCursorType(a) for a in clang_args]
    args = [make_arg_info(clang_args[i], clang_types[i], i) for i in eachindex(clang_args)]
    # An array of pointers (the batched routines' A, B, C) is passed by value: the
    # caller passes a c_ptr to the array, in device or host memory. The metadata's
    # `ref` keeps one by reference (rocfft_execute, whose callers pass one buffer).
    for i in eachindex(args)
      is_ptr_array(clang_types[i]) &&
        (args[i] = ArgInfo(args[i].name, "type(c_ptr)", ", value", args[i].is_string))
    end
    # Disambiguate any duplicate dummy names (some headers repeat or omit names).
    # Fortran names ignore case, so N and n are duplicates too.
    taken = Set{String}()
    for (i, a) in enumerate(args)
      n = a.name
      lowercase(n) in taken && (n = "$(a.name)_$(i)")
      push!(taken, lowercase(n))
      n == a.name || (args[i] = ArgInfo(n, a.ftype, a.suffix, a.is_string))
    end

    push!(funcs, FuncInfo(name, ret_ft, is_void, args))
  end
  isempty(skipped_variadic) ||
    @info "  skipped $(length(skipped_variadic)) variadic function(s) (no portable Fortran interface):" sort!(unique(skipped_variadic))
  return funcs
end

# Absolute path of the header a cursor was declared in ("" if unknown).
function cursor_file(c) :: String
  loc     = Clang.LibClang.clang_getCursorLocation(c.cursor)
  fileref = Ref{Clang.LibClang.CXFile}(C_NULL)
  line = Ref{Cuint}(0); col = Ref{Cuint}(0); off = Ref{Cuint}(0)
  Clang.LibClang.clang_getFileLocation(loc, fileref, line, col, off)
  fileref[] == C_NULL && return ""
  cxstr = Clang.LibClang.clang_getFileName(fileref[])
  s = unsafe_string(Clang.LibClang.clang_getCString(cxstr))
  Clang.LibClang.clang_disposeString(cxstr)
  return s
end

# Fallback filter without an owner list: ROCm headers (/opt/rocm or
# rocm-libraries), not system headers reached transitively.
function is_project_header(f::String) :: Bool
  isempty(f) && return false
  return occursin("rocm", lowercase(f))
end

# Keep a declaration only if it comes from one of this library's own headers: an
# owner marker as a directory (`/rocsparse/…`) or file-name prefix
# (`/rocsparse-types.h`). The trailing separator keeps "hip" from matching
# "hipblas". The marker alone excludes system headers, so it also works for
# /usr/include/<lib>/ installs, and it keeps a math library from re-emitting the
# HIP runtime enums it includes.
function owns_decl(f::String, own::Vector{String}) :: Bool
  isempty(f) && return false
  isempty(own) && return is_project_header(f)
  for m in own, sep in ('/', '.', '-', '_')
    occursin("/" * m * sep, f) && return true
  end
  return false
end

# Enumerators are de-duplicated across all enums, case-insensitively (Fortran
# names are case-insensitive and a module scope is flat); first occurrence wins.
function collect_enums(root; own::Vector{String} = String[]) :: Vector{EnumInfo}
  enums = EnumInfo[]
  seen  = Set{String}()
  for c in Clang.children(root)
    Clang.kind(c) == Clang.CXCursor_EnumDecl || continue
    owns_decl(cursor_file(c), own) || continue
    consts = Pair{String,Int64}[]
    for ec in Clang.children(c)
      Clang.kind(ec) == Clang.CXCursor_EnumConstantDecl || continue
      nm = Clang.spelling(ec)
      isempty(nm) && continue
      key = lowercase(nm)
      key ∈ seen && continue
      push!(seen, key)
      val = Clang.LibClang.clang_getEnumConstantDeclValue(ec.cursor)
      push!(consts, nm => Int64(val))
    end
    isempty(consts) && continue
    push!(enums, EnumInfo(stable_enum_name(Clang.spelling(c)), consts))
  end
  return enums
end

# libclang spells an anonymous enum "enum (unnamed at /abs/path/hip/x.h:37:1)";
# keep the path from its last `include/` on (or the file name) so the emitted
# comment does not depend on the include root.
function stable_enum_name(s::AbstractString) :: String
  m = match(r"^(.*\((?:unnamed|anonymous)(?: enum)? at )(.+?)(:\d+:\d+\).*)$", s)
  m === nothing && return String(s)
  path = m.captures[2]
  i = findlast("/include/", path)
  rel = i === nothing ? basename(path) : path[last(i)+1:end]
  return m.captures[1] * rel * m.captures[3]
end

# Macros are visible as CXCursor_MacroDefinition cursors because Clang.jl parses
# with CXTranslationUnit_DetailedPreprocessingRecord.

# True when `items` is ONE parenthesised group: `(1<<3)|(1<<5)` starts and ends
# with parens but is two groups.
function one_paren_group(items, lp, rp) :: Bool
  depth = 0
  for (i, c) in enumerate(items)
    c == lp && (depth += 1)
    c == rp && (depth -= 1)
    (depth == 0 && i < length(items)) && return false
  end
  return depth == 0
end

# Parse a macro body (tokens after the name) as a 64-bit integer, or nothing.
function macro_int_value(toks::Vector{String})
  length(toks) < 2 && return nothing
  body = toks[2:end]
  while length(body) >= 2 && one_paren_group(body, "(", ")")
    body = body[2:end-1]
  end
  isempty(body) && return nothing
  s = join(body, "")
  # Strip a leading integer cast: `((int)-1)` -> `-1`.
  s = replace(s, r"^\((?:signed|unsigned)?\s*(?:int|long|short|char)\)" => "")
  while length(s) >= 2 && one_paren_group(s, '(', ')')
    s = s[2:end-1]
  end

  lit(x) = begin
    m = match(r"^([+-]?)(0[xX][0-9a-fA-F]+|\d+)[uUlL]*$", x)
    m === nothing && return nothing
    try
      d = m[2]
      v = startswith(lowercase(d), "0x") ? parse(Int64, d[3:end]; base=16) :
          length(d) > 1 && startswith(d, "0") ? parse(Int64, d; base=8) :   # C octal: 010 is 8
          parse(Int64, d)
      return m[1] == "-" ? -v : v
    catch
      return nothing   # out of Int64 range
    end
  end

  v = lit(s)
  v === nothing || return v

  # Bit flags: `1U << 6`, `(1<<3)|(1<<5)`.
  shifted(x) = begin
    while length(x) >= 2 && one_paren_group(x, '(', ')')
      x = strip(x[2:end-1])
    end
    p = split(x, "<<")
    length(p) == 1 && return lit(strip(x))
    length(p) == 2 || return nothing
    a, b = lit(strip(p[1])), lit(strip(p[2]))
    (a === nothing || b === nothing || b < 0 || b > 62) ? nothing : a << b
  end
  acc = Int64(0)
  for part in split(s, "|")
    pv = shifted(strip(part))
    pv === nothing && return nothing
    acc |= pv
  end
  return acc
end

# name => value for object-like integer macros, skipping reserved "__" names,
# de-duplicated case-insensitively.
function collect_macros(root; own::Vector{String} = String[]) :: Vector{Pair{String,Int64}}
  out  = Pair{String,Int64}[]
  seen = Set{String}()
  for c in Clang.children(root)
    Clang.kind(c) == Clang.CXCursor_MacroDefinition || continue
    owns_decl(cursor_file(c), own) || continue
    Clang.LibClang.clang_Cursor_isMacroFunctionLike(c.cursor) != 0 && continue
    nm = Clang.spelling(c)
    (isempty(nm) || startswith(nm, "__")) && continue
    # Include guards defined with a value (`#define ROCTX_H_ 1`).
    occursin(r"^[A-Z][A-Z0-9_]*_(H|HPP)_*$", nm) && continue
    key = lowercase(nm)
    key ∈ seen && continue
    toks = String[t.text for t in Clang.tokenize(c)]
    val = macro_int_value(toks)
    val === nothing && continue
    push!(seen, key)
    push!(out, nm => val)
  end
  return out
end

# Object-like identifier aliases `#define SHORT LONG`, used for ABI-versioned
# symbols (`#define hipDeviceProp_t hipDeviceProp_tR0600`). Returns LONG => SHORT.
function collect_define_aliases(root; own::Vector{String} = String[]) :: Dict{String,String}
  out = Dict{String,String}()
  for c in Clang.children(root)
    Clang.kind(c) == Clang.CXCursor_MacroDefinition || continue
    owns_decl(cursor_file(c), own) || continue
    Clang.LibClang.clang_Cursor_isMacroFunctionLike(c.cursor) != 0 && continue
    short = Clang.spelling(c)
    (isempty(short) || startswith(short, "__")) && continue
    toks = String[t.text for t in Clang.tokenize(c)]
    length(toks) == 2 || continue
    target = toks[2]
    occursin(r"^[A-Za-z_][A-Za-z0-9_]*$", target) || continue
    target == short && continue
    out[target] = short
  end
  return out
end

# Function-like macros that forward verbatim to another function,
# `#define roctxMark(message) roctxMarkA(message)`: the macro is the documented
# name, the expansion the ABI symbol. Returns LONG => SHORT. Only exact
# pass-throughs (same parameters, same order, no extra tokens) qualify.
function collect_forwarding_macros(root; own::Vector{String} = String[]) :: Dict{String,String}
  out = Dict{String,String}()
  ident = r"^[A-Za-z_][A-Za-z0-9_]*$"
  for c in Clang.children(root)
    Clang.kind(c) == Clang.CXCursor_MacroDefinition || continue
    owns_decl(cursor_file(c), own) || continue
    Clang.LibClang.clang_Cursor_isMacroFunctionLike(c.cursor) == 0 && continue
    short = Clang.spelling(c)
    (isempty(short) || startswith(short, "__")) && continue
    toks = String[t.text for t in Clang.tokenize(c)]
    # name ( p1 , … , pN ) target ( p1 , … , pN )
    (length(toks) >= 5 && toks[1] == short && toks[2] == "(") || continue
    close = findfirst(==(")"), toks)
    close === nothing && continue
    params = toks[3:close-1]
    args = filter(!=(","), params)
    (length(args) == cld(length(params), 2) && all(a -> occursin(ident, a), args)) || continue
    body = toks[close+1:end]
    (length(body) >= 3 && occursin(ident, body[1]) && body[1] != short) || continue
    body == vcat([body[1], "("], params, [")"]) || continue
    out[body[1]] = short
  end
  return out
end

# `static inline` functions that only forward to another function with the same
# parameters, `static inline hipError_t hipChooseDevice(int* device, ...)
# { return hipChooseDeviceR0600(device, ...); }`: the newer HIP headers spell their
# versioned names this way instead of with a #define. The inline function has no
# symbol, so it becomes an alias of its target. Returns LONG => SHORT.
function collect_inline_forwarders(root; own::Vector{String} = String[]) :: Dict{String,String}
  out = Dict{String,String}()
  sources = Dict{String,String}()
  for c in Clang.children(root)
    Clang.kind(c) == Clang.CXCursor_FunctionDecl || continue
    Clang.LibClang.clang_Cursor_isFunctionInlined(c.cursor) == 0 && continue
    file = cursor_file(c)
    (isempty(file) || !owns_decl(file, own)) && continue
    short  = Clang.spelling(c)
    params = String[Clang.spelling(p) for p in Clang.children(c)
                    if Clang.kind(p) == Clang.CXCursor_ParmDecl]
    # Function bodies are not parsed, so read the body from the source, right
    # after the declaration's extent.
    stop = Clang.LibClang.clang_getRangeEnd(Clang.LibClang.clang_getCursorExtent(c.cursor))
    fileref = Ref{Clang.LibClang.CXFile}(C_NULL)
    line = Ref{Cuint}(0); col = Ref{Cuint}(0); off = Ref{Cuint}(0)
    Clang.LibClang.clang_getFileLocation(stop, fileref, line, col, off)
    src = get!(() -> read(file, String), sources, file)
    m = match(r"^\s*\{\s*(?:return\s+)?([A-Za-z_]\w*)\s*\(([^()]*)\)\s*;\s*\}",
              SubString(src, Int(off[]) + 1))
    m === nothing && continue
    target, args = m.captures
    target == short && continue
    passed = String[strip(a) for a in split(args, ',') if !isempty(strip(a))]
    passed == params || continue
    out[target] = short
  end
  return out
end

# The names a header documents for an ABI symbol: `#define` aliases and inline
# forwarders. Returns LONG => SHORT.
collect_name_aliases(root; own::Vector{String} = String[]) =
  merge(collect_define_aliases(root; own=own), collect_inline_forwarders(root; own=own))

# One opaque member of `sz` bytes whose element kind matches the C alignment `al`,
# so later field offsets of an enclosing bind(C) struct stay correct.
function opaque_blob_field(sz::Integer, al::Integer;
                           name::AbstractString = "opaque", doc::AbstractString = "") :: FieldInfo
  el, esz = al >= 8 ? ("integer(c_int64_t)", 8) :
            al >= 4 ? ("integer(c_int32_t)", 4) :
            al >= 2 ? ("integer(c_int16_t)", 2) :
                      ("integer(c_int8_t)",  1)
  return FieldInfo(name, el, "($(cld(sz, esz)))", doc)
end

# (size, alignment) of a Clang type; 0 when the layout is incomplete or erroneous.
function type_layout(t) :: Tuple{Int,Int}
  sz = Int(Clang.LibClang.clang_Type_getSizeOf(t.type))
  al = Int(Clang.LibClang.clang_Type_getAlignOf(t.type))
  return (sz > 0 ? sz : 0, al > 0 ? al : 0)
end

# The record declaration a type resolves to, or nothing when it isn't a record.
function record_decl(t)
  ct = Clang.getCanonicalType(t)
  Clang.kind(ct) == Clang.CXType_Record || return nothing
  return Clang.CLCursor(Clang.LibClang.clang_getTypeDeclaration(ct.type))
end

is_union_cursor(cur) = Clang.kind(cur) == Clang.CXCursor_UnionDecl
is_anon_cursor(cur)  = Clang.LibClang.clang_Cursor_isAnonymous(cur.cursor) != 0

# Map a C union to ONE Fortran field (Fortran has no unions): a single named field
# when every member maps to the same type (a back-compat rename, as in
# hipMemAllocationProp), otherwise an opaque blob of the union's size and
# alignment. It must never be dropped: that would shift every following field.
function union_field(decl, t, fallback_name::AbstractString) :: FieldInfo
  members = [fc for fc in Clang.children(decl) if Clang.kind(fc) == Clang.CXCursor_FieldDecl]
  sz, al  = type_layout(t)
  mapped  = Tuple{String,String,Bool}[]
  for fc in members
    ft, dims, ok, dep = map_field_type(Clang.getCursorType(fc))
    push!(mapped, (ft, dims, ok && dep === nothing))
  end
  if !isempty(mapped) && all(m -> m[3], mapped) && allequal(mapped)
    ft, dims, _ = mapped[1]
    names = [Clang.spelling(fc) for fc in members]
    doc   = length(names) > 1 ? "C union; also spelled " * join(names[2:end], ", ") : ""
    return FieldInfo(safe_ident(names[1]), ft, dims, doc)
  end
  return opaque_blob_field(sz, al; name = fallback_name,
                           doc = "$(sz)-byte C union: keeps the layout exact, members not individually accessible")
end

# Map a struct field type to (ftype, dims, ok, dep): ok = false when the field
# (hence the struct) is not bind(C)-representable; dep = embedded struct tag or
# nothing.
function map_field_type(t)
  k = Clang.kind(t)

  # A flexible array member (`double v[]`) has no Fortran equivalent, and mapping
  # it to its element type would make the derived type longer than the C struct:
  # the struct becomes an opaque blob instead.
  k == Clang.CXType_IncompleteArray && return ("", "", false, nothing)

  if k == Clang.CXType_ConstantArray
    dims = Int[]
    el   = t
    while Clang.kind(el) == Clang.CXType_ConstantArray
      push!(dims, Int(Clang.LibClang.clang_getArraySize(el)))
      el = Clang.getElementType(el)
    end
    ft, _, ok, dep = map_field_type(el)
    ok || return (ft, "", false, dep)
    # C is row-major, Fortran column-major: reverse the extents.
    return (ft, "(" * join(reverse(dims), ",") * ")", true, dep)
  end

  if k == Clang.CXType_Pointer
    pt = Clang.getPointeeType(t)
    Clang.kind(pt) == Clang.CXType_FunctionProto && return ("type(c_funptr)", "", true, nothing)
    if Clang.kind(pt) == Clang.CXType_Elaborated &&
       Clang.kind(Clang.getCanonicalType(pt)) == Clang.CXType_FunctionProto
      return ("type(c_funptr)", "", true, nothing)
    end
    return ("type(c_ptr)", "", true, nothing)
  end

  if k in (Clang.CXType_Elaborated, Clang.CXType_Record, Clang.CXType_Typedef)
    ct = Clang.getCanonicalType(t)
    ck = Clang.kind(ct)
    if ck == Clang.CXType_Record
      decl = Clang.LibClang.clang_getTypeDeclaration(ct.type)
      Clang.LibClang.clang_getCursorKind(decl) == Clang.CXCursor_UnionDecl &&
        return ("", "", false, nothing)
      nm = Clang.spelling(Clang.CLCursor(decl))
      isempty(nm) && return ("", "", false, nothing)
      occursin(" ", nm) && return ("", "", false, nothing)  # "struct (unnamed at ...)"
      return ("type($nm)", "", true, nm)
    end
    # A pointer field (incl. via a typedef like hipArray_t) is type(c_ptr):
    # cltype_to_fortran's type(<name>) for record pointers is only right for arguments.
    if ck == Clang.CXType_Pointer
      Clang.kind(Clang.getPointeeType(ct)) == Clang.CXType_FunctionProto &&
        return ("type(c_funptr)", "", true, nothing)
      return ("type(c_ptr)", "", true, nothing)
    end
    # Pass the non-canonical type so width-exact typedefs (size_t, int64_t) are
    # honoured before canonicalizing to `long` (32-bit on Windows).
    ft, _ = cltype_to_fortran(t)
    return (ft, "", true, nothing)
  end

  ft, _ = cltype_to_fortran(t)
  return (ft, "", true, nothing)
end

# tag name => preferred typedef name, shortest wins, so `hipDeviceProp_tR0600`
# surfaces as `hipDeviceProp_t`. A tag that is its own typedef competes like any
# other: neither skipped (hipDeviceProp_t) nor forced (hipFFTW's fftw_iodim).
function collect_typedef_aliases(root, own::Vector{String}) :: Dict{String,String}
  aliases = Dict{String,String}()
  for (tname, tag) in record_typedefs(root, own)
    if !haskey(aliases, tag) || length(tname) < length(aliases[tag])
      aliases[tag] = tname
    end
  end
  return aliases
end

# Every typedef of a record in the owned headers, as (typedef name, struct tag)
# pairs in declaration order.
function record_typedefs(root, own::Vector{String}) :: Vector{Pair{String,String}}
  out = Pair{String,String}[]
  for c in Clang.children(root)
    Clang.kind(c) == Clang.CXCursor_TypedefDecl || continue
    owns_decl(cursor_file(c), own) || continue
    tname = Clang.spelling(c)
    isempty(tname) && continue
    ct = Clang.getCanonicalType(Clang.getCursorType(c))
    Clang.kind(ct) == Clang.CXType_Record || continue
    decl = Clang.LibClang.clang_getTypeDeclaration(ct.type)
    tag  = Clang.spelling(Clang.CLCursor(decl))
    isempty(tag) && continue
    push!(out, tname => tag)
  end
  return out
end

# Owned structs as bind(C) derived types (opaque blobs when not field-mappable),
# topologically sorted so embedded types come first.
function collect_structs(root; skip::Vector{String} = String[],
                         own::Vector{String} = String[],
                         keep::Vector{String} = String[]) :: Vector{StructInfo}
  aliases = collect_typedef_aliases(root, own)
  # A #define alias of a versioned tag takes precedence.
  for (tag, short) in collect_define_aliases(root; own=own)
    aliases[tag] = short
  end
  emitname(tag) = get(aliases, tag, tag)
  RECORD_ALIASES[] = Dict{String,String}(t => emitname(tag) for (t, tag) in record_typedefs(root, own))
  skipset  = Set(lowercase.(skip))
  keepset  = Set(lowercase.(keep))   # vector types this library needs emitted anyway

  raw      = StructInfo[]
  seen     = Set{String}()
  for c in Clang.children(root)
    Clang.kind(c) == Clang.CXCursor_StructDecl || continue
    # A forward declaration (`struct S;`) has no fields: wait for the definition,
    # or the struct would become an opaque blob and the definition be skipped.
    Clang.LibClang.clang_isCursorDefinition(c.cursor) == 0 && continue
    owns_decl(cursor_file(c), own) || continue
    tag = Clang.spelling(c)
    isempty(tag) && continue
    name = emitname(tag)
    (lowercase(name) ∈ seen || lowercase(name) ∈ skipset) && continue
    # Skip HIP vector types (int4, double2, ...): hipfort does not expose them and
    # user code defines its own. A library passing one BY VALUE (rocRAND's uint4)
    # must emit it and opts in via keep_structs.
    (occursin(r"^(?:u?char|u?short|u?int|u?long|u?longlong|float|double)[1234]$"i, name) &&
     !(lowercase(name) ∈ keepset)) && continue
    # Names like `__half2` are not Fortran identifiers; users keep type(c_ptr).
    occursin(r"^[A-Za-z]", name) || continue

    fields = FieldInfo[]
    deps   = String[]
    ok     = true
    nanon  = 0
    # Nested records named by a FieldDecl (`struct {…} allocFlags;`). Any other
    # anonymous nested record is an inline member with no FieldDecl of its own.
    named_nested = Set{UInt}()
    for fc in Clang.children(c)
      Clang.kind(fc) == Clang.CXCursor_FieldDecl || continue
      d = record_decl(Clang.getCursorType(fc))
      d === nothing || push!(named_nested, hash(Clang.spelling(d)))
    end

    for fc in Clang.children(c)
      # Inline anonymous union (`union { … };`), numbered to keep names distinct.
      if is_union_cursor(fc) && is_anon_cursor(fc) && !(hash(Clang.spelling(fc)) in named_nested)
        nanon += 1
        nm = nanon == 1 ? "anonymous_union" : "anonymous_union$(nanon)"
        push!(fields, union_field(fc, Clang.getCursorType(fc), nm))
        continue
      end
      # Inline anonymous struct: its fields cannot be named without inventing API,
      # so the enclosing struct becomes opaque.
      if Clang.kind(fc) == Clang.CXCursor_StructDecl && is_anon_cursor(fc) &&
         !(hash(Clang.spelling(fc)) in named_nested)
        ok = false; break
      end
      Clang.kind(fc) == Clang.CXCursor_FieldDecl || continue
      if Clang.LibClang.clang_Cursor_isBitField(fc.cursor) != 0
        ok = false; break
      end
      fct  = Clang.getCursorType(fc)
      fdec = record_decl(fct)
      if fdec !== nothing && is_union_cursor(fdec)
        push!(fields, union_field(fdec, fct, safe_ident(Clang.spelling(fc))))
        continue
      end
      # A field of anonymous struct type (`struct {…} allocFlags;`) has no type
      # name to emit: keep it as an opaque blob.
      if fdec !== nothing && is_anon_cursor(fdec)
        sz, al = type_layout(fct)
        if sz > 0
          push!(fields, opaque_blob_field(sz, al; name = safe_ident(Clang.spelling(fc)),
                doc = "$(sz)-byte unnamed C struct: keeps the layout exact, fields not individually accessible"))
          continue
        end
        ok = false; break
      end
      ft, dims, fok, dep = map_field_type(fct)
      if !fok
        ok = false; break
      end
      if dep !== nothing
        # map_field_type names the tag; use the name the struct is emitted under.
        ft  = "type($(emitname(dep)))"
        dep = emitname(dep)
        push!(deps, dep)
      end
      push!(fields, FieldInfo(safe_ident(Clang.spelling(fc)), ft, dims, ""))
    end

    if ok && !isempty(fields)
      push!(raw, StructInfo(name, fields, unique(deps)))
    else
      # Not field-mappable (bit-fields, anonymous member): emit an opaque blob
      # rather than drop it and every struct embedding it (hipDeviceArch_t).
      sz, al = type_layout(Clang.getCursorType(c))
      sz > 0 || continue
      push!(raw, StructInfo(name, [opaque_blob_field(sz, al)], String[]))
    end

    push!(seen, lowercase(name))
  end

  # Cascade-drop structs whose embedded types were themselves dropped.
  changed = true
  while changed
    changed = false
    kept = StructInfo[]
    names = Set(s.name for s in raw)
    for s in raw
      if all(d -> d == s.name || d ∈ names, s.deps)
        push!(kept, s)
      else
        changed = true
      end
    end
    raw = kept
  end

  byname  = Dict(s.name => s for s in raw)
  ordered = StructInfo[]
  placed  = Set{String}()
  function visit(s, stack)
    s.name ∈ placed && return
    s.name ∈ stack  && return
    push!(stack, s.name)
    for d in s.deps
      d != s.name && haskey(byname, d) && visit(byname[d], stack)
    end
    push!(ordered, s); push!(placed, s.name)
  end
  for s in raw; visit(s, Set{String}()); end
  return ordered
end

