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

# Doxygen docstrings of the hipfort layout: the C headers' comments turned into
# `!>` lines that hipfort's docs build (Doxygen, WARN_AS_ERROR=YES) accepts.

# Names Doxygen cannot resolve from Fortran (anchors of doc groups, names the
# bindings do not declare): a \ref to one is a build error. Refreshed with
# refresh_doxygen_denylist.sh when the headers change.
const DOXY_DENYLIST = let f = joinpath(@__DIR__, "doxygen_denylist.txt")
  isfile(f) ? Set(filter(!isempty, strip.(readlines(f)))) : Set{String}()
end

# A \ref, @ref, #X, ::X or X() naming a denylisted name (or one of `deny`, the
# library's own constants: Doxygen cannot link a Fortran enumerator) becomes a
# code span. Run before wrapping, so a reference cannot be split across lines.
function neutralize_denylisted_refs(t::AbstractString, deny::Set{String}) :: String
  (isempty(DOXY_DENYLIST) && isempty(deny)) && return String(t)
  denied(nm) = nm in DOXY_DENYLIST || nm in deny
  s = String(t)
  s = replace(s, r"(?:[\\@]ref[ \t]+|#|::)([A-Za-z_]\w*)" =>
        m -> (nm = match(r"([A-Za-z_]\w*)$", m).captures[1];
              denied(nm) ? "`$nm`" : m))
  s = replace(s, r"([A-Za-z_]\w*)\(\)" =>
        m -> (nm = m[1:end-2];
              denied(nm) ? "`$nm()`" : m))
  return s
end

# Raw doc comment attached to a cursor ("" if none).
function cursor_comment(c) :: String
  cxstr = Clang.LibClang.clang_Cursor_getRawCommentText(c.cursor)
  ptr   = Clang.LibClang.clang_getCString(cxstr)
  s     = ptr == C_NULL ? "" : unsafe_string(ptr)
  Clang.LibClang.clang_disposeString(cxstr)
  return s
end

# A versioned symbol documented only through its inline forwarder takes the
# forwarder's comment. Since ROCm 10.2, HIP documents `static inline
# hipGetDeviceProperties` (and hipChooseDevice), which forwards to an undocumented
# hipGetDevicePropertiesR0600; through ROCm 10.1 a #define made the comment the
# R0600 declaration's. Every header's forwarders: only the functions already in
# DOCS are touched, whatever the path of the headers (no "rocm" needed in it).
function inherit_forwarder_docs!(root)
  fwd = collect_inline_forwarders(root; own = nothing)   # LONG => SHORT
  short_of = Dict(v => k for (k, v) in fwd)
  for c in Clang.children(root)
    Clang.kind(c) == Clang.CXCursor_FunctionDecl || continue
    target = get(short_of, Clang.spelling(c), nothing)
    (target === nothing || !haskey(DOCS[], target) || !isempty(DOCS[][target])) && continue
    DOCS[][target] = cursor_comment(c)
  end
end

# Convert a C/Doxygen comment block into Fortran `!>` lines, stripping the
# `/** … */` / leading-`*` decoration and word-wrapping to the column limit so
# the result stays valid under -std=f2008.
# Reconcile a `@param name` command with the routine's actual dummy arguments
# (`argnames`, lowercased). ROCm headers sometimes document a name that differs
# from the real parameter (e.g. `@param[out] value` for the arg `value_out`, or a
# stale `@param flags`); a strict Doxygen (WARN_AS_ERROR=YES) then errors
# "argument not found". If the doc name matches an arg → keep; if it matches a
# keyword-renamed arg (name → name_) → fix it; otherwise strip the `@param[dir]`
# command, leaving the text so the description survives as prose.
# Normalize the separator between a @param name and its description to " - "
# (as hipfort did): the ROCm headers are inconsistent — some write
# "\param x - desc", most write "\param x desc". Returns " - desc", or "" when
# there is no description, and leaves an existing leading dash untouched.
function _param_sep(rest::AbstractString) :: String
  d = lstrip(rest)
  isempty(d)          && return ""
  startswith(d, "-")  && return " " * d       # already dashed
  return " - " * d
end

function fix_param_line(t::AbstractString, argnames::Set{String})
  isempty(argnames) && return t
  m = match(r"^([\\@])param(\[[^\]]*\])?\s+([A-Za-z_]\w*)(.*)$", t)
  m === nothing && return t
  cmd, dir, name, rest = m.captures[1], something(m.captures[2], ""), m.captures[3], m.captures[4]
  sep = _param_sep(rest)
  ln = lowercase(name)
  ln in argnames && return "$(cmd)param$(dir) $(name)$(sep)"               # valid as-is
  renamed = safe_argname(name)
  (renamed != name && lowercase(renamed) in argnames) &&
    return "$(cmd)param$(dir) $(renamed)$(sep)"                            # renamed dummy (myKind, …)
  return strip("$(name)$(sep)")                                            # unknown → plain text
end

# Turn a group-OPENING docstring into plain group membership.
#
# The ROCm headers open a Doxygen group on the comment of the first function that
# belongs to it:
#
#     \defgroup Device Device Management
#     \ingroup API
#     This section describes the device management functions ...
#     \brief Waits on all active streams ...
#
# Doxygen reads that whole comment as the GROUP's documentation, so the function
# never becomes a member and its own \brief is swallowed into the group page —
# which is why most HIP groups rendered empty. The declarations now live in each
# library's `[doxygen] groups` table (see emit_doxygen_groups), so here we drop the
# opening block and leave the function as a member of the group it used to open.
#
# A comment can open several nested groups at once (API then Driver, on hipInit);
# the function belongs to the innermost one, so the last \defgroup wins. A \ingroup
# INSIDE the block names the group's parent and goes with it; a \ingroup in a
# comment with no \defgroup is the function's own membership and is left alone.
function strip_group_openers(entries::Vector{Tuple{String,String}})
  any(e -> occursin(r"^[\\@]defgroup\b", e[2]), entries) || return entries
  out        = Tuple{String,String}[]
  last_group = ""
  skipping   = false
  for (lead, t) in entries
    m = match(r"^[\\@]defgroup\s+(\w+)", t)
    if m !== nothing
      last_group = String(m.captures[1])
      skipping   = true
      continue
    end
    if skipping
      # The group prose runs until the function's own documentation starts. Only
      # \brief/\param/\return may end it: \note and \warning are routinely part of
      # the group description itself (e.g. MemoryM's Linux/Windows caveat).
      if occursin(r"^[\\@](?:brief|param|return|returns)\b", t)
        skipping = false
      else
        continue
      end
    end
    push!(out, (lead, t))
  end
  isempty(last_group) && return out
  pushfirst!(out, ("", "@ingroup $(last_group)"), ("", ""))
  return out
end

function doc_to_fortran_lines(raw::String, indent::String;
                              argnames::Set{String} = Set{String}(),
                              deny::Set{String} = Set{String}()) :: Vector{String}
  isempty(strip(raw)) && return String[]
  blank = "$(indent)!>"
  out   = String[]
  # Phase 1: strip comment markers / Doxygen noise, keep (leading indent, text).
  cleaned = Tuple{String,String}[]
  for ln in split(raw, '\n')
    t = rstrip(ln)                     # keep the author's leading indent (drop CR/trailing)
    t = replace(t, r"^\s*/\*+!?" => "")   # opening /** or /*! (with any leading ws)
    t = replace(t, r"\*/\s*$" => "")      # closing */
    t = replace(t, r"^\s*\*+!?"  => "")   # leading * on continuation lines
    # Preserve the docstring's original leading indentation, as hipfort did, so the
    # generated !> block matches the hand-written files and shrinks the PR diff.
    lead = match(r"^[ \t]*", t).match
    t = lstrip(t)
    # Strip Doxygen/HTML noise that doesn't read well in Fortran source.
    t = replace(t, r"@\{|@\}" => "")                          # group markers
    t = replace(t, r"(?i)</?(?:b|i|tt|em|code|br|p)\s*/?>" => "") # simple HTML tags
    t = replace(t, r"\\n(?![A-Za-z])" => "")                  # Doxygen \n line-break command
    t = replace(t, r"`{3,}" => "``")                         # collapse stray 3+ backticks
    t = replace(t, r"``([^`\n]*[\[\]|][^`\n]*)``" => s"\1")  # code spans with [ ] | -> plain
    t = replace(t, r"[\\@](?:snippet|include|includelineno|dontinclude|htmlinclude|example)\b.*$" => "")
    t = replace(t, r"\\le(?![a-zA-Z])"  => "&le;")
    t = replace(t, r"\\ge(?![a-zA-Z])"  => "&ge;")
    t = replace(t, r"\\leq\b" => "&le;")
    t = replace(t, r"\\geq\b" => "&ge;")
    t = replace(t, r"\\ne(?:q)?(?![a-zA-Z])" => "&ne;")
    t = replace(t, r"@oaram\b" => "@param")   # header typo for @param
    t = strip(t)
    push!(cleaned, (lead, String(t)))
  end
  # Phase 2: some ROCm headers (rocBLAS/hipBLAS/rocSPARSE/rocSOLVER/hipSPARSE) put a
  # bare `@param[dir]` on its own line and the parameter NAME on the next line. Merge
  # the two so fix_param_line attaches the " - description" separator, matching the
  # single-line layout the HIP runtime and FFT headers already use.
  merged = Tuple{String,String}[]
  i = 1
  while i <= length(cleaned)
    lead, t = cleaned[i]
    pm = match(r"^([\\@]param(?:\[[^\]]*\])?)$", t)
    if pm !== nothing && i < length(cleaned) &&
       match(r"^[A-Za-z_]\w*", cleaned[i+1][2]) !== nothing
      # Merge only the name line onto `@param[dir]` (fix_param_line then adds " - ").
      # We deliberately do NOT absorb the following description lines: rocBLAS et al.
      # document enum-valued params (transA, uplo, side, …) as multi-line bullet
      # lists, which collapsing to one line would turn into an unreadable run-on.
      push!(merged, (lead, pm.captures[1] * " " * cleaned[i+1][2]))
      i += 2
    elseif occursin(r"[\\@]ref\s*$", t) && i < length(cleaned)
      # A `@ref` left dangling at end of line, its target on the next one. The C
      # headers wrap their prose, so this happens naturally; joining here is what
      # lets neutralize_denylisted_refs (which works a line at a time) see the
      # pair at all. Doxygen reports the unresolved reference against the NEXT
      # line, which is why it looks like a bare word.
      push!(merged, (lead, rstrip(t) * " " * lstrip(cleaned[i+1][2])))
      i += 2
    else
      push!(merged, (lead, t))
      i += 1
    end
  end
  merged = strip_group_openers(merged)
  # Phase 3: reconcile @param names, neutralize refs, wrap, emit.
  for (lead, t0) in merged
    t = fix_param_line(t0, argnames)    # reconcile @param names with real args (+ " - " sep)
    t = neutralize_denylisted_refs(t, deny)   # before wrapping: \ref/#/:: /X() -> `X`
    if isempty(t)
      push!(out, blank); continue
    end
    prefix = "$(indent)!> " * lead
    if length(prefix) + length(t) <= FORTRAN_MAX_COL
      push!(out, prefix * t)
    else
      cur = prefix
      # Tokenize keeping backtick code spans (`x` / ``x y``) atomic, so wrapping
      # never splits one across `!>` lines (a split span confuses Doxygen's <tt>).
      toks = [m.match for m in eachmatch(r"``.*?``[.,;:!?]*|`[^`]*`[.,;:!?]*|\S+", t)]
      for w in toks
        cand = cur == prefix ? cur * w : cur * " " * w
        if length(cand) > FORTRAN_MAX_COL && cur != prefix
          push!(out, cur); cur = prefix * w
        else
          cur = cand
        end
      end
      cur != prefix && push!(out, cur)
    end
  end
  # A trailing backslash is consumed as a line-continuation by the C preprocessor
  # (hipfort's docs build runs `gfortran -E -cpp`), splicing adjacent `!>` lines.
  # Append `%` (a no-op LaTeX EOL comment) so the line no longer ends in `\`.
  for i in eachindex(out)
    endswith(out[i], '\\') && (out[i] = out[i] * "%")
  end
  while !isempty(out) && out[1]   == blank; popfirst!(out); end
  while !isempty(out) && out[end] == blank; pop!(out); end
  return out
end

# A C struct-field comment as one `!<` line.
function field_doc(raw::String) :: String
  isempty(strip(raw)) && return ""
  parts = String[]
  for ln in split(raw, '\n')
    l = strip(ln)
    l = replace(l, r"^/\*+!?<?" => "")   # /**  /**<  /*!<
    l = replace(l, r"\*+/\s*$" => "")    # */
    l = replace(l, r"^//+!?<?" => "")    # //  ///  //!  ///<
    l = replace(l, r"^\*+!?<?\s?" => "") # leading * (continuation lines)
    l = strip(l)
    isempty(l) || push!(parts, l)
  end
  return strip(replace(join(parts, " "), r"\s+" => " "))
end
