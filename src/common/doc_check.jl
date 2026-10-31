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

# A cross-check of the metadata against the doxygen comments of the C headers:
# where an argument's @param description clearly says what it is (one value on
# the host, on the device, in either as the pointer mode says, or an array), and
# the binding takes it otherwise, gen_files warns. It never changes a binding nor
# stops the generation: the docs are prose, and the metadata has the last word.

"""
Per function name, its documented arguments: C argument name => description, as
collect_funcs found them (FUNC_DOCS[]["rocblas_sdot"]["result"]). Global like
UNMAPPED_CPTR: a diagnostics collector filled by the frontend and read only by
gen_files, which keeps FuncInfo, built in many places, free of prose. Reset per
collect_funcs call.
"""
const FUNC_DOCS = Ref(Dict{String,Dict{String,String}}())
reset_func_docs!() = (FUNC_DOCS[] = Dict{String,Dict{String,String}}(); nothing)

# Doxygen commands that open a new block, so end a @param description; inline ones
# (\p, \f$, \ref, \c, \b) and LaTeX in formulas (\alpha, \text) do not.
const DOC_BLOCK_CMD = r"[@\\](?:param|tparam|retval|returns?|result|notes?|details?|brief|short|code|endcode|warning|see|sa|par|section|subsection|ingroup|defgroup|addtogroup|deprecated|remarks?|verbatim|endverbatim|pre|post|since|throws?|exception|bug|todo|attention|example|snippet|include|image|copydoc|internal|endinternal)\b|@[{}]"
const DOC_PARAM = r"[@\\]param\s*(?:\[\s*(?:in|out)(?:\s*,\s*(?:in|out))?\s*\])?\s+([A-Za-z_]\w*)"

# The comment text without its decoration (/**, /*!, ///, leading *, */).
function doc_text(raw::AbstractString)
  lines = map(split(raw, '\n')) do l
    l = strip(l)
    l = replace(l, r"\*+/$" => "")
    l = replace(l, r"^(/\*+[!<]?|//[/!<]?)" => "")
    l = replace(l, r"^\*+" => "")
    strip(l)
  end
  return join(lines, '\n')
end

"""
    doc_params(raw) -> Vector{Pair{String,String}}

The `@param[in|out|in,out] name description` entries of a raw doc comment, in
order, the description with its whitespace collapsed. A description runs until the
next block command (`@param`, `\\retval`, `\\note`, ...) or a blank line; the name
may be on the line after `@param[in]` (hipSPARSE, rocBLAS).
"""
function doc_params(raw::AbstractString)
  txt = doc_text(raw)
  out = Pair{String,String}[]
  for m in eachmatch(DOC_PARAM, txt)
    from = m.offset + ncodeunits(m.match)
    rest = SubString(txt, from)
    stop = ncodeunits(rest) + 1
    for r in (DOC_BLOCK_CMD, r"\n\s*\n")
      x = findfirst(r, rest)
      x === nothing || (stop = min(stop, first(x)))
    end
    desc = strip(replace(rest[1:prevind(rest, stop)], r"\s+" => " "))
    push!(out, String(m.captures[1]) => String(desc))
  end
  return out
end

# What a @param description says the argument is, rule by rule; the first sentence
# that matches decides, and in a sentence the per-batch and array phrases first.
# Tightened against the headers' prose:
#  - "array" as a noun only: "array flags", "array type" name a HIP array;
#  - a vector or matrix "on the GPU" is a buffer, not a scalar on the device;
#  - "host or device" (in any phrasing) is the pointer mode, not the host.
const DOC_ARRAY = r"\barrays?\b(?!\s+(?!(?:of|on|in|to|for|with|containing|storing|holding|that|which|where|is|are|must|should|will|can|may|returned|allocated|used|pointers?|size|length|elements?)\b)[a-z]+\b)"i
const DOC_BATCH = r"\bbatch_?count\b"i
const DOC_RULES = (
  "buffer" => [DOC_ARRAY, DOC_BATCH, r"\bvectors\b"i, r"\w\[\s*\w+\s*\]", r"\beach\b"i,
               r"\b(vector|matrix|matrices)\b.*\b(on the GPU|in device memory)"i],
  "scalar-pointer-mode" => [r"device pointer or host pointer"i, r"\bhost or (the )?device\b"i,
                            r"\bdevice or (the )?host\b"i, r"specif(y|ies|ying) the scalar"i,
                            r"^scalar\b.*\\f\$"i],
  "scalar-device" => [r"on the GPU"i, r"in device memory"i],
  "scalar-host" => [r"on the host"i, r"number of bytes"i, r"size in bytes"i],
)
# A sentence that describes one number (the size of an array, the number of
# entries in arrays, a pointer to a count) mentions arrays it does not point to.
const DOC_COUNT = r"^(?:-\s*)?(?:returns?\s+)?(?:(?:a\s+)?pointer to\s+)?(?:the\s+)?(?:total\s+|actual\s+)?(?:size|number|count|length)\b"i

"""
    doc_classify(desc, name = "") -> (value, sentence) or nothing

The classification a @param description of argument `name` (its C spelling)
states, and the sentence that states it. The argument indexed anywhere in its own
description (`info[l]`) is one value per entry, a buffer, whatever an earlier
sentence said ("pointer to a rocblas_int on the GPU. If info[l] = 0, ...").
Per-batch phrases do not apply to the batch count itself, nor any buffer phrase
to a sentence that describes one number (DOC_COUNT).
"""
function doc_classify(desc::AbstractString, name::AbstractString = "")
  if !isempty(name)
    m = match(Regex("\\b" * name * "\\[\\s*\\w+\\s*\\]"), desc)
    m === nothing || return ("buffer", String(m.match))
  end
  for s in split(desc, r"(?<=\.)\s+")
    s = strip(s)
    isempty(s) && continue
    for (val, pats) in DOC_RULES
      if val == "buffer"
        occursin(DOC_COUNT, s) && continue
        is_batch_count(name) && (pats = filter(!=(DOC_BATCH), pats))
      end
      any(p -> occursin(p, s), pats) && return (val, String(s))
    end
  end
  return nothing
end

"""
    function_docs!(docs, name, raw, cnames, carried) -> carried

Record in `docs` the documented arguments of function `name`, whose C argument
names are `cnames`, from its own raw comment `raw` ("" if none). One doxygen
block often documents a group of declarations (the S, D, C, Z precisions, the _64
variants): a declaration without a @param of its own takes the last block seen,
`carried`, when that block names at least 60% of its arguments. Returns the block
to carry to the next declaration.
"""
function function_docs!(docs::Dict{String,Dict{String,String}}, name::AbstractString,
                        raw::AbstractString, cnames::Vector{String},
                        carried::Vector{Pair{String,String}})
  own = doc_params(raw)
  ps = if !isempty(own)
    carried = own
  elseif !isempty(cnames) && count(in(Set(first.(carried))), cnames) >= 0.6 * length(cnames)
    carried
  else
    Pair{String,String}[]
  end
  isempty(ps) || (docs[String(name)] = Dict{String,String}(ps))
  return carried
end

# The raw comment libclang attaches to a cursor, or "".
function raw_comment(cursor)
  s = Clang.LibClang.clang_Cursor_getRawCommentText(cursor.cursor)
  p = Clang.LibClang.clang_getCString(s)
  txt = p == C_NULL ? "" : unsafe_string(p)
  Clang.LibClang.clang_disposeString(s)
  return txt
end

# What the binding takes the typed pointer `arg` of `fn` for, after the signature
# defaults: a pointer the metadata does not call a scalar is a data buffer.
function effective_kind(md::Metadata, fn::AbstractString, arg::AbstractString)
  arg in meta_get(md.devonly, fn, EMPTY_STRSET) && return "scalar-device"
  arg in meta_get(md.ptrmode, fn, EMPTY_STRSET) && return "scalar-pointer-mode"
  arg in meta_get(md.scalar, fn, EMPTY_STRSET)  && return "scalar-host"
  return "buffer"
end

# Arguments whose doc comment is wrong, "function argument": the check skips them.
# Each is a header bug (to report upstream), not a choice of phrasing: keep this
# list to those, with the reason.
const DOC_ERRATA = Set([
  # "column indices ... Must be an array of length rows*ell_width", pasted from
  # ell_col_ind: ell_cols is the number of columns of the ELL part, one int64_t.
  "rocsparse_bell_get ell_cols", "rocsparse_const_bell_get ell_cols",
])

"""
    check_metadata_docs(funcs, md, docs = FUNC_DOCS[]) -> Vector{String}

Warn, once for the library, about every typed pointer argument (not a `void*`, not
a `T**`) whose doxygen description states a classification (doc_classify) other
than the one the binding has: the metadata's, the signature default's, or a data
buffer. Not reported: a doc that says "on the GPU" in a routine with a batch
count, which cannot have a `scalar-device` argument (check_batched_device_scalars),
and an argument in DOC_ERRATA. Run after apply_signature_defaults!. A function that
a table covers is reported under the table's key as written; the functions without
one that agree on an argument are reported under one brace key (brace_key), as a
table would name them. Returns the lines reported, one per line in the warning
(a list would be cut to the log's width).
"""
function check_metadata_docs(funcs::Vector{FuncInfo}, md::Metadata,
                             docs::Dict{String,Dict{String,String}} = FUNC_DOCS[])
  isempty(docs) && return String[]
  found = Dict{String,Set{String}}()   # what is reported => the table keys or functions
  for f in funcs
    d = get(docs, f.name, nothing)
    d === nothing && continue
    hit = applying_table(md, f.name)
    byname = Dict(safe_argname(k) => (k, v) for (k, v) in d)
    batched = any(a -> is_batch_count(a.name), f.args)
    for a in f.args
      a.suffix == "(*)" || continue
      doc = get(byname, a.name, nothing)
      doc === nothing && continue
      said = doc_classify(last(doc), first(doc))
      said === nothing && continue
      first(said) == "scalar-device" && batched && continue
      "$(f.name) $(first(doc))" in DOC_ERRATA && continue
      # An explicit `buffer` is a decision the table states (hipfort's shape kept).
      hit !== nothing && (v = get(hit[2], first(doc), nothing); v == "buffer" || (v isa AbstractVector && "buffer" in v)) && continue
      has = effective_kind(md, f.name, a.name)
      first(said) == has && continue
      s = last(said)
      length(s) > 90 && (s = first(s, 87) * "...")
      what = "$(first(doc)): doc says $(first(said)), binding has $(has) (\"$(s)\")"
      k = hit === nothing ? "" : md.origin[hit[1]]
      push!(get!(found, what, Set{String}()),
            hit === nothing ? f.name : occursin(r"[{}]", k) ? "[\"$(k)\"]" : "[$(k)]")
    end
  end
  out = String[]
  for (what, wheres) in found
    tables = sort!([w for w in wheres if startswith(w, "[")])
    plain = sort!([w for w in wheres if !startswith(w, "[")])
    for w in tables; push!(out, "$(w) $(what)"); end
    isempty(plain) || push!(out, "$(brace_key(plain)) $(what)")
  end
  sort!(out)
  isempty(out) ||
    @warn "$(basename(md.path)): $(length(out)) argument(s) whose doc comment says otherwise than the binding " *
          "(a metadata entry to add or fix, or prose to ignore):\n" * join(out, "\n")
  return out
end

# One brace key naming `names` (load_metadata's expand_braces gives them back):
# their common prefix and suffix around the alternatives, rocsolver_{c,d,s,z}gecon.
function brace_key(names::Vector{String})
  ns = sort!(unique(names))
  length(ns) == 1 && return only(ns)
  short = minimum(length, ns)
  p = 0
  while p < short && all(n -> n[p + 1] == ns[1][p + 1], ns); p += 1; end
  q = 0
  while q < short - p && all(n -> n[end - q] == ns[1][end - q], ns); q += 1; end
  alts = [n[p + 1:end - q] for n in ns]
  return "[\"" * ns[1][1:p] * "{" * join(alts, ",") * "}" * ns[1][end - q + 1:end] * "\"]"
end
