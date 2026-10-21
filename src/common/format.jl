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

# The free-form line limit of the Fortran standard; FORTRAN_MAX_COL is our tighter
# layout target.
const FORTRAN_LINE_LIMIT = 132

# Print `line`, splitting it with `&` continuations to stay within FORTRAN_MAX_COL when a
# break point allows it, else at the first ',' or '(' before FORTRAN_LINE_LIMIT; a line
# with no such break point is printed unchanged.
# Columns are characters, not bytes, so a line with non-ASCII text wraps safely.
function println_wrapped(io, line::String, cont_indent::String = "   ")
  chars = collect(line)
  n = length(chars)
  n <= FORTRAN_MAX_COL && (println(io, line); return)
  soft = min(FORTRAN_MAX_COL - 2, n)
  lastof(ch) = (for i in soft:-1:2; chars[i] == ch && return i; end; 0)
  # Break preference before the soft limit: ',' (keeps a trailing bind(c, name=...)
  # intact), then '(', then '='.
  pos = lastof(',')
  pos == 0 && (pos = lastof('('))
  pos == 0 && (pos = lastof('='))
  # Otherwise take the first ',' or '(' past it, leaving room for " &".
  if pos == 0
    for i in (FORTRAN_MAX_COL - 1):min(FORTRAN_LINE_LIMIT - 2, n)
      (chars[i] == ',' || chars[i] == '(') && (pos = i; break)
    end
  end
  pos == 0 && (println(io, line); return)   # genuinely unbreakable
  println(io, String(chars[1:pos]) * " &")
  println_wrapped(io, cont_indent * lstrip(String(chars[pos+1:end])), cont_indent)
end

# Emit `<head> <bind_clause>`; when too long, wrap `head` and put the bind clause
# intact on its own continuation line.
function emit_bind_signature(io, head::String, bind_clause::String, cont_indent::String)
  full = head * " " * bind_clause
  if length(full) <= FORTRAN_MAX_COL
    println(io, full)
  else
    println_wrapped(io, head * " &", cont_indent)
    println(io, cont_indent * bind_clause)
  end
end
