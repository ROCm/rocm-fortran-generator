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

# Intermediate representation filled by the Clang frontend and consumed by the
# Fortran emitters.

struct ArgInfo
  name      :: String
  ftype     :: String   # e.g. "real(c_double)"
  suffix    :: String   # ", value"  |  "(*)"  |  ""
  is_string :: Bool     # INPUT string: the C type is `const char*`
  ctype     :: String   # the C type as declared, e.g. "const float *"; "" if built by hand
end
ArgInfo(name::AbstractString, ftype::AbstractString, suffix::AbstractString, is_string::Bool) =
  ArgInfo(name, ftype, suffix, is_string, "")

struct FuncInfo
  name      :: String
  ret_ftype :: String   # "void" or a Fortran type string
  is_void   :: Bool
  args      :: Vector{ArgInfo}
end

struct EnumInfo
  name      :: String                        # "" for anonymous enums
  constants :: Vector{Pair{String,Int64}}
end

struct FieldInfo
  name  :: String
  ftype :: String     # e.g. "integer(c_int)" or "type(hipUUID)"
  dims  :: String     # "" or "(3)" or "(3,2)"
  doc   :: String     # generator note emitted as `!<`, e.g. for a C union ("" if none)
end

struct StructInfo
  name   :: String
  fields :: Vector{FieldInfo}
  deps   :: Vector{String}   # names of embedded struct types
end
