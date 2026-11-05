# Copyright span of a hipfort-layout module: hipfort's modules date from 2020,
# hipFFTW's from 2026 and ROCTx's from 2024. The packaged modules are 2026.
const LICENSE_YEARS = Dict("hipfftw" => "2026", "roctx" => "2024-2026")
license_years(name::AbstractString) =
  HIPFORT ? get(LICENSE_YEARS, String(name), "2020-2026") : "2026"
license_years(cfg::Dict) = license_years(cfg["general"]["name"])

# MIT notice with an SPDX line, as in hipfort (ROCm/hipfort#563).
function emit_license_header(io; years::String = "2026")
  println(io, "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!")
  println(io, "! Copyright (C) $(years) Advanced Micro Devices, Inc. All rights reserved.")
  println(io, "!")
  println(io, "! SPDX-License-Identifier: MIT")
  println(io, "!")
  println(io, "! Permission is hereby granted, free of charge, to any person obtaining a copy")
  println(io, "! of this software and associated documentation files (the \"Software\"), to deal")
  println(io, "! in the Software without restriction, including without limitation the rights")
  println(io, "! to use, copy, modify, merge, publish, distribute, sublicense, and/or sell")
  println(io, "! copies of the Software, and to permit persons to whom the Software is")
  println(io, "! furnished to do so, subject to the following conditions:")
  println(io, "!")
  println(io, "! The above copyright notice and this permission notice shall be included in")
  println(io, "! all copies or substantial portions of the Software.")
  println(io, "!")
  println(io, "! THE SOFTWARE IS PROVIDED \"AS IS\", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR")
  println(io, "! IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,")
  println(io, "! FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE")
  println(io, "! AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER")
  println(io, "! LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,")
  println(io, "! OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN")
  println(io, "! THE SOFTWARE.")
  println(io, "!")
  println(io, "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!")
  println(io, "")
end
