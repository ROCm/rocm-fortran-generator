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

# The hipfort layout (ROCM_FORTRAN_LAYOUT=hipfort): the mini fixture generated into
# hipfort's separate modules, against golden files, with its CUDA branches
# (fixtures/mini/mini.txt, mini_enums_cuda.txt) and docstrings, then compiled.
# Set ROCM_FORTRAN_REFRESH_GOLDEN to rewrite the golden files on purpose.
#
#   julia --project=src src/test/hipfort_layout.jl

# The layout is read when the generator is included.
ENV["ROCM_FORTRAN_LAYOUT"] = "hipfort"
using Test
include(joinpath(@__DIR__, "gen_mini.jl"))

const GOLDEN = joinpath(@__DIR__, "fixtures", "hipfort")

# [library] uses (the uses/ fixture, as hipfft and hipfftxt): hipfort_ulibxt uses
# hipfort_ulib whole, so `use hipfort_ulibxt` alone gives both APIs, as cufftXt does
# cufft; its enums and types are modules of its own, and it shares ulib's CUDA map.
@testset "hipfort layout: [library] uses" begin
  fx   = joinpath(@__DIR__, "fixtures", "uses")
  tmp  = mktempdir()
  meta = joinpath(tmp, "metadata"); mkpath(meta)
  write(joinpath(meta, "ulib.txt"), "ulibCreate cuulibCreate\nulibXtMalloc cuulibXtMalloc\nulibXtSetArea cuulibXtSetArea\n")
  for lib in ("ulib", "ulibxt")
    d = joinpath(tmp, lib); mkpath(d)
    cfg = replace(read(joinpath(fx, "$(lib).toml"), String),
                  "[library]\n" => "[library]\nmetadata_dir = \"$(meta)\"\n")
    write(joinpath(d, "$(lib).toml"), cfg)
    run_library_generator(d; include_dir = joinpath(fx, "include"))
  end
  out(lib, f) = joinpath(tmp, lib, "output", f)
  @test !isfile(out("ulib", "hipfort_ulib_types.F90"))   # ulib.h binds no type
  xt    = read(out("ulibxt", "hipfort_ulibxt.F90"), String)
  xtenm = read(out("ulibxt", "hipfort_ulibxt_enums.F90"), String)
  base  = read(out("ulib", "hipfort_ulib.F90"), String) * read(out("ulib", "hipfort_ulib_enums.F90"), String)
  @test occursin("module hipfort_ulibxt\n  use hipfort_ulib\n  use hipfort_ulibxt_enums\n" *
                 "  use hipfort_ulibxt_types\n  implicit none\n", xt)
  # Nothing of ulib is redeclared or `use`d narrowly (a PRIVATE would hide it).
  @test !occursin("hipfort_ulib_enums", xt) && !occursin("private", xt)
  @test !occursin("ULIB_SUCCESS", xtenm) && !occursin("ULIB_FORWARD", xtenm)
  @test occursin("ULIB_XT_FORMAT_INPUT = 0", xtenm) && occursin("ULIB_XT_MAX_GPUS = 8", xtenm)
  @test occursin("type, bind(c) :: ulibXtDesc", read(out("ulibxt", "hipfort_ulibxt_types.F90"), String))
  @test !occursin("ulibXt", base) && !occursin("ULIB_XT", base)
  # By name: ulibXtSetArea, declared in ulib.h, is ulibxt's.
  @test occursin("bind(c, name=\"ulibXtSetArea\")", xt)
  # A group its docstrings name is defined in the module of its members, which
  # alone carries the [doxygen] groups of its config: every @ingroup of the two
  # modules resolves, and no group is defined twice (both break hipfort's docs).
  ulibmod = read(out("ulib", "hipfort_ulib.F90"), String)
  @test occursin("!>  @ingroup ulibXtMem\n", xt)
  @test occursin("!>   @defgroup ulibXtMem Multi-device memory\n", xt)
  @test !occursin("ulibXtMem", ulibmod)
  defs = [m[1] for t in (xt, ulibmod) for m in eachmatch(r"@defgroup\s+(\w+)", t)]
  @test allunique(defs)
  @test all(m -> m[1] in defs, (m for t in (xt, ulibmod) for m in eachmatch(r"@ingroup\s+(\w+)", t)))
  # Only ulib has a status enum, so only it has a check helper.
  @test isfile(out("ulib", "ulib.checkmeta")) && !isfile(out("ulibxt", "ulibxt.checkmeta"))
  # ulib's CUDA map: a mapped routine binds its CUDA twin, an unmapped one is ROCm-only.
  @test occursin("#ifdef USE_CUDA_NAMES\n    function ulibXtMalloc_(plan,desc,myFormat) bind(c, name=\"cuulibXtMalloc\")", xt)
  @test occursin("#ifndef USE_CUDA_NAMES\n  interface ulibXtFree\n", xt)

  fc = get(ENV, "FC", "gfortran")
  if Sys.which(fc) === nothing
    @info "$(fc) not found, skipping the compile check"
  else
    write(joinpath(tmp, "prog.f90"), """
      program p
        use hipfort_ulibxt
        implicit none
        type(c_ptr) :: plan, desc
        type(ulibXtDesc) :: d
        integer(kind(ULIB_SUCCESS)) :: st
        st = ulibXtMalloc(plan, desc, ULIB_XT_FORMAT_INPUT)
        if (st == ULIB_SUCCESS) st = ulibCreate(plan)
        if (st == ULIB_SUCCESS) st = ulibXtSetArea(plan, desc)
        d%nGPUs = ULIB_XT_MAX_GPUS
      end program p
      """)
    srcs = [out("ulib", "hipfort_ulib_enums.F90"), out("ulib", "hipfort_ulib.F90"),
            out("ulibxt", "hipfort_ulibxt_enums.F90"), out("ulibxt", "hipfort_ulibxt_types.F90"),
            out("ulibxt", "hipfort_ulibxt.F90"), joinpath(tmp, "prog.f90")]
    for defs in ([], ["-DUSE_CUDA_NAMES"], ["-DUSE_ASSUMED_RANK"])
      dir = mktempdir()
      @test all(f -> success(pipeline(`$fc -cpp $defs -fsyntax-only -J$dir -I$dir $f`;
                                      stdout=devnull, stderr=devnull)), srcs)
    end
  end
end

# A nullable argument (the nullable/ fixture, as hipModuleGetGlobal's dptr) is taken
# by reference by the _opt form and by value by the bind(C) specific, which leaves
# the generic. The generic resolves to _opt on both backends, including for a
# routine the NVIDIA backend binds to the driver API (cu*, as cuModuleGetGlobal_v2),
# so that `call X(dptr, ...)` passes the address of dptr under USE_CUDA_NAMES too.
@testset "hipfort layout: nullable arguments on both backends" begin
  fx  = joinpath(@__DIR__, "fixtures", "nullable")
  tmp = mktempdir()
  d   = joinpath(tmp, "nlib"); mkpath(d)
  write(joinpath(d, "nlib.toml"),
        replace(read(joinpath(fx, "nlib.toml"), String),
                "[library]\n" => "[library]\nmetadata_dir = \"$(joinpath(fx, "metadata"))\"\n"))
  run_library_generator(d; include_dir = joinpath(fx, "include"))
  out(f) = joinpath(d, "output", f)
  mod = read(out("hipfort_nlib.F90"), String)
  # The driver-bound routine: _opt alone under USE_CUDA_NAMES, _opt and _typed on
  # ROCm; the bind(C) specific is in neither.
  @test occursin("  interface nlibGetGlobal\n\n#ifdef USE_CUDA_NAMES\n" *
                 "    module procedure nlibGetGlobal_opt\n#else\n" *
                 "    module procedure &\n      nlibGetGlobal_opt,&\n      nlibGetGlobal_typed\n" *
                 "#endif\n  end interface\n", mod)
  @test !occursin("procedure nlibGetGlobal_\n", mod)
  # Its _opt form is compiled for both backends, its _typed form for ROCm only.
  @test occursin("  contains\n\n    function nlibGetGlobal_opt(", mod)
  @test occursin("#ifndef USE_CUDA_NAMES\n    function nlibGetGlobal_typed(", mod)
  # The runtime-bound routine: the same generic on both backends.
  @test occursin("  interface nlibGetNodes\n\n    module procedure &\n" *
                 "      nlibGetNodes_opt,&\n      nlibGetNodes_typed\n  end interface\n", mod)

  # Called through the generic, the C entry point of each backend receives the
  # address of dptr and nodes, or NULL when they are absent.
  fc = get(ENV, "FC", "gfortran")
  cc = get(ENV, "CC", "gcc")
  if Sys.which(fc) === nothing || Sys.which(cc) === nothing
    @info "$(fc) or $(cc) not found, skipping the run check"
  else
    write(joinpath(tmp, "stub.c"), """
      #include <stddef.h>
      static int get(void** dptr, size_t* bytes) {
        if (!dptr) return 1;
        *dptr = (void*)0x1234;
        if (bytes) *bytes = 42;
        return 0;
      }
      static int nodes(void** nodes, size_t* n) {
        *n = 3;
        if (!nodes) return 1;
        *nodes = (void*)0x5678;
        return 0;
      }
      int cuNlibGetGlobal(void** d, size_t* b, void* m, const char* s) { return get(d, b); }
      int nlibGetGlobal(void** d, size_t* b, void* m, const char* s) { return get(d, b); }
      int cudaNlibGetNodes(void* g, void** p, size_t* n) { return nodes(p, n); }
      int nlibGetNodes(void* g, void** p, size_t* n) { return nodes(p, n); }
      """)
    write(joinpath(tmp, "prog.f90"), """
      program p
        use iso_c_binding
        use hipfort_nlib
        implicit none
        type(c_ptr), target :: dptr, hmod, nodes
        integer(c_size_t), target :: bytes, n
        integer :: bad
        bad = 0
        dptr = c_null_ptr; hmod = c_null_ptr; nodes = c_null_ptr; bytes = 0
        if (nlibGetGlobal(dptr, c_loc(bytes), hmod, c_null_ptr) /= NLIB_SUCCESS) bad = 1
        if (transfer(dptr, 0_c_intptr_t) /= int(z'1234', c_intptr_t) .or. bytes /= 42) bad = 2
        if (nlibGetGlobal(bytes=c_loc(bytes), hmod=hmod, name=c_null_ptr) /= NLIB_FAILURE) bad = 3
        if (nlibGetNodes(hmod, nodes, c_loc(n)) /= NLIB_SUCCESS) bad = 4
        if (transfer(nodes, 0_c_intptr_t) /= int(z'5678', c_intptr_t) .or. n /= 3) bad = 5
        if (nlibGetNodes(hmod, numNodes=c_loc(n)) /= NLIB_FAILURE) bad = 6
        if (bad /= 0) error stop bad
      end program p
      """)
    for defs in ([], ["-DUSE_CUDA_NAMES"])
      dir = mktempdir()
      objs = [joinpath(dir, "stub.o")]
      ok = success(pipeline(`$cc -c $(joinpath(tmp, "stub.c")) -o $(objs[1])`; stderr=devnull))
      for f in (out("hipfort_nlib_enums.F90"), out("hipfort_nlib.F90"), joinpath(tmp, "prog.f90"))
        o = joinpath(dir, splitext(basename(f))[1] * ".o"); push!(objs, o)
        ok = ok && success(pipeline(`$fc -cpp $defs -c -J$dir -I$dir $f -o $o`;
                                    stdout=devnull, stderr=devnull))
      end
      exe = joinpath(dir, "prog")
      ok = ok && success(pipeline(`$fc $objs -o $exe`; stdout=devnull, stderr=devnull))
      @test ok && success(`$exe`)
    end
  end
end

@testset "hipfort layout" begin
  out, _ = gen_mini()
  files = ["hipfort_mini_enums.F90", "hipfort_mini_types.F90", "hipfort_mini.F90"]
  @test all(f -> isfile(joinpath(out, f)), files)
  @test !isfile(joinpath(out, "mini.F90"))

  for f in files
    txt = read(joinpath(out, f), String)
    golden = joinpath(GOLDEN, f)
    haskey(ENV, "ROCM_FORTRAN_REFRESH_GOLDEN") && write(golden, txt)
    @test txt == read(golden, String)
  end

  mod   = read(joinpath(out, "hipfort_mini.F90"), String)
  enums = read(joinpath(out, "hipfort_mini_enums.F90"), String)
  # The module re-exports its enums and types; each interface body IMPORTs them,
  # and no scope `use`s a module the module has (ftn reads it again each time).
  @test occursin("module hipfort_mini\n  use hipfort_mini_enums\n  use hipfort_mini_types\n", mod)
  @test occursin("bind(c, name=\"mini_cscal\")\n      import\n      implicit none", mod)
  @test !occursin(r"^ {6}use "m, mod)
  # hipfort's copyright span.
  @test occursin("Copyright (C) 2020-2026", mod)
  # A mapped routine binds its CUDA twin under USE_CUDA_NAMES; an unmapped one is
  # ROCm-only.
  @test occursin("#ifdef USE_CUDA_NAMES\n    function mini_create_(handle) bind(c, name=\"cuminiCreate\")\n#else", mod)
  @test occursin("#ifndef USE_CUDA_NAMES\n  interface mini_destroy\n", mod)
  @test occursin("#ifdef USE_CUDA_NAMES\n    enumerator :: MINI_OP_T = 2\n#else\n    enumerator :: MINI_OP_T = 1\n#endif", enums)
  # The headers' Doxygen comments as docstrings.
  @test occursin("  !> ", mod)
  # A versioned symbol documented only on its inline forwarder takes its comment.
  @test occursin("  !>  @brief Choose a device (documented on the forwarder only).\n#ifndef USE_CUDA_NAMES\n  interface mini_choose_R0600\n", mod)

  # The check routine goes to hipfort_check, assembled from the .checkmeta.
  @test !occursin("miniCheck", mod)
  @test readlines(joinpath(out, "mini.checkmeta"))[1:4] ==
        ["miniCheck", "MINI_STATUS_SUCCESS", "hipfort_mini_enums", "MINI"]
  gen_unified_check_file([out], out)
  check = read(joinpath(out, "hipfort_check.F90"), String)
  @test occursin("  subroutine miniCheck(status)", check)
  @test occursin("    use hipfort_mini_enums, only: MINI_STATUS_SUCCESS, MINI_STATUS_FAILURE", check)

  # The modules compile, in both backends' configuration (the ROCm and the CUDA one).
  fc = get(ENV, "FC", "gfortran")
  if Sys.which(fc) === nothing
    @info "$(fc) not found, skipping the compile check"
  else
    for defs in ([], ["-DUSE_CUDA_NAMES"], ["-DUSE_ASSUMED_SHAPE"], ["-DUSE_ASSUMED_RANK"])
      dir = mktempdir()
      ok = all(files) do f
        success(pipeline(`$fc -cpp $defs -fsyntax-only -J$dir -I$dir $(joinpath(out, f))`;
                         stdout=devnull, stderr=devnull))
      end
      @test ok
    end
  end
end
