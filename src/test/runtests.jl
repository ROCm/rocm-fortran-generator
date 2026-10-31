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

# Unit tests for the generator: emitters captured into an IOBuffer, helpers and
# loaders, plus Clang parses of the self-contained headers under fixtures/, so no
# ROCm install is needed.
#
# Run:  julia --project=src src/test/runtests.jl
#   coverage:  julia --project=src --code-coverage=user src/test/runtests.jl

using Test

include(joinpath(@__DIR__, "gen_mini.jl"))
include(joinpath(COMMON, "hip_generics.jl"))
include(joinpath(COMMON, "blas_generics.jl"))
include(joinpath(COMMON, "header_sources.jl"))

# Free-form lines must fit in 132 columns; preprocessor directives are consumed by
# cpp and exempt. Returns the offending (lineno, ncols, text) tuples.
const FORTRAN_MAX_COLS = 132
overlong_fortran_lines(s::AbstractString) =
    [(i, length(l), l) for (i, l) in enumerate(split(s, '\n'))
     if length(l) > FORTRAN_MAX_COLS && !startswith(lstrip(l), "#")]

@testset "generator" begin

    @testset "type mapping" begin
        @test complex_kind("hipDoubleComplex")      == "c_double_complex"
        @test complex_kind("rocblas_float_complex") == "c_float_complex"
        @test complex_kind("hipComplex")            == "c_float_complex"
        @test complex_kind("int")                   === nothing

        @test typedef_ckind("size_t")         == "integer(c_size_t)"
        @test typedef_ckind("int32_t")        == "integer(c_int32_t)"
        @test typedef_ckind("uint64_t")       == "integer(c_int64_t)"
        @test typedef_ckind("rocblas_stride") == "integer(c_int64_t)"   # LLP64 ABI guard
        @test typedef_ckind("int")            === nothing

        @test clean_type_name("const hipStream_t *")   == "hipStream_t"
        @test clean_type_name("hipDeviceProp_tR0600")  == "hipDeviceProp_t"  # R#### stripped
    end

    @testset "name / spec / arg helpers" begin
        @test spec_name("hipblasSgemm", "_rank_2") == "hipblasSgemm_rank_2"
        long = spec_name("x"^70, "_suf")
        @test length(long) <= 63 && endswith(long, "_suf")   # 63-char identifier limit

        @test is_buffer(ArgInfo("x", "real(c_double)", "(*)", false))
        @test !is_buffer(ArgInfo("n", "integer(c_int)", ", value", false))

        ra = raw_arg(ArgInfo("x", "real(c_double)", "(*)", false))
        @test ra.ftype == "type(c_ptr)" && ra.suffix == ", value"  # buffer -> c_ptr,value
    end

    @testset "spec_name collision disambiguation" begin
        # A collision is not a compile error but a generic listing the OTHER
        # function's specific, i.e. a call to the wrong C entry point.
        #
        # A pair that once occurred: "…_bufferSize" + an 18-character suffix is exactly
        # 63 characters, never truncated, while "…_bufferSizeExt" cut to fit lands on the
        # same string, so spec_name must register untruncated names too.
        memo, taken = copy(SPEC_MEMO), copy(SPEC_TAKEN)
        try
            base = "hipsparseSpruneCsr2csrByPercentage_bufferSize"
            ext  = base * "Ext"
            suf  = "_assumed_rank_cptr"
            @test length(base * suf) == 63        # the untruncated half of the clash

            empty!(SPEC_MEMO); empty!(SPEC_TAKEN)
            @test spec_name(base, suf) == base * suf    # first caller keeps the plain cut
            got = spec_name(ext, suf)
            @test got != base * suf
            @test length(got) == 63                     # still within the identifier limit
            # The tag is FNV-1a of the base, pinned as a literal: Julia's `hash` is
            # not stable across versions and would rename shipped specifics.
            @test got == "hipsparseSpruneCsr2csrByPercentage_buffe_c00d_assumed_rank_cptr"
            @test spec_name(ext, suf) == got            # memoized: emission is stable

            # The bounded retry loop, when the tagged name is taken as well (no
            # natural input reaches it). The second tag is FNV-1a of base*"1".
            empty!(SPEC_MEMO); empty!(SPEC_TAKEN)
            spec_name(base, suf)
            SPEC_TAKEN["hipsparseSpruneCsr2csrByPercentage_buffe_c00d_assumed_rank_cptr"] =
                "someone_elses_base"
            @test spec_name(ext, suf) ==
                  "hipsparseSpruneCsr2csrByPercentage_buffe_9e74_assumed_rank_cptr"

            # Uncontested: a long name is truncated but not tagged, matching the
            # identifiers upstream hipfort ships.
            empty!(SPEC_MEMO); empty!(SPEC_TAKEN)
            @test spec_name(ext, suf) == base * suf
        finally
            empty!(SPEC_MEMO);  merge!(SPEC_MEMO, memo)
            empty!(SPEC_TAKEN); merge!(SPEC_TAKEN, taken)
        end
    end

    @testset "bind emission" begin
        f = FuncInfo("hipMalloc", "integer(c_int)", false,
                     [ArgInfo("ptr",  "type(c_ptr)",       ", value", false),
                      ArgInfo("size", "integer(c_size_t)", ", value", false)])
        io = IOBuffer()
        emit_generic(io, f, LibMeta())
        s = String(take!(io))
        # Every function is a generic around its bind(C) specific X_, as in hipfort.
        @test occursin("  interface hipMalloc\n    function hipMalloc_(ptr,size) bind(c, name=\"hipMalloc\")", s)
        @test !occursin("#if", s) && occursin("end interface", s)
    end

    richf = FuncInfo("hipblasSscal", "integer(c_int)", false,
        [ArgInfo("handle", "type(c_ptr)",           ", value", false),
         ArgInfo("n",      "integer(c_int)",        ", value", false),
         ArgInfo("x",      "real(c_float)",         "(*)",     false),
         ArgInfo("incx",   "integer(c_int)",        ", value", false)])

    @testset "wrapper bodies (per-rank / assumed-rank)" begin
        io = IOBuffer(); emit_rank_wrapper(io, richf, LibMeta(), 1)
        s = String(take!(io))
        @test occursin("hipblasSscal_rank_1", s) && occursin("c_loc(", s) && occursin("end function", s)

        io = IOBuffer(); emit_rank_wrapper(io, richf, LibMeta(); assumed=true)
        s = String(take!(io))
        @test occursin("hipblasSscal_assumed_rank", s) && occursin("dimension(..)", s)

        # The void half: no result variable, `call`, and `end subroutine`.
        voidf = FuncInfo("hipblasVoid", "void", true,
            [ArgInfo("handle", "type(c_ptr)",           ", value", false),
             ArgInfo("x",      "real(c_float)",         "(*)",     false)])
        io = IOBuffer(); emit_rank_wrapper(io, voidf, LibMeta(), 1)
        s = String(take!(io))
        @test occursin("    subroutine hipblasVoid_rank_1(handle,x)", s)
        @test occursin("      call hipblasVoid_(handle,c_loc(x))", s)
        @test occursin("    end subroutine", s) && !occursin("end function", s)
        @test !occursin("hipblasVoid_rank_1 =", s)     # no result assignment
    end

    @testset "wrapper use preamble" begin
        # Nothing but iso_c_binding: the enums, types and sibling names come by
        # host association from the library module.
        io = IOBuffer(); emit_wrapper_uses(io)
        @test String(take!(io)) == "      use iso_c_binding\n      implicit none\n"
    end

    @testset "check messages (status names)" begin
        enums = [EnumInfo("zz_other_t", ["ZZ_A" => Int64(0), "ZZ_B" => Int64(1)]),
                 EnumInfo("zzStatus_t", ["ZZ_SUCCESS" => Int64(0), "ZZ_BAD" => Int64(1),
                                         "ZZ_WORSE" => Int64(2), "ZZ_BAD_ALIAS" => Int64(1)])]
        # the enum holding the success constant, minus success, one name per value
        @test status_names(enums, "zz_success") == ["ZZ_BAD", "ZZ_WORSE"]
        @test isempty(status_names(enums, "OTHER_SUCCESS"))

        io = IOBuffer()
        emit_check_failure(io, "  ", "ZZ", ["ZZ_BAD", "ZZ_WORSE"])
        s = String(take!(io))
        @test occursin("  select case (status)\n  case (ZZ_BAD)\n    name = \"ZZ_BAD\"", s)
        @test occursin("  case default\n    name = \"unknown status\"", s)
        @test occursin("write (*, \"(a,i0,a)\") \"ZZ ERROR: \" // name // \" (code \", status, \")\"", s)
        io = IOBuffer()
        emit_check_failure(io, "  ", "ZZ", String[])
        @test String(take!(io)) == "  write (*, *) \"ZZ ERROR: code = \", status\n"

        # The <lib>Check routine of the module, named by [check] name if given. The
        # success constant is host-associated: no `use` line.
        io = IOBuffer()
        write_check_routine(io, Dict("general" => Dict("name" => "zz")),
                            status_names(enums, "ZZ_SUCCESS"), "ZZ_SUCCESS")
        c = String(take!(io))
        @test startswith(c, "    subroutine zzCheck(status)\n      implicit none\n")
        @test occursin("      integer(kind(ZZ_SUCCESS)) :: status\n", c)
        @test occursin("\"ZZ ERROR: \" // name", c) && count("stop 1", c) == 1
        io = IOBuffer()
        write_check_routine(io, Dict("general" => Dict("name" => "zz"),
                                     "check"   => Dict("name" => "zzAssert")), String[], "ZZ_SUCCESS")
        @test occursin("subroutine zzAssert(status)", String(take!(io)))
    end

    @testset "emit_generic interface + module procedures" begin
        io = IOBuffer()
        # array overloads: any function with a data buffer gets them
        emit_generic(io, richf, LibMeta())
        s = String(take!(io))
        @test occursin("interface hipblasSscal", s)
        @test occursin("module procedure", s) && occursin("hipblasSscal_rank_1", s)

        # Pointer-mode scalars (`scalar-pointer-mode`): the bind(C) specific takes type(c_ptr)
        # and the host form is a module procedure. Exactly ONE bind(c, name=…) per
        # generic: two bind(C) specifics on one binding label violate F2018 19.2.
        let meta = LibMeta(scalar_ptrs = Dict("zzaxpy" => Set(["alpha"])))
            df = FuncInfo("zzaxpy", "integer(c_int)", false,
                 [ArgInfo("handle", "type(c_ptr)",           ", value", false),
                  ArgInfo("alpha",  "real(c_double)",        "",        false),
                  ArgInfo("x",      "real(c_double)",        "(*)",     false)])
            @test wants_typed(df, meta)

            io = IOBuffer()
            emit_generic(io, df, meta)
            s = String(take!(io))
            @test count(x -> occursin("bind(c, name=\"zzaxpy\")", x), split(s, '\n')) == 1
            @test occursin("function zzaxpy_(handle,alpha,x)", s)
            @test occursin("      type(c_ptr),value :: alpha\n", s)
            @test !occursin("      real(c_double) :: alpha\n", s)
            # The typed form is listed in the generic, outside the tier guard.
            @test occursin("module procedure zzaxpy_typed", s)

            io = IOBuffer()
            emit_typed_body(io, [df], meta)
            s = String(take!(io))
            @test occursin("function zzaxpy_typed(handle,alpha,x)", s)
            @test occursin("      real(c_double),target :: alpha\n", s)
            @test occursin("      type(c_ptr) :: x\n", s)          # buffers stay pointers
            @test occursin("zzaxpy_typed = zzaxpy_(handle,c_loc(alpha),x)", s)
        end

        # An optional scalar (`nullable`): absent, it reaches C as NULL.
        let meta = LibMeta(scalar_ptrs = Dict("zzget" => Set(["v", "err"])))
            dg = FuncInfo("zzget", "integer(c_int)", false,
                 [ArgInfo("v",   "integer(c_int)", "",           false),
                  ArgInfo("err", "integer(c_int)", ", optional", false)])
            io = IOBuffer()
            emit_typed_body(io, [dg], meta)
            s = String(take!(io))
            @test occursin("      integer(c_int),optional,target :: err\n", s)
            @test occursin("if (present(err)) err__p = c_loc(err)", s)
            @test occursin("zzget_typed = zzget_(c_loc(v),err__p)", s)
        end

        # `const char*` arguments ([library] string_args, ROCTx): the bind(C)
        # specific keeps type(c_ptr),value and stays in the generic; _typed takes
        # the caller's character storage and forwards c_loc of it, with no copy.
        let meta = LibMeta(string_args = true)
            ds = FuncInfo("zzname", "integer(c_int)", false,
                 [ArgInfo("name",   "type(c_ptr)",    ", value", true),
                  ArgInfo("device", "integer(c_int)", ", value", false)])
            @test !wants_typed(ds, LibMeta())
            @test wants_typed(ds, meta) &&
                  string_args(ds, meta) == Set(["name"])

            io = IOBuffer()
            emit_generic(io, ds, meta)
            s = String(take!(io))
            @test occursin("  interface zzname\n", s)
            @test occursin("function zzname_(name,device)", s)
            @test occursin("      type(c_ptr),value :: name\n", s)
            @test occursin("    module procedure zzname_typed\n", s)
            @test !occursin("#if", s)               # no tier guard around it

            io = IOBuffer()
            emit_typed_body(io, [ds], meta)
            s = String(take!(io))
            @test occursin("function zzname_typed(name,device)", s)
            @test occursin("      character(kind=c_char,len=*),intent(in),target :: name\n", s)
            @test occursin("      integer(c_int) :: device\n", s)
            @test occursin("zzname_typed = zzname_(c_loc(name),device)", s)
            @test !occursin("c_null_char", s)      # zero-copy: the caller's NUL
            # A non-string c_ptr argument is untouched.
            @test string_args(FuncInfo("zzp", "void", true,
                     [ArgInfo("p", "type(c_ptr)", ", value", false)]), meta) == Set{String}()
        end
    end

    @testset "matrix wrappers (_full_rank / rank 2 / `always-c-ptr` pass-through)" begin
        # Needs a buffer followed by an `ld*` argument for emits_fullrank.
        matf = FuncInfo("zzgemv", "integer(c_int)", false,
            [ArgInfo("handle",   "type(c_ptr)",           ", value", false),
             ArgInfo("A",        "real(c_double)",        "(*)",     false),
             ArgInfo("lda",      "integer(c_int)",        ", value", false),
             ArgInfo("x",        "real(c_double)",        "(*)",     false),
             ArgInfo("myResult", "real(c_double)",        "(*)",     false)])
        meta = LibMeta(cptr_args = Dict("zzgemv" => Set(["myResult"])))

        @test arg_natural_rank(matf, meta, 2) == 2   # A, followed by lda
        @test arg_natural_rank(matf, meta, 4) == 1   # x, a plain vector
        # Strided batched: a batch stride adds a dimension, after ld* or inc*.
        sb = FuncInfo("zzgemv_strided_batched", "integer(c_int)", false,
            [ArgInfo("A", "real(c_double)", "(*)", false), ArgInfo("lda", "integer(c_int)", ", value", false),
             ArgInfo("stride_A", "integer(c_int64_t)", ", value", false),
             ArgInfo("x", "real(c_double)", "(*)", false), ArgInfo("incx", "integer(c_int)", ", value", false),
             ArgInfo("stridex", "integer(c_int64_t)", ", value", false),
             ArgInfo("r", "real(c_double)", "(*)", false), ArgInfo("stride_r", "integer(c_int64_t)", ", value", false)])
        # _full_rank keeps hipfort's ranks (the batch packed in the last dimension);
        # _strided_rank adds the batch dimension.
        @test [arg_natural_rank(sb, LibMeta(), i) for i in (1, 4, 7)] == [2, 1, 1]
        @test [arg_natural_rank(sb, LibMeta(), i; strides = true) for i in (1, 4, 7)] == [3, 2, 2]
        @test emits_fullrank(sb, LibMeta()) && emits_stridedrank(sb, LibMeta())
        @test emits_fullrank(matf, meta) && !emits_stridedrank(matf, meta)
        # The metadata imposes a rank: rotg_strided_batched's one scalar per batch.
        let m = LibMeta(dims = Dict("zzgemv_strided_batched" => Dict("r" => 1)))
            @test arg_natural_rank(sb, m, 7; strides = true) == 1
        end
        @test has_matrix_buffer(matf, meta) && emits_fullrank(matf, meta)

        io = IOBuffer()
        emit_rank_wrapper(io, matf, meta, 2; suffix="_full_rank", natural=true)
        s = String(take!(io))
        @test occursin("function zzgemv_full_rank(handle,A,lda,x,myResult)", s)
        @test occursin("real(c_double),target,dimension(:,:) :: A", s)  # matrix
        @test occursin("real(c_double),target,dimension(:) :: x", s)    # vector
        # The `always-c-ptr` argument is a scalar OUTPUT pointer: declared
        # type(c_ptr) and forwarded unchanged, never arrayified or c_loc'd.
        @test occursin("      type(c_ptr) :: myResult\n", s)
        @test occursin("zzgemv_(handle,c_loc(A),lda,c_loc(x),myResult)", s)

        # A uniform rank-2 overload (no `natural`): EVERY data buffer is
        # dimension(:,:), the pass-through still is not.
        io = IOBuffer()
        emit_rank_wrapper(io, matf, meta, 2)
        s = String(take!(io))
        @test occursin("function zzgemv_rank_2(handle,A,lda,x,myResult)", s)
        @test occursin("real(c_double),target,dimension(:,:) :: x", s)
        @test occursin("      type(c_ptr) :: myResult\n", s)

        # …and the generic actually lists the _full_rank specifics.
        io = IOBuffer()
        emit_generic(io, matf, meta)
        s = String(take!(io))
        @test occursin("zzgemv_full_rank", s)

        # A function whose ONLY buffer is a pass-through has no data array
        # to arrayify: rank_0 and rank_1 would be identical (ambiguous).
        pf = FuncInfo("zzdot", "integer(c_int)", false,
             [ArgInfo("myResult", "real(c_double)", "(*)", false)])
        pmeta = LibMeta(cptr_args = Dict("zzdot" => Set(["myResult"])))
        @test !func_has_buffer(pf, pmeta)
    end

    @testset "long-line wrapping" begin
        io = IOBuffer(); emit_bind_signature(io, "    function foo(a)", "bind(c, name=\"foo\")", "        ")
        @test !occursin("&", String(take!(io)))                       # short -> one line
        io = IOBuffer(); emit_bind_signature(io, "    function " * ("a"^120) * "(x)",
                                             "bind(c, name=\"x\")", "        ")
        @test occursin("&", String(take!(io)))                        # long -> continuation
    end

    @testset "enums + types emission" begin
        enums = [EnumInfo("hipblasStatus_t",
                          ["HIPBLAS_STATUS_SUCCESS" => Int64(0),
                           "HIPBLAS_STATUS_NOT_INITIALIZED" => Int64(1)])]
        io = IOBuffer(); emit_enum_decls(io, enums)
        s = String(take!(io))
        @test occursin("enum, bind(c)", s)
        @test occursin("enumerator :: HIPBLAS_STATUS_SUCCESS = 0", s)

        structs = [StructInfo("hipDeviceArch_t",
                              [FieldInfo("hasGlobalInt32Atomics", "integer(c_int)", "", "")], String[])]
        io = IOBuffer(); emit_type_decls(io, structs)
        s = String(take!(io))
        @test occursin("type, bind(c) :: hipDeviceArch_t", s)
        @test occursin("integer(c_int) :: hasGlobalInt32Atomics", s)
    end

    @testset "hip runtime families (memory families / auxiliary)" begin
        render(f) = (io = IOBuffer(); f(io); String(take!(io)))
        for (spec, body, tok) in (
            (hipmemcpy_spec,       hipmemcpy_body,       "interface hipMemcpy"),
            (hipmalloc_spec,       hipmalloc_body,       "interface hipMalloc"),
            (hiphostregister_spec, hiphostregister_body, "interface hipHostRegister"),
            (hip_auxiliary_spec,   nothing,              "interface hipGetDeviceProperties"))
            t = render(spec) * (body === nothing ? "" : render(body))
            @test occursin(tok, t)
            # Folded into `module hip`: the enums, types and hipMemcpy come by host
            # association, so iso_c_binding is the only module `use`d.
            @test all(m -> m.captures[1] == "iso_c_binding",
                      eachmatch(r"^\s*use(?:, intrinsic ::)?\s+(\w+)"m, t))
        end
        s = render(hipmemcpy_spec) * render(hipmemcpy_body)
        @test occursin("c_loc(", s) && occursin("hipMemcpy_r8", s)

        # int(size(x), c_size_t) evaluates size() in default integer and wraps
        # past 2^31 - 1, so byte counts use size(x, kind=c_size_t).
        @test occursin("nbytes = size(dest, kind=c_size_t) * 8_c_size_t", s)
        @test occursin("nbytes = int(1, c_size_t) * 8_c_size_t", s)        # rank 0
        m = render(hipmalloc_body)
        h = render(hiphostregister_body)
        for t in (s, m, h)
            @test !occursin("int(size(", t)
        end
        @test occursin("hipMalloc_(cptr, size(source, kind=c_size_t)*", m)
        @test occursin("hipHostRegister_(c_loc(hostPtr(1)), size(hostPtr, kind=c_size_t)*", h)

        # hipFree/hipHostFree pass the pointer itself, whatever its lower bounds.
        @test occursin("res = hipFree_(c_loc(ptr))", m)
        @test occursin("res = hipHostFree_(c_loc(ptr))", m)
        @test !occursin("c_loc(ptr(1", m)
        # A failed allocation leaves ptr unassociated: cptr starts null, and
        # c_f_pointer runs only on success.
        @test occursin("cptr = c_null_ptr\n    res = hipMalloc_(cptr, nbytes)\n    if (res /= 0) then\n      ptr => null()\n      return", m)
        @test !occursin("if (res == 0) res = hipMemcpy", m)
        # hipFree never takes c_loc of an unassociated pointer.
        @test occursin("if (associated(ptr)) then\n      res = hipFree_(c_loc(ptr))", m)
        @test occursin("else if (.not. guard) then\n      res = hipFree_(c_null_ptr)", m)
    end

    # A Set/Get helper as parsed from its header, and its generic with the typed
    # overloads blas_aux_procs adds.
    blas_aux_generic(name, naming) = begin
        v(n, t) = ArgInfo(n, t, ", value", false)
        f = FuncInfo(name, "integer(c_int)", false,
                     [v("rows", "integer(c_int)"), v("cols", "integer(c_int)"), v("elemSize", "integer(c_int)"),
                      v("A", "type(c_ptr)"), v("lda", "integer(c_int)"), v("B", "type(c_ptr)"),
                      v("ldb", "integer(c_int)"), v("stream", "type(c_ptr)")])
        io = IOBuffer(); emit_generic(io, f, LibMeta(extra_procs = blas_aux_procs(naming)))
        String(take!(io))
    end

    @testset "BLAS Set/Get generics (hipblas :camel + rocblas :snake)" begin
        d = blas_aux_procs(:camel)
        @test haskey(d, "hipblasSetVector") && haskey(d, "hipblasGetMatrixAsync")
        @test "hipblasSetVector_r8_rank_0" in d["hipblasSetVector"][1]
        @test "hipblasSetVector_r8_assumed_rank" in d["hipblasSetVector"][2]
        @test haskey(blas_aux_procs(:snake), "rocblas_set_vector")
        s = blas_aux_generic("hipblasGetMatrixAsync", :camel)
        @test occursin("interface hipblasGetMatrixAsync", s)
        @test occursin("bind(c, name=\"hipblasGetMatrixAsync\")", s)       # from the header
        @test occursin("hipblasGetMatrixAsync_c8_full_rank", s) && occursin("hipblasGetMatrixAsync_c8_assumed_rank", s)

        io = IOBuffer(); emit_blas_aux_impls(io, :camel, "HIPBLAS_STATUS_SUCCESS")
        s = String(take!(io))
        @test occursin("hipblasSetVector_", s) && occursin("c_loc(", s)

        @test occursin("interface rocblas_get_matrix_async", blas_aux_generic("rocblas_get_matrix_async", :snake))
    end

    @testset "no emitted line exceeds 132 columns" begin
        # The mini fixture is too small to overflow; the async BLAS assumed-rank
        # `module procedure` lists are the worst case.
        function assert_fits(label, s)
            bad = overlong_fortran_lines(s)
            for (i, n, l) in bad
                @info "line >$(FORTRAN_MAX_COLS) cols in $label" line=i cols=n text=l
            end
            @test isempty(bad)
        end
        for (nm, status) in [(:camel, "HIPBLAS_STATUS_SUCCESS"),
                             (:snake, "rocblas_status_success")]
            gname = nm === :camel ? "hipblasGetMatrixAsync" : "rocblas_get_matrix_async"
            assert_fits("blas_generics/$(nm)", blas_aux_generic(gname, nm))
            io = IOBuffer(); emit_blas_aux_impls(io, nm, status)
            assert_fits("blas_impls/$(nm)", String(take!(io)))
        end
        assert_fits("mini.expected.F90",
                    read(joinpath(@__DIR__, "fixtures", "mini.expected.F90"), String))
    end

    @testset "source-to-source golden (parse mini.h -> gen_files)" begin
        # The full parse + gen_files pipeline, compared against the committed
        # golden. Set ROCM_FORTRAN_REFRESH_GOLDEN to rewrite it when the output
        # changes on purpose.
        out, ir = gen_mini()
        funcs, enums, macros, aliases, structs =
            ir.funcs, ir.enums, ir.macros, ir.aliases, ir.structs

        @test length(funcs) == 9
        @test Set(e.name for e in enums)   == Set(["mini_status_t", "mini_op_t"])
        @test Set(s.name for s in structs) == Set(["mini_float_complex", "mini_double_complex", "mini_params_t"])
        @test length(macros) == 1 && macros[1].first == "MINI_VERSION" && macros[1].second == 42
        @test aliases["mini_dscal"] == "miniScale"   # dict is keyed target -> alias
        # An aliasable target, and one whose short name is itself an entry point.
        @test aliases["mini_set_mode_v2"] == "mini_set_mode"
        @test aliases["mini_reset"]       == "mini_destroy"
        # An inline function forwarding its parameters unchanged (hipChooseDevice in
        # newer HIP headers) is an alias; one that changes an argument is not.
        @test aliases["mini_choose_R0600"] == "mini_choose"
        @test !("mini_choose_next" in values(aliases))

        modtxt = read(joinpath(out, "mini.F90"), String)
        golden = joinpath(@__DIR__, "fixtures", "mini.expected.F90")
        haskey(ENV, "ROCM_FORTRAN_REFRESH_GOLDEN") && write(golden, modtxt)
        @test strip(modtxt) == strip(read(golden, String))

        # Semantic assertions, so a refreshed golden cannot enshrine a regression.

        # Versioned aliases (hipGetDevicePropertiesR0600): the short name is a generic
        # naming the target's specific, never a second interface on its symbol.
        @test occursin("  interface mini_set_mode\n    procedure mini_set_mode_v2_\n  end interface\n", modtxt)
        @test count("bind(c, name=\"mini_set_mode_v2\")", modtxt) == 1
        # A target with overloads: the short name lists its module procedures too
        # (mini_dscal has array overloads and a _typed form).
        @test occursin("  interface miniScale\n    procedure mini_dscal_\n", modtxt)
        @test occursin("module procedure mini_dscal_typed", split(modtxt, "interface miniScale")[2])
        @test count("bind(c, name=\"mini_dscal\")", modtxt) == 1
        @test occursin("  interface mini_choose\n    procedure mini_choose_R0600_\n  end interface\n", modtxt)
        @test count("bind(c, name=\"mini_choose_R0600\")", modtxt) == 1
        # An alias whose short name is a real entry point is skipped.
        @test count("function mini_destroy_(", modtxt) == 1
        @test count("bind(c, name=\"mini_reset\")", modtxt) == 1

        # The void routine.
        @test occursin("subroutine mini_record_(handle,x,tag) bind(c, name=\"mini_record\")", modtxt)
        @test occursin("    end subroutine\n", modtxt)                    # rank wrappers
        @test occursin("call mini_record_(handle,c_loc(x),tag)", modtxt)

        # The `scalar-host` scalar (fixtures/mini/mini.toml): a pointer in the
        # bind(C) specific, its Fortran type in the _typed form, listed unguarded.
        @test occursin("      type(c_ptr),value :: myInfo\n", modtxt)
        @test occursin("    module procedure mini_dscal_typed\n", modtxt)
        @test occursin("mini_dscal_typed = mini_dscal_(handle,n,x,tag,c_loc(myInfo))", modtxt)
    end

    @testset "type mapping on real cursors (pointer/elaborated branches)" begin
        hdr = joinpath(@__DIR__, "fixtures", "typemap.h")
        cfg = Dict("general" => Dict("name" => "tm"),
                   "library" => Dict("prefix" => "tm"),
                   "clang"   => Dict("defines" => String[], "extra_include_dirs" => String[]))
        args = make_clang_args(cfg, dirname(hdr))
        ctx  = create_context([hdr], args)
        tu   = ctx.trans_units[1]
        root = Clang.getTranslationUnitCursor(tu)
        funcs = GC.@preserve ctx tu collect_funcs(root, "tm")
        F = Dict(f.name => f for f in funcs)

        sc = F["tm_scalars"].args
        @test sc[1].ftype == "integer(c_size_t)"  && sc[1].suffix == ", value"   # size_t
        @test sc[2].ftype == "integer(c_int64_t)" && sc[2].suffix == ", value"   # int64_t (LLP64 guard)
        @test sc[3].ftype == "integer(c_int32_t)"                                # int32_t

        pt = F["tm_ptrs"].args
        @test pt[1].ftype == "integer(c_size_t)"  && pt[1].suffix == "(*)"       # size_t*
        @test pt[2].ftype == "integer(c_int64_t)" && pt[2].suffix == "(*)"       # int64_t*
        @test pt[3].ftype == "real(c_double)"     && pt[3].suffix == "(*)"       # double*
        @test pt[4].ftype == "type(c_ptr)"        && pt[4].suffix == ", value"   # char* -> c_ptr,value
        @test pt[5].ftype == "type(c_ptr)"        && pt[5].suffix == ""          # void** -> c_ptr by ref

        en = F["tm_enums"].args
        @test occursin("integer(kind(", en[1].ftype) && en[1].suffix == ", value"  # enum by value
        # enum* carries the kind of its POINTEE enum, not some other enum's.
        @test en[2].ftype == "integer(kind(TM_A))" && en[2].suffix == "(*)"

        @test occursin("tm_params", F["tm_struct"].args[1].ftype)                 # struct* -> derived type
        @test F["tm_funptr"].args[1].ftype == "type(c_funptr)"                    # function pointer
    end

    @testset "collect_funcs skip paths + batched rewrite (skips.h)" begin
        hdr = joinpath(@__DIR__, "fixtures", "skips.h")
        # Under C23 `int f();` means `(void)`, making the no-prototype case vacuous.
        cfg = Dict("general" => Dict("name" => "skips"),
                   "library" => Dict("prefix" => "skips"),
                   "clang"   => Dict("defines" => String[], "extra_include_dirs" => String[],
                                     "extra_args" => ["-std=gnu17"]))
        args = make_clang_args(cfg, dirname(hdr))
        @test "-std=gnu17" in args
        ctx  = create_context([hdr], args)
        tu   = ctx.trans_units[1]
        root = Clang.getTranslationUnitCursor(tu)
        funcs = GC.@preserve ctx tu collect_funcs(root, "skips")
        F = Dict(f.name => f for f in funcs)

        @test !haskey(F, "skips_log")       # variadic: no portable Fortran interface
        @test !haskey(F, "skips_inline")    # static inline: no symbol to bind against
        # Only the K&R one is CXType_FunctionNoProto, which
        # clang_isFunctionTypeVariadic also reports as variadic.
        @test haskey(F, "skips_start") && isempty(F["skips_start"].args)
        @test haskey(F, "skips_stop")  && isempty(F["skips_stop"].args)
        @test length(funcs) == 5

        # Both spellings of an array of pointers go by value, whatever the name.
        b = Dict(a.name => (a.ftype, a.suffix) for a in F["skips_sgemm_batched"].args)
        @test b["A"] == ("type(c_ptr)", ", value")   # T* const A[]
        @test b["B"] == ("type(c_ptr)", ", value")   # T* const*  (trmv/tpmv spelling)
        @test b["C"] == ("real(c_float)", "(*)")     # a plain data buffer is untouched
        @test b["n"] == ("integer(c_int)", ", value")
        p = Dict(a.name => (a.ftype, a.suffix) for a in F["skips_sgemm"].args)
        @test p["A"] == ("type(c_ptr)", ", value") && p["B"] == ("type(c_ptr)", ", value")
        # A plain T** is an output, by reference.
        @test only(F["skips_create"].args).suffix == ""
    end

    @testset "doc comments (doc_check.jl)" begin
        # @param entries: rocBLAS and hipSPARSE put the name on the next line;
        # a description ends at the next block command or a blank line.
        rb = """/*! @{
            @param[in]
            handle    [rocblas_handle]
                      handle to the library.
            @param[in, out]
            result
                      device pointer or host pointer to store the dot product.
                      Return value is 0.0 if n <= 0.

            Not part of a description.
            ********************************************************************/"""
        @test doc_params(rb) == ["handle" => "[rocblas_handle] handle to the library.",
                                 "result" => "device pointer or host pointer to store the dot product. Return value is 0.0 if n <= 0."]
        @test doc_params("/**\n * @param [out] bytes The size in bytes\n * @returns #hipSuccess\n */") ==
              ["bytes" => "The size in bytes"]
        @test doc_params("/*! \\param x scalar \\f\$\\alpha\\f\$.\n *  \\retval STATUS ok */") ==
              ["x" => "scalar \\f\$\\alpha\\f\$."]
        @test isempty(doc_params("/** \\brief no parameters */"))

        # The rules, first sentence first; in a sentence, the array phrases first.
        cls(d, n = "") = (r = doc_classify(d, n); r === nothing ? nothing : first(r))
        @test cls("device pointer or host pointer to scalar alpha.") == "scalar-pointer-mode"
        @test cls("scalar \\f\$\\alpha\\f\$.") == "scalar-pointer-mode"
        @test cls("pointer to the sine element, can be on the host or device.") == "scalar-pointer-mode"
        @test cls("Scalar on the GPU.") == "scalar-device"
        @test cls("pointer to a rocblas_int in device memory.") == "scalar-device"
        @test cls("the result, on the host.") == "scalar-host"
        @test cls("size in bytes of the buffer.") == "scalar-host"
        @test cls("Array of batch_count integers on the GPU.") == "buffer"
        @test cls("pointer to int. One for each batch, on the GPU.") == "buffer"
        @test cls("pointer storing vector x on the GPU.") == "buffer"
        @test cls("info, see below. Scalar on the GPU.") == "scalar-device"   # first matching sentence
        @test cls("Scalar on the GPU. An array of them.") == "scalar-device"
        @test cls("the handle.") === nothing
        # Tightened against the headers' prose:
        # the argument indexed in its own description is one value per entry,
        @test cls("pointer to a rocblas_int on the GPU. If info[l] = 0, success.", "info") == "buffer"
        @test cls("pointer to a rocblas_int on the GPU. If info[l] = 0, success.", "nev") == "scalar-device"
        # a count mentions the arrays it counts, "array flags" names a HIP array,
        @test cls("number of elements in the column indices and values arrays. Can be either host or device pointer.") ==
              "scalar-pointer-mode"
        @test cls("- Returns size of the array returned in dependencies_out.") === nothing
        @test cls("- Returned array flags") === nothing
        # a batch count is not one per batch entry, and a matrix on the GPU is a buffer.
        @test cls("batch_count of the sparse matrix.", "batch_count") === nothing
        @test cls("pointer to the scalar cosine of the rotation matrix, on the GPU.") == "buffer"

        # A block carries to following declarations that it mostly documents.
        docs = Dict{String,Dict{String,String}}()
        blk = function_docs!(docs, "f_s", "/** @param[in] n count. @param[out] r result. */", ["n", "r"], Pair{String,String}[])
        @test first.(blk) == ["n", "r"]
        blk = function_docs!(docs, "f_d", "", ["n", "r"], blk)
        @test docs["f_d"] == docs["f_s"]
        function_docs!(docs, "g", "", ["n", "a", "b"], blk)                 # 1 of 3 named
        @test !haskey(docs, "g")
        @test brace_key(["lib_sx", "lib_dx", "lib_dx_64"]) == "[\"lib_{dx,dx_64,sx}\"]"
        @test expand_braces("lib_{dx,dx_64,sx}") == ["lib_dx", "lib_dx_64", "lib_sx"]
        @test brace_key(["lib_x"]) == "lib_x"

        # On real cursors: libclang's raw comment, carried to the undocumented twin.
        hdr = joinpath(@__DIR__, "fixtures", "docs.h")
        cfg = Dict("general" => Dict("name" => "docs"), "library" => Dict("prefix" => "docs"),
                   "clang"   => Dict("defines" => String[], "extra_include_dirs" => String[]))
        ctx  = create_context([hdr], make_clang_args(cfg, dirname(hdr)))
        tu   = ctx.trans_units[1]
        funcs = GC.@preserve ctx tu collect_funcs(Clang.getTranslationUnitCursor(tu), "docs")
        D = FUNC_DOCS[]
        @test D["docs_sdot"]["result"] == "device pointer or host pointer to store the dot product."
        @test D["docs_ddot"] == D["docs_sdot"]
        @test D["docs_mem"] == Dict("bytes" => "The size in bytes")
        @test !haskey(D, "docs_other")

        # The check compares with the binding: the table, the signature defaults, or a buffer.
        withmeta(f, toml) = mktemp() do path, io
            write(io, toml); close(io); f(load_metadata(path))
        end
        withmeta("format = 1\n[\"docs_{s,d}dot\"]\nresult = \"scalar-host\"\n") do md
            out = @test_logs (:warn, r"2 argument\(s\) whose doc comment") check_metadata_docs(funcs, md)
            @test out == ["[\"docs_{s,d}dot\"] result: doc says scalar-pointer-mode, binding has scalar-host " *
                          "(\"device pointer or host pointer to store the dot product.\")",
                          "docs_mem bytes: doc says scalar-host, binding has buffer (\"The size in bytes\")"]
        end
        withmeta("format = 1\n[\"docs_{s,d}dot\"]\nresult = \"scalar-pointer-mode\"\n" *
                 "[docs_mem]\nbytes = \"scalar-host\"\n") do md
            @test isempty(@test_logs check_metadata_docs(funcs, md))
        end
        # Functions without a table are reported under one brace key; "on the GPU" in a
        # batched routine is not, nor an erratum.
        P(n) = ArgInfo(n, "integer(c_int)", "(*)", false, "int *")
        fs = [FuncInfo("lib_snev", "integer(c_int)", false, [P("nev")]),
              FuncInfo("lib_dnev", "integer(c_int)", false, [P("nev")]),
              FuncInfo("lib_snev_batched", "integer(c_int)", false,
                       [P("nev"), ArgInfo("batch_count", "integer(c_int)", ", value", false, "int")]),
              FuncInfo("rocsparse_bell_get", "integer(c_int)", false, [P("ell_cols")])]
        dd = Dict(f.name => Dict("nev" => "pointer to a rocblas_int on the GPU.") for f in fs[1:3])
        dd["rocsparse_bell_get"] = Dict("ell_cols" => "Must be an array of length rows.")
        withmeta("format = 1\n[rocsparse_bell_get]\nell_cols = \"scalar-host\"\n") do md
            @test check_metadata_docs(fs, md, dd) ==
                  ["[\"lib_{d,s}nev\"] nev: doc says scalar-device, binding has buffer (\"pointer to a rocblas_int on the GPU.\")"]
        end
    end

    @testset "metadata loaders + IR helpers" begin
        # refs_derived_type: true only when a real derived type (not c_ptr/c_funptr)
        @test refs_derived_type(FuncInfo("f", "integer(c_int)", false,
              [ArgInfo("p", "type(hipDeviceProp_t)", "", false)]))
        @test !refs_derived_type(FuncInfo("f", "integer(c_int)", false,
              [ArgInfo("p", "type(c_ptr)", ", value", false)]))
        @test refs_derived_type(FuncInfo("f", "type(someType_t)", false, ArgInfo[]))  # via return

        # Foreign enum kinds: a sibling's (rocBLAS's in rocSOLVER) is `use`d by name
        # from the sibling module, one narrow `use, only:` per sibling; a kind from
        # the HIP runtime is spelled integer(c_int), so the library does not need
        # `use hip`; the library's own kinds are kept.
        let meta = LibMeta(own_consts = Set(["OWN_C"]),
                           sibling_enum_mod = Dict("SIB_C" => "sib"))
            fe = FuncInfo("f", "integer(c_int)", false,
                 [ArgInfo("a", "integer(kind(SIB_C))", ", value", false),
                  ArgInfo("b", "integer(kind(UNK_C))", ", value", false),
                  ArgInfo("c", "integer(kind(OWN_C))", ", value", false),
                  ArgInfo("t", "type(sib_pair_t)",     "",        false)])
            g = only(neutralize_funcs([fe], meta))
            @test [a.ftype for a in g.args] == ["integer(kind(SIB_C))", "integer(c_int)",
                                                "integer(kind(OWN_C))", "type(sib_pair_t)"]
            @test sibling_module_uses([fe, fe], "zz", meta) == ["sib, only: SIB_C, sib_pair_t"]
            @test sibling_module_uses([fe], "zz", LibMeta()) == String[]   # no sibling
            # The check routine's status names come from the sibling too; own and
            # unknown names are not `use`d.
            @test sibling_module_uses([fe], "zz", meta; extra=["SIB_C", "OWN_C", "UNK_C"]) ==
                  ["sib, only: SIB_C, sib_pair_t"]
            let m2 = LibMeta(own_consts = meta.own_consts,
                             sibling_enum_mod = Dict("SIB_C" => "sib", "SIB_BAD" => "sib"))
                @test sibling_module_uses([fe], "zz", m2; extra=["SIB_BAD"]) ==
                      ["sib, only: SIB_BAD, SIB_C, sib_pair_t"]
            end
        end

        # Pointer-mode scalars are keyed off LibMeta.scalar_ptrs alone.
        let meta = LibMeta(scalar_ptrs = Dict("zzdev" => Set(["alpha"])))
            fdev = FuncInfo("zzdev", "integer(c_int)", false,
                            [ArgInfo("alpha", "real(c_double)", "", false)])
            fno  = FuncInfo("zzplain", "integer(c_int)", false,
                            [ArgInfo("alpha", "real(c_double)", "", false)])
            @test has_scalar_ptr(fdev, meta)
            @test !has_scalar_ptr(fno, meta)

            @test raw_arg(fdev, fdev.args[1], meta).ftype  == "type(c_ptr)"
            @test raw_arg(fdev, fdev.args[1], meta).suffix == ", value"
            @test raw_arg(fno,  fno.args[1], meta).ftype   == "real(c_double)"

            # A scalar entry makes a generic with a _typed module procedure and
            # no array wrapper.
            @test wants_typed(fdev, meta)
            @test !wants_typed(fno, meta)
            @test needs_typed([fdev], meta)
            @test !needs_wrappers([fdev], meta)
            # A pointer-mode scalar beside a host-only one: the device pointer
            # mode's own call, _devptr, keeps the first a pointer, types the second.
            let mmeta = LibMeta(scalar_ptrs = Dict("zzmix" => Set(["alpha", "bsize"])),
                                ptrmode     = Dict("zzmix" => Set(["alpha"])))
                fm = FuncInfo("zzmix", "integer(c_int)", false,
                              [ArgInfo("alpha", "real(c_double)",   "", false),
                               ArgInfo("bsize", "integer(c_size_t)", "", false)])
                @test wants_typed(fm, mmeta) && wants_devptr(fm, mmeta)
                # A pointer-mode scalar gives the array forms a _devptr twin too.
                @test wants_rank_devptr(fm, mmeta)
                io = IOBuffer()
                emit_typed_body(io, [fm], mmeta)
                s = String(take!(io))
                @test occursin("zzmix_typed = zzmix_(c_loc(alpha),c_loc(bsize))", s)
                @test occursin("function zzmix_devptr(alpha,bsize)", s)
                @test occursin("      type(c_ptr),value :: alpha\n", s)
                @test occursin("zzmix_devptr = zzmix_(alpha,c_loc(bsize))", s)
            end
            # A C `char` stays by value in the wrapper (gfortran forwards a
            # by-reference character(c_char) to a bind(C) value dummy as garbage).
            let fc = FuncInfo("zzchar", "integer(c_int)", false,
                              [ArgInfo("jobu", "character(c_char)", ", value", false),
                               ArgInfo("alpha", "real(c_double)", "", false)]),
                cmeta = LibMeta(scalar_ptrs = Dict("zzchar" => Set(["alpha"])))
                io = IOBuffer()
                emit_typed_body(io, [fc], cmeta)
                @test occursin("      character(c_char), value :: jobu\n", String(take!(io)))
                # Same for a type(c_funptr)/type(c_ptr): by reference, c_funloc(k)
                # becomes a .rodata temporary with an absolute address (DT_TEXTREL).
                fk = FuncInfo("zzchar", "integer(c_int)", false,
                              [ArgInfo("f", "type(c_funptr)", ", value", false),
                               ArgInfo("s", "type(c_ptr)", ", value", false),
                               ArgInfo("alpha", "real(c_double)", "", false)])
                emit_typed_body(io, [fk], cmeta)
                out = String(take!(io))
                @test occursin("      type(c_funptr), value :: f\n", out)
                @test occursin("      type(c_ptr), value :: s\n", out)
            end
            # A device-written scalar (`scalar-device`) keeps the pointer and gets no _typed;
            # the array overloads get a _devptr twin taking it as a pointer.
            let dmeta = LibMeta(scalar_ptrs = Dict("zzdev"    => Set(["alpha"]),
                                                   "zzdev_64" => Set(["alpha"])),
                                devonly     = Dict("zzdev" => Set(["alpha"])))
                @test !wants_typed(fdev, dmeta) && wants_rank_devptr(fdev, dmeta)
                # An ILP64 variant inherits its base routine's `scalar-device` entry.
                f64 = FuncInfo("zzdev_64", fdev.ret_ftype, fdev.is_void, fdev.args)
                @test devonly_args(f64, dmeta) == Set(["alpha"])
                @test !wants_typed(f64, dmeta) && wants_rank_devptr(f64, dmeta)
            end
        end

        # load_metadata + apply_argkinds: listed scalar pointers revert to by-ref;
        # _64 / _v2 variants inherit the base function's scalar set
        mktemp() do path, io
            # C argument names are normalized through safe_argname, the spelling
            # every consumer compares against.
            write(io, "# comment\nformat = 1\n\n" *
                      "[myfunc]\nalpha = \"scalar-pointer-mode\"\nbeta = \"scalar-host\"\nx = \"always-c-ptr\"\ngamma = \"scalar-device\"\n\n" *
                      "[hipFuncGetAttribute]\nvalue = \"scalar-host\"\n\n" *
                      "[hipGetSymbolSize]\nmySize = \"scalar-host\"\n"); close(io)
            md = load_metadata(path)
            @test md.scalar["myfunc"] == Set(["alpha", "beta", "gamma"])
            @test md.ptrmode["myfunc"] == Set(["alpha", "gamma"])          # device implies the c_ptr form
            @test md.devonly["myfunc"] == Set(["gamma"])
            @test md.cptr["myfunc"] == Set(["x"])
            @test md.scalar["hipFuncGetAttribute"] == Set(["myValue"])    # C spelling -> emitted name
            @test md.scalar["hipGetSymbolSize"]    == Set(["mySize"])     # already renamed: idempotent
            hf = FuncInfo("hipFuncGetAttribute", "integer(c_int)", false,
                 [ArgInfo("myValue", "integer(c_int)", "(*)", false)])
            @test first(apply_argkinds([hf], md))[1].args[1].suffix == ""
            f = FuncInfo("myfunc", "integer(c_int)", false,
                [ArgInfo("alpha", "real(c_double)", "(*)", false),
                 ArgInfo("x",     "real(c_double)", "(*)", false)])
            g, scalar_ptrs, _ = apply_argkinds([f], md)
            g = only(g)
            @test scalar_ptrs == Dict("myfunc" => Set(["alpha"]))
            @test g.args[1].suffix == "" && g.args[2].suffix == "(*)"      # alpha scalarized, x stays a buffer
            f64 = FuncInfo("myfunc_64", "integer(c_int)", false,
                  [ArgInfo("alpha", "real(c_double)", "(*)", false)])
            @test first(apply_argkinds([f64], md))[1].args[1].suffix == ""       # inherits base scalars
            # A _64 variant inherits its base routine's tables: here the opt-out.
            let g64 = FuncInfo("mat_64", "integer(c_int)", false,
                               [ArgInfo("A", "real(c_double)", "(*)", false), ArgInfo("lda", "integer(c_int64_t)", ", value", false)])
                @test wants_fullrank(g64, LibMeta()) && native_maxrank(g64, LibMeta()) == 1
                @test native_maxrank(g64, LibMeta(no_arrays_by = Dict("mat" => true))) == -1
                # An any-rank buffer: rank 0 to 3, and no _full_rank form.
                ar = LibMeta(dims = Dict("mat" => Dict("A" => ANY_RANK)))
                @test native_maxrank(g64, ar) == 3 && !wants_fullrank(g64, ar)
            end
            # A _spt variant takes the table of the same function without _spt, then
            # of the 32-bit one; a _v2 is a new API and inherits nothing.
            @test meta_get(Dict("f_v2" => 2, "f" => 1), "f_v2_spt", 0) == 2
            @test meta_get(Dict("f" => 1), "f_v2_spt", 0) == 0
            @test meta_get(Dict("f" => 1), "f_64_spt", 0) == 1
            @test meta_get(Dict("f" => 1), "f_v2", 0) == 0
        end

        # A kernel-written value of a batched routine is one per batch entry, a
        # buffer: scalar-device there stops the generation (hipSOLVER's and hipBLAS's
        # batched devInfo); host and pointer-mode scalars stay legitimate.
        let path = joinpath(mktempdir(), "b.toml")
            write(path, """
                format = 1
                [solveBatched]
                info = "scalar-host"
                devInfo = "scalar-device"
                [solve]
                devInfo = "scalar-device"
                [axpyBatched]
                alpha = "scalar-pointer-mode"
                """)
            md = load_metadata(path)
            p(n) = ArgInfo(n, "integer(c_int)", "(*)", false)
            bc = ArgInfo("batch_count", "integer(c_int)", ", value", false)
            ok = [FuncInfo("solve", "integer(c_int)", false, [p("devInfo")]),
                  FuncInfo("axpyBatched", "integer(c_int)", false, [p("alpha"), bc])]
            @test check_batched_device_scalars(ok, md) === nothing
            bad = FuncInfo("solveBatched_64", "integer(c_int)", false, [p("info"), p("devInfo"), bc])
            @test_throws r"solveBatched_64 devInfo" withenv(() -> check_batched_device_scalars([bad], md), "ROCM_FORTRAN_STRICT" => "1")
            # Without ROCM_FORTRAN_STRICT: a warning, and the entry is ignored for that function
            # only, so devInfo binds as a buffer there and stays scalar-device in solveBatched.
            @test_logs (:warn, r"solveBatched_64 devInfo") check_batched_device_scalars([bad], md)
            @test !("devInfo" in meta_get(md.devonly, "solveBatched_64", EMPTY_STRSET))
            @test "devInfo" in md.devonly["solveBatched"]
            @test "devInfo" in md.ignored["solveBatched_64"]
            @test is_batch_count("batchCount") && is_batch_count("batchSize") && !is_batch_count("stride")
        end
        # The same rule on the shipped metadata, by name since no headers are read here.
        for path in filter(isfile, [joinpath(@__DIR__, "..", lib, "metadata", "$(lib).toml")
                                    for lib in readdir(joinpath(@__DIR__, ".."))])
            md = load_metadata(path)
            bad = [k for (k, v) in md.devonly if occursin(r"(?i)batch(ed)?$", k) && !isempty(v)]
            @test isempty(bad)
        end

        # anonymous-enum spellings lose the absolute include path
        @test stable_enum_name("enum (unnamed at /opt/rocm/include/hip/hip_runtime_api.h:37:1)") ==
              "enum (unnamed at hip/hip_runtime_api.h:37:1)"
        @test stable_enum_name("enum (anonymous at /tmp/x/foo.h:3:1)") == "enum (anonymous at foo.h:3:1)"
        @test stable_enum_name("hipError_t") == "hipError_t"

        # revert_unknown_structs: pointers to non-emitted structs fall back to c_ptr
        let
            structs = [StructInfo("Known_t", FieldInfo[], String[])]
            f = FuncInfo("f", "integer(c_int)", false,
                [ArgInfo("a", "type(Known_t)",     "",        false),
                 ArgInfo("b", "type(Unk_t)",       "",        false),
                 ArgInfo("p", "type(c_ptr)",       ", value", false)])
            g = revert_unknown_structs([f], structs)[1]
            @test g.args[1].ftype == "type(Known_t)"                                  # emitted struct kept
            @test g.args[2].ftype == "type(c_ptr)" && g.args[2].suffix == ", value"   # unknown reverted
            @test g.args[3].ftype == "type(c_ptr)"                                    # already c_ptr
            # A struct returned by value has no pointer fallback: a c_ptr would break the ABI.
            # Strict, an error; otherwise a warning, and the function is left out.
            @test_throws ErrorException withenv(() -> revert_unknown_structs([FuncInfo("r", "type(Unk_t)", false, ArgInfo[])], structs),
                                                "ROCM_FORTRAN_STRICT" => "1")
            @test isempty(@test_logs (:warn, r"left out") revert_unknown_structs([FuncInfo("r", "type(Unk_t)", false, ArgInfo[])], structs))
        end

        # reset_generator_state!: one library's collectors never reach the next
        let
            BIND_NAMES[]["short"] = "long"; RECORD_ALIASES[]["t"] = "s"; record_unmapped_cptr!("foo *")
            reset_generator_state!()
            @test isempty(BIND_NAMES[]) && isempty(RECORD_ALIASES[]) && isempty(UNMAPPED_CPTR[])
        end

        # unmapped-c_ptr diagnostic
        let saved = UNMAPPED_CPTR[]
            reset_unmapped_cptr!()
            @test isempty(UNMAPPED_CPTR[]) && unmapped_cptr_summary() == String[]
            record_unmapped_cptr!("const foo_bar *")   # cleaned to "foo_bar"
            record_unmapped_cptr!("foo_bar")           # groups with the above
            record_unmapped_cptr!("baz_t")
            record_unmapped_cptr!("")                  # blank spelling -> <anonymous>
            @test UNMAPPED_CPTR[]["foo_bar"] == 2
            @test UNMAPPED_CPTR[]["<anonymous>"] == 1
            s = unmapped_cptr_summary()
            @test s[1] == "foo_bar ×2"                 # most frequent first
            @test "baz_t ×1" in s
            reset_unmapped_cptr!()
            @test isempty(UNMAPPED_CPTR[])
            UNMAPPED_CPTR[] = saved
        end
    end

    @testset "format.jl line formatting" begin
        io = IOBuffer(); println_wrapped(io, "short line"); s = String(take!(io))
        @test !occursin("&", s) && occursin("short line", s)              # fits -> one line
        io = IOBuffer(); println_wrapped(io, "call f(" * join(["arg$i" for i in 1:40], ", ") * ")")
        @test occursin("&", String(take!(io)))                            # long -> wrapped at comma
        io = IOBuffer(); println_wrapped(io, "x"^110 * ",y")              # break char only AFTER soft limit
        @test occursin("&", String(take!(io)))
        io = IOBuffer(); println_wrapped(io, "y"^140); s = String(take!(io))  # genuinely unbreakable
        @test !occursin("&", s) && occursin("y"^140, s)
        toks = ["é$i" for i in 1:60]                                      # non-ASCII: columns are characters
        io = IOBuffer(); println_wrapped(io, "call f(" * join(toks, ", ") * ")"); s = String(take!(io))
        ls = split(chomp(s), '\n')
        @test length(ls) > 1 && all(l -> length(l) <= FORTRAN_MAX_COL, ls)
        joined = join([replace(strip(l), r"\s*&$" => "") for l in ls], " ")
        @test split(joined, r"[\s,()]+"; keepempty=false) == ["call", "f", toks...]
    end

    @testset "argument overrides (nullable / struct-array / by-value / by-reference)" begin
        d = mktempdir()
        write(joinpath(d, "zz.toml"), """
            # comment
            format = 1
            [zz_solve]
            p_error = "nullable"
            [zz_get]
            status = "nullable"
            n = "nullable"
            [zz_guru]
            dims = "struct-array"
            rank = "struct-array"
            [zz_cb]
            cb_data = "by-value"
            [zz_exec]
            bufs = "by-reference"
            n = "by-reference"
            """)
        fs = [FuncInfo("zz_solve", "integer(c_int)", false,
                       [ArgInfo("h", "type(c_ptr)", ", value", false),
                        ArgInfo("p_error", "type(c_ptr)", "", false)]),
              FuncInfo("zz_solve_64_spt", "integer(c_int)", false,
                       [ArgInfo("h", "type(c_ptr)", ", value", false),
                        ArgInfo("p_error", "type(c_ptr)", "", false)]),
              FuncInfo("zz_get", "integer(c_int)", false,
                       [ArgInfo("status", "integer(kind(ZZ_OK))", "", false),
                        ArgInfo("n", "integer(c_int)", ", value", false)]),
              FuncInfo("zz_guru", "type(c_ptr)", false,
                       [ArgInfo("rank", "integer(c_int)", ", value", false),
                        ArgInfo("dims", "type(zz_iodim)", "", false)]),
              FuncInfo("zz_cb", "integer(c_int)", false,
                       [ArgInfo("cb_data", "type(c_ptr)", "", false)]),
              FuncInfo("zz_exec", "integer(c_int)", false,
                       [ArgInfo("bufs", "type(c_ptr)", ", value", false),
                        ArgInfo("n", "integer(c_int)", ", value", false)])]
        zz = load_metadata(joinpath(d, "zz.toml"))
        # A value that does not apply stops the generation; check_metadata_applies
        # catches it first, from the headers.
        withenv("ROCM_FORTRAN_STRICT" => "1") do
            @test_throws r"n \(nullable: not a pointer to one value or struct\)" apply_arg_overrides(fs, zz)
            @test_throws r"zz_guru rank = \"struct-array\" \(not a pointer to a struct\)" check_metadata_applies(fs, zz)
            @test_throws r"zz_exec n = \"by-reference\" \(not an array of pointers\)" check_metadata_applies(fs, zz)
        end
        # Without it, a warning and the value is ignored: n keeps its C passing.
        @test_logs (:warn, r"value\(s\) that do not apply, ignored") match_mode=:any apply_arg_overrides(fs, zz)
        zz = load_metadata(joinpath(d, "zz.toml"))
        fs = [f for f in fs if f.name != "zz_get"]
        fs = [f.name == "zz_guru" ? FuncInfo(f.name, f.ret_ftype, f.is_void, f.args[2:2]) :
              f.name == "zz_exec" ? FuncInfo(f.name, f.ret_ftype, f.is_void, f.args[1:1]) : f for f in fs]
        out = Dict(f.name => f for f in apply_arg_overrides(fs, zz))
        @test out["zz_solve"].args[2].suffix == ", optional"
        @test out["zz_solve_64_spt"].args[2].suffix == ", optional"   # a variant inherits the table
        @test out["zz_guru"].args[1].suffix  == "(*)"            # derived-type array
        @test out["zz_cb"].args[1].suffix    == ", value"
        @test out["zz_exec"].args[1].suffix  == ""               # by-reference: array of pointers
        # A derived-type array is not a data buffer: the bind(C) specific keeps its
        # type and shape instead of turning it into an opaque type(c_ptr), value.
        @test !is_buffer(out["zz_guru"].args[1])
        @test raw_arg(out["zz_guru"].args[1]).suffix == "(*)"
        io = IOBuffer(); emit_generic(io, out["zz_guru"], LibMeta()); s = String(take!(io))
        @test occursin("type(zz_iodim) :: dims(*)", s)
        # A nullable by-reference argument: the bind(C) specific takes its address
        # (OPTIONAL in a bind(C) interface is Fortran 2018), and the _opt module
        # procedure takes it OPTIONAL and forwards c_null_ptr if absent.
        nometa = LibMeta()
        io = IOBuffer(); emit_generic(io, out["zz_solve"], nometa)
        s = String(take!(io))
        @test occursin("type(c_ptr),value :: p_error", s)
        @test !occursin("optional", s)
        @test wants_opt(out["zz_solve"], nometa)
        io = IOBuffer()
        emit_typed_body(io, [out["zz_solve"]], nometa)
        s = String(take!(io))
        @test occursin("function zz_solve_opt(h,p_error)", s)
        @test occursin("      type(c_ptr),optional,target :: p_error\n", s)
        @test occursin("if (present(p_error)) p_error__p = c_loc(p_error)", s)
        @test occursin("zz_solve_opt = zz_solve_(h,p_error__p)", s)
        # The generic lists _opt instead of the bind(C) specific (same arguments).
        io = IOBuffer()
        emit_generic(io, out["zz_solve"], nometa)
        s = String(take!(io))
        @test occursin("  interface\n", s) && occursin("  interface zz_solve\n", s)
        @test occursin("module procedure zz_solve_opt", s)
        @test !occursin("optional", s)
    end

    @testset "clang_args.jl (config-driven)" begin
        fx      = joinpath(@__DIR__, "fixtures")
        featdir = joinpath(fx, "featlib")

        # auto_feature_defines: resolve #cmakedefine flags against CMake defaults
        defs = auto_feature_defines(featdir)
        @test Set(defs) == Set(["FEATLIB_WITH_FOO",     # direct option ON
                                "FEATLIB_WITH_BAR",     # set(...${ENABLE_BAR}) -> ON
                                "FEATLIB_WITH_BUILD"])  # BUILD_WITH_ variant ON
        @test auto_feature_defines(mktempdir()) == String[]        # no *-version.h.in

        # cmake_version_vars: a version from rocm_setup_version + math(EXPR), and one
        # from a VERSION file, read by file(READ) and parsed by a string(REGEX) it
        # stands in for (rocprofiler-sdk).
        vars = cmake_version_vars(read(joinpath(fx, "verlib", "CMakeLists.txt"), String))
        @test vars["VerLib_VERSION_MAJOR"] == "5" && vars["verlib_VERSION_PATCH"] == "7"
        @test vars["verlib_VERSION_NUMBER"] == "500207"          # math(EXPR) evaluated
        vars = cmake_version_vars("""
            file(READ "\${CMAKE_CURRENT_SOURCE_DIR}/VERSION" FULL_VERSION_STRING LIMIT_COUNT 1)
            project(sdk VERSION \${SDK_VERSION})
            """, "1.4.2")
        @test vars["FULL_VERSION_STRING"] == "1.4.2"
        @test vars["PROJECT_VERSION_MAJOR"] == "1" && vars["PROJECT_VERSION_PATCH"] == "2"

        # synth_generated_headers: a source checkout lacks the headers its build
        # generates; those the parsed header includes are synthesized.
        let inc    = joinpath(fx, "verlib", "library", "include"),
            hipinc = joinpath(fx, "rocm-systems", "projects", "hip", "include"),
            hdr    = joinpath(inc, "verlib", "verlib.h")
            gen = synth_generated_headers([hdr], [inc, hipinc])
            @test gen !== nothing
            for rel in ("verlib/verlib_version.h", "verlib_version.h")  # included path and bare
                h = read(joinpath(gen, rel), String)
                @test occursin("#define VERLIB_VERSION 500207", h)
                @test occursin("#define VERLIB_VERSION_MAJOR 5", h)
                @test !occursin("VERLIB_VERSION_TWEAK", h)    # unresolved: dropped
                @test !occursin("VERLIB_COMMIT_ID", h)        # ${GIT_HASH_...}: dropped
                @test occursin("/* #cmakedefine VERLIB_WITH_FOO */", h)  # left to -D
            end
            for rel in ("verlib/verlib-config.h", "verlib-config.h")    # found by name
                h = read(joinpath(gen, rel), String)
                @test occursin("/* #cmakedefine VERLIB_WITH_BAR */", h)
                @test occursin("#define VERLIB_HAS_CONFIG 1", h)
            end
            for rel in ("internal/verlib-export.h", "verlib-export.h")
                h = read(joinpath(gen, rel), String)
                for m in ("EXPORT", "NO_EXPORT", "DEPRECATED", "DEPRECATED_EXPORT", "DEPRECATED_NO_EXPORT")
                    @test occursin("#define VERLIB_$(m)\n", h)
                end
            end
            h = read(joinpath(gen, "hip", "hip_version.h"), String)   # from hip/../VERSION
            for d in ("HIP_VERSION_MAJOR 7", "HIP_VERSION_MINOR 17", "HIP_VERSION_PATCH 0",
                      "HIP_VERSION_GITHASH \"\"", "HIP_VERSION_BUILD_ID 0", "HIP_VERSION_BUILD_NAME \"\"",
                      "HIP_VERSION    (HIP_VERSION_MAJOR * 10000000 + HIP_VERSION_MINOR * 100000 + HIP_VERSION_PATCH)")
                @test occursin("#define $(d)\n", h)
            end
            @test !ispath(joinpath(gen, "stdint.h"))                    # not ours to make
            # Only what is missing: nothing once the generated headers are found.
            @test synth_generated_headers([hdr], [inc, hipinc, gen]) === nothing
            @test synth_generated_headers(String[], String[]) === nothing

            # The source-mode parse: ROCM_SYSTEMS adds the HIP include dirs and
            # parse_checked synthesizes the rest; Clang reports no error.
            args = withenv("ROCM_SYSTEMS" => joinpath(fx, "rocm-systems")) do
                make_clang_args(Dict("general" => Dict("name" => "verlib")), inc)
            end
            @test "-I$(hipinc)" in args
            ctx, tu = parse_checked([hdr], args)
            root = Clang.getTranslationUnitCursor(tu)
            macros = Dict(GC.@preserve ctx tu collect_macros(root; own = ["verlib"]))
            @test macros["VERLIB_VERSION"] == 500207 && macros["VERLIB_HAS_CONFIG"] == 1
        end

        # parse_checked: any Clang error fails the parse, a missing header included.
        let hdr = joinpath(fx, "broken.h")
            args = make_clang_args(Dict("general" => Dict("name" => "broken")), dirname(hdr))
            err = try parse_checked([hdr], args); nothing catch e; e end
            @test err isa ErrorException && err.msg == "2 Clang error(s) parsing the headers"
        end
        @test parse_checked([MINI_HDR], make_clang_args(MINI_CFG, dirname(MINI_HDR)))[2] isa Clang.TranslationUnit

        # make_clang_args: extra include dirs / defines / feature -D / extra args
        cfg = Dict("general" => Dict("name" => "featlib"),
                   "clang"   => Dict("extra_include_dirs" => [featdir, "/does/not/exist"],
                                     "defines"            => ["MYDEF=1"],
                                     "extra_args"         => ["-include", "stddef.h"]))
        args = make_clang_args(cfg, featdir)
        @test "-I$(featdir)" in args                          # existing extra dir added
        @test !any(a -> occursin("/does/not/exist", a), args) # missing dir skipped
        @test "-DMYDEF=1" in args
        @test "-include" in args && "stddef.h" in args
        @test "-DFEATLIB_WITH_FOO" in args                    # auto feature -D
        @test "-DFEATLIB_EXPORT=" in args

        # find_headers: <subdir>/<file> (installed, nested) then <file> (flat monorepo)
        inc = joinpath(fx, "verlib", "library", "include")
        @test only(find_headers(Dict("general" => Dict("name" => "verlib")), inc)) ==
              joinpath(inc, "verlib", "verlib.h")                           # nested
        flat = find_headers(Dict("general" => Dict("name" => "typemap")), fx)
        @test only(flat) == joinpath(fx, "typemap.h")                       # no typemap/ dir: flat
        named = find_headers(Dict("general" => Dict("name" => "x"),
                                  "headers" => Dict("subdir" => "nope", "file" => "mini.h")), fx)
        @test only(named) == joinpath(fx, "mini.h")
        @test_throws ErrorException find_headers(Dict("general" => Dict("name" => "nope")), fx)
    end

    @testset "header sources (generate_all.jl selection)" begin
        tmp = mktempdir()
        libs, sys, inst, out = (joinpath(tmp, d) for d in ("libs", "sys", "inst", "out"))
        for p in ("rocblas", "hipfft", "hipsolver")
            mkpath(joinpath(libs, "projects", p, "library", "include"))
        end
        mkpath(joinpath(sys, "projects", "hip", "include"))
        mkpath(joinpath(sys, "projects", "rocprofiler-sdk", "source", "include"))
        write(joinpath(sys, "projects", "hip", "VERSION"),
              "#HIP_VERSION_MAJOR\n7\n#HIP_VERSION_MINOR\n17\n#HIP_VERSION_PATCH\n3\n")
        mkpath(joinpath(inst, "hip")); mkpath(joinpath(inst, "rocblas"))
        write(joinpath(inst, "hip", "hip_version.h"),
              "#define HIP_VERSION_MAJOR 7\n#define HIP_VERSION_MINOR 16\n#define HIP_VERSION_PATCH 26385\n")
        math = filter(l -> repo_of(l) == "rocm-libraries", LIBS)
        @test length(math) == 11 && filter(l -> repo_of(l) == "rocm-systems", LIBS) == ["hip", "roctx"]
        @test repo_of("hipfftw") == "rocm-libraries" && proj_of("hipfftw") == "hipfft"

        # Neither checkout: every library, from the installed dir.
        s, rest = header_sources(Dict{String,String}(), [inst, out])
        @test rest == [out] && selected_libs(s) == LIBS && !from_checkouts(s)
        @test lib_include(s, "rocblas") == inst && lib_include(s, "rocsolver") === nothing
        @test hip_installed_include(s) == "" && hip_version(s) == "7.16.26385"
        @test describe_sources(s) == "installed $inst"

        # ROCM_SYSTEMS alone: hip and roctx from the checkout; no include dir is read.
        s, rest = header_sources(Dict("ROCM_SYSTEMS" => sys), [out])
        @test rest == [out] && selected_libs(s) == ["hip", "roctx"] && s.installed == ""
        @test lib_include(s, "hip") == joinpath(sys, "projects", "hip", "include")
        @test lib_include(s, "roctx") == joinpath(sys, "projects", "rocprofiler-sdk", "source", "include")
        @test hip_installed_include(s) == "" && hip_version(s) == "7.17.3"
        @test_throws ArgumentError header_sources(Dict("ROCM_SYSTEMS" => sys), [inst, out])

        # ROCM_LIBRARIES alone: the math libraries from the checkout, HIP from the
        # installed dir, which must hold it.
        s, rest = header_sources(Dict("ROCM_LIBRARIES" => libs), [inst, out])
        @test rest == [out] && selected_libs(s) == math
        @test lib_include(s, "hipfftw") == joinpath(libs, "projects", "hipfft", "library", "include")
        @test lib_include(s, "rocsparse") === nothing    # a missing project fails the run
        @test hip_installed_include(s) == inst && hip_version(s) == "7.16.26385"
        @test describe_sources(s) == "rocm-libraries checkout $libs, HIP headers from installed $inst"
        @test_throws ArgumentError header_sources(Dict("ROCM_LIBRARIES" => libs), [libs, out])

        # Both: every library from the checkouts, nothing installed.
        s, rest = header_sources(Dict("ROCM_LIBRARIES" => libs, "ROCM_SYSTEMS" => sys), String[])
        @test isempty(rest) && selected_libs(s) == LIBS && s.installed == ""
        @test lib_include(s, "rocblas") == joinpath(libs, "projects", "rocblas", "library", "include")
        @test hip_installed_include(s) == "" && hip_version(s) == "7.17.3"

        # Metadata: a checkout's projects/<proj>/fortran/metadata/ replaces src/<lib>/metadata/.
        gen_meta(lib) = joinpath(GEN_ROOT, lib, "metadata")
        mkpath(joinpath(libs, "projects", "hipfft", "fortran", "metadata"))
        mkpath(joinpath(sys, "projects", "fortran", "metadata"))
        @test lib_metadata(s, "hipfft")  == joinpath(libs, "projects", "hipfft", "fortran", "metadata")
        @test lib_metadata(s, "hipfftw") == joinpath(libs, "projects", "hipfft", "fortran", "metadata")
        @test lib_metadata(s, "roctx")   == joinpath(sys, "projects", "fortran", "metadata")
        @test lib_metadata(s, "hip")     == joinpath(sys, "projects", "fortran", "metadata")
        @test lib_metadata(s, "rocblas") == gen_meta("rocblas")   # no metadata in the checkout
        let (si, _) = header_sources(Dict{String,String}(), [inst, out])
            @test lib_metadata(si, "hipfft") == gen_meta("hipfft")   # installed: never a checkout
        end

        # generate_all.jl options: --libs narrows the run to some libraries, and
        # --overwrite writes into the checkout's fortran/ directory, which must exist.
        @test run_options(["--libs=rocblas,hipfftw", "--overwrite", inst, out]) ==
              (["rocblas", "hipfftw"], true, [inst, out])
        @test run_options([out]) == (nothing, false, [out])
        @test_throws ArgumentError run_options(["--foo"])
        @test_throws ArgumentError run_options(["--libs="])
        let (sl, _) = header_sources(Dict("ROCM_LIBRARIES" => libs), [inst, out])
            @test run_libs(sl, nothing) == math
            @test run_libs(sl, ["hipfftw", "rocblas"]) == ["rocblas", "hipfftw"]   # in LIBS order
            @test_throws ArgumentError run_libs(sl, ["rocblass"])   # not a library
            @test_throws ArgumentError run_libs(sl, ["hip"])        # rocm-systems is not read
            @test overwrite_target(sl, "hipfftw") ==
                  joinpath(libs, "projects", "hipfft", "fortran", "hipfftw.F90")
            @test_throws ArgumentError check_overwrite(sl, ["rocblas"])   # no rocblas/fortran/ yet
            mkpath(joinpath(libs, "projects", "rocblas", "fortran"))
            @test check_overwrite(sl, ["rocblas", "hipfftw"]) === nothing
        end
        @test overwrite_target(s, "roctx") == joinpath(sys, "projects", "fortran", "roctx.F90")
        let (si, _) = header_sources(Dict{String,String}(), [inst, out])
            @test_throws ArgumentError check_overwrite(si, ["rocblas"])   # installed: no checkout
        end

        @test_throws ArgumentError header_sources(Dict("ROCM_SYSTEMS" => inst), String[])   # no projects/
        @test_throws ArgumentError header_sources(Dict{String,String}(), [joinpath(tmp, "nope")])
        @test_throws ArgumentError header_sources(Dict{String,String}(), [libs, out])   # no hip/: not ROCm
        @test_throws ArgumentError header_sources(Dict{String,String}(), [inst, out, out])

        # ROCM_FORTRAN_HIP_INCLUDE: only the installed hip/ is visible, searched last and
        # hidden from the synthesis, so its stale copies of the checkout's generated
        # headers lose.
        fx  = joinpath(@__DIR__, "fixtures")
        inc = joinpath(fx, "verlib", "library", "include")
        hdr = joinpath(inc, "verlib", "verlib.h")
        mkpath(joinpath(inst, "verlib")); mkpath(joinpath(inst, "internal"))
        write(joinpath(inst, "hip", "hip_runtime_api.h"), "#include <hip/hip_version.h>\n")
        write(joinpath(inst, "verlib", "verlib_version.h"), "#define VERLIB_VERSION 1\n")
        write(joinpath(inst, "verlib", "verlib-config.h"), "#define VERLIB_HAS_CONFIG 0\n")
        write(joinpath(inst, "internal", "verlib-export.h"), "#error stale export header\n")
        withenv("ROCM_SYSTEMS" => nothing, "ROCM_FORTRAN_HIP_INCLUDE" => inst) do
            args = make_clang_args(Dict("general" => Dict("name" => "verlib")), inc)
            ctx, tu = parse_checked([hdr], args)
            incs = [a[3:end] for a in args if startswith(a, "-I")]
            @test incs[1] == inc && readdir(incs[end]) == ["hip"]
            @test realpath(joinpath(incs[end], "hip")) == realpath(joinpath(inst, "hip"))
            root = Clang.getTranslationUnitCursor(tu)
            macros = Dict(GC.@preserve ctx tu collect_macros(root; own = ["verlib"]))
            @test macros["VERLIB_VERSION"] == 500207 && macros["VERLIB_HAS_CONFIG"] == 1

            # A checkout that cannot synthesize its version header fails, rather than
            # reading the installed one.
            co = joinpath(tmp, "verlib-co")
            cp(joinpath(fx, "verlib"), co)
            coinc = joinpath(co, "library", "include")
            rm(joinpath(coinc, "verlib", "verlib_version.h.in"))
            args = make_clang_args(Dict("general" => Dict("name" => "verlib")), coinc)
            @test_throws ErrorException parse_checked([joinpath(coinc, "verlib", "verlib.h")], args)
        end
    end

    @testset "gen_files metadata helpers + rename/no-success paths" begin
        # Brace expansion: every name of a key gets the table; a name in two keys is
        # an error; a variant's own table replaces its base's entirely.
        @test expand_braces("rocblas_{s,d}dot{,_64}") ==
              ["rocblas_sdot", "rocblas_sdot_64", "rocblas_ddot", "rocblas_ddot_64"]
        for k in ("x{a", "x}a", "x{a{b,c}}", "x{a}")
            @test_throws ArgumentError expand_braces(k)
        end
        mktemp() do path, io
            write(io, """
                format = 1
                ["lib_{s,d}dot"]
                r = "always-c-ptr"
                [lib_ddot_64]
                r = "1d"
                """); close(io)
            md = load_metadata(path)
            @test md.origin["lib_sdot"] == "lib_{s,d}dot" && md.cptr["lib_ddot"] == Set(["r"])
            @test meta_get(md.cptr, "lib_sdot_64", nothing) == Set(["r"])      # inherited whole
            @test isempty(meta_get(md.cptr, "lib_ddot_64", nothing))            # replaced whole
            @test applying_table(md, "lib_sdot_64")[1] == "lib_sdot"
        end
        for dup in ("format = 1\n[\"f{a,b}\"]\nx = \"1d\"\n[fa]\nx = \"2d\"\n",
                    "format = 1\n[\"f{a,a}\"]\nx = \"1d\"\n",
                    "format = 1\n[\"f{a,b-c}\"]\nx = \"1d\"\n")
            mktemp() do path, io
                write(io, dup); close(io)
                @test_throws ErrorException load_metadata(path)
            end
        end

        # Imposed ranks and the opt-out.
        mktemp() do path, io
            write(io, "format = 1\n[foo]\nx = \"1d\"\ny = \"3d\"\n[bar]\nz = \"any-rank\"\n[baz]\nfortran-arrays = false\n"); close(io)
            md = load_metadata(path)
            @test md.dims["foo"] == Dict("x" => 1, "y" => 3) && md.dims["bar"]["z"] == ANY_RANK
            @test md.no_arrays == Set(["baz"])
            # The opt-out applies to the function's variants, not to the others.
            nm = LibMeta(no_arrays_by = Dict(fn => fn in md.no_arrays for fn in keys(md.tables)))
            mk(n) = FuncInfo(n, "integer(c_int)", false, [ArgInfo("x", "real(c_double)", "(*)", false)])
            @test withheld(mk("baz_64"), nm) && !withheld(mk("foo_64"), nm)
        end
        let md = load_metadata(joinpath(@__DIR__, "nope.toml"))
            @test isempty(md.dims) && isempty(md.scalar) && isempty(md.no_arrays)
        end
        # An empty file, or one with only comments, is no metadata either.
        for content in ("", "# nothing to say yet\n")
            mktemp() do path, io
                write(io, content); close(io)
                md = load_metadata(path)
                @test isempty(md.dims) && isempty(md.scalar) && isempty(md.optional)
            end
        end
        # A malformed file is an error, never ignored.
        for bad in ("[f]\nx = \"scalar-host\"\n",                                  # no format
                    "format = 2\n",                                                   # unknown format
                    "format = 1\n[f]\nx = \"scalar\"\n",                            # unknown value
                    "format = 1\n[f]\nx = [\"scalar-host\", \"scalar-device\"]\n",  # two kinds
                    "format = 1\n[f]\nx = [\"by-value\", \"by-reference\"]\n",      # two passings
                    "format = 1\n[f]\nx = [\"1d\", \"2d\"]\n",                      # two ranks
                    "format = 1\n[f]\nfortran-arrays = true\n",                      # only false
                    "format = 1\n[f]\nx = [\"scalar-host\", \"always-c-ptr\"]\n",   # a scalar is not a buffer
                    "format = 1\n[\"*\"]\nx = \"nullable\"\n",                      # not a function name
                    "format = 1\n[f]\nx = [\"by-value\", \"nullable\"]\n",         # nullable would be ignored
                    "format = 1\n[f]\nx = [\"function-pointer\", \"1d\"]\n",       # takes no other value
                    "format = 1\n[f]\nx = [\"struct-array\", \"nullable\"]\n",
                    "format = 1\n[f]\nx = [\"scalar-host\", \"1d\"]\n",            # a rank is a buffer's
                    "format = 1\n[f]\nx = [\"always-c-ptr\", \"2d\"]\n",
                    "format = 1\n[f]\nx = [\"scalar-device\", \"nullable\"]\n",    # no form takes it typed
                    "format = 1\n[f]\nx = [\"scalar-host\", \"devptr\"]\n")       # devptr is a buffer's
            mktemp() do path, io
                write(io, bad); close(io)
                @test_throws ErrorException load_metadata(path)
            end
        end
        # Errors name the key as written, braces included.
        mktemp() do path, io
            write(io, "format = 1\n[\"lib_{s,d}dot\"]\nr = [\"by-value\", \"nullable\"]\n"); close(io)
            @test_throws r"\[\"lib_\{s,d\}dot\"\] r" load_metadata(path)
        end
        # A value that does not apply to the C argument it names stops the generation:
        # the generator would ignore it.
        mktemp() do path, io
            write(io, """
                format = 1
                [lib_f]
                h = "always-c-ptr"
                n = "scalar-host"
                x = "1d"
                r = ["scalar-host", "nullable"]
                """); close(io)
            md = load_metadata(path)
            f(args...) = FuncInfo("lib_f_64", "integer(c_int)", false, collect(ArgInfo, args))
            h  = ArgInfo("h", "type(c_ptr)", ", value", false)          # a handle
            n  = ArgInfo("n", "integer(c_int)", ", value", false)
            x  = ArgInfo("x", "real(c_double)", "(*)", false)
            r  = ArgInfo("r", "real(c_double)", "(*)", false)
            hx = ArgInfo("h", "real(c_double)", "(*)", false)
            nx = ArgInfo("n", "integer(c_int)", "(*)", false)
            @test check_metadata_applies([f(hx, nx, x, r)], md) === nothing
            withenv("ROCM_FORTRAN_STRICT" => "1") do
                @test_throws r"lib_f_64 h = \"always-c-ptr\" \(not a data buffer" check_metadata_applies([f(h, nx, x, r)], load_metadata(path))
                @test_throws r"lib_f_64 n = \"scalar-host\" \(not a pointer to a value" check_metadata_applies([f(hx, n, x, r)], load_metadata(path))
            end
            # Without it (a header that changed): a warning, and the entry is ignored for
            # lib_f_64 only; lib_f keeps it, and lib_f_64's n binds by its C declaration.
            @test_logs (:warn, r"lib_f_64 n = \"scalar-host\"") check_metadata_applies([f(hx, n, x, r)], md)
            @test !("n" in meta_get(md.scalar, "lib_f_64", EMPTY_STRSET)) && "n" in md.scalar["lib_f"]
            @test !("n" in named_args(md, f(hx, n, x, r))) && "x" in named_args(md, f(hx, n, x, r))
        end
        # Defaults from the C signature, for the arguments a table does not name.
        let A(n, ft, suf, ct) = ArgInfo(n, ft, suf, false, ct),
            h   = A("handle", "type(c_ptr)", ", value", "lib_handle"),
            int(n) = A(n, "integer(c_int)", "(*)", "int *"),
            sz(n)  = A(n, "integer(c_size_t)", "(*)", "size_t *"),
            F(n, args...) = FuncInfo(n, "integer(c_int)", false, collect(ArgInfo, args)),
            rules = DefaultRules(pointer_mode = true, solver_handles = Set(["lib_handle"]))
            # a size query: its last integer output, and every size_t output
            @test signature_defaults(F("lib_getrs_bufferSize", h, int("ipiv"), int("lwork")), rules) ==
                  Dict("lwork" => ("scalar-host", "size query: its last integer output"))
            @test keys(signature_defaults(F("lib_x_buffer_size", h, sz("a"), sz("b")), rules)) == Set(["a", "b"])
            # a getter, unless a by-value integer indexes into something
            e = A("base", "integer(kind(LIB_ZERO))", "(*)", "lib_index_base *")
            @test keys(signature_defaults(F("lib_get_size", h, int("rows"), e), rules)) == Set(["rows", "base"])
            @test isempty(signature_defaults(F("lib_get_values", h, A("i", "integer(c_int)", ", value", "int"), int("v")), rules))
            # a solver routine's last integer output (info, emitted myInfo); a buffer when batched
            x = A("A", "real(c_double)", "(*)", "double *")
            @test signature_defaults(F("lib_getrf", h, x, int("ipiv"), int("myInfo")), rules) ==
                  Dict("myInfo" => ("scalar-device", "solver: its last integer output, the info the kernel writes"))
            @test signature_defaults(F("lib_getrf_batched", h, x, int("myInfo"),
                                       A("batch_count", "integer(c_int)", ", value", "int")), rules) ==
                  Dict("myInfo" => ("devptr", "solver: its last integer output, one info per batch entry, a buffer"))
            # pointer mode: a const alpha or beta, not an output
            @test keys(signature_defaults(F("lib_axpy", h, A("alpha", "real(c_double)", "(*)", "const double *"),
                                            A("beta", "real(c_double)", "(*)", "double *")), rules)) == Set(["alpha"])
            @test isempty(signature_defaults(F("lib_axpy", h, A("alpha", "real(c_double)", "(*)", "const double *")),
                                             DefaultRules()))
            # An entry wins (`buffer` keeps a data buffer); one equal to the default is reported.
            mktemp() do path, io
                write(io, "format = 1\n[lib_getrf]\ninfo = \"buffer\"\n[lib_potrf]\ninfo = \"scalar-device\"\n"); close(io)
                md = load_metadata(path)
                fs = [F("lib_getrf", h, x, int("myInfo")), F("lib_potrf", h, x, int("myInfo")), F("lib_trtri", h, x, int("myInfo"))]
                @test_logs (:warn, r"1 entr\(y/ies\) only repeat") match_mode=:any apply_signature_defaults!(md, fs, rules)
                @test isempty(meta_get(md.devonly, "lib_getrf", EMPTY_STRSET))
                @test meta_get(md.devonly, "lib_trtri", EMPTY_STRSET) == Set(["myInfo"])
                @test meta_get(md.scalar, "lib_trtri", EMPTY_STRSET) == Set(["myInfo"])
            end
            @test const_pointee(A("x", "real(c_float)", "(*)", "const float *"))
            @test !const_pointee(A("x", "real(c_float)", "(*)", "float *const"))
        end
        # A variant's own table that drops keys of its base's is reported.
        mktemp() do path, io
            write(io, "format = 1\n[lib_h]\na = \"scalar-host\"\nb = \"scalar-host\"\n[lib_h_64]\na = \"scalar-host\"\n[\"lib_k{,_64}\"]\nx = \"1d\"\n"); close(io)
            @test_logs (:warn, r"1 variant table") match_mode=:any load_metadata(path)
        end
        # Keys are C names; the emitted spelling is accepted but reported.
        mktemp() do path, io
            write(io, "format = 1\n[lib_n]\nmyInfo = \"scalar-device\"\nblock_ = \"scalar-host\"\n[lib_p]\ninfo = \"scalar-device\"\n"); close(io)
            md = @test_logs (:warn, r"2 argument\(s\) named as the module spells them") match_mode=:any load_metadata(path)
            @test md.devonly["lib_n"] == md.devonly["lib_p"] == Set(["myInfo"])
        end
        # A table that classifies alpha but forgets beta is reported too.
        mktemp() do path, io
            write(io, "format = 1\n[lib_m]\nalpha = \"scalar-pointer-mode\"\n"); close(io)
            pa(n) = ArgInfo(n, "real(c_double)", "(*)", false)
            m = FuncInfo("lib_m", "integer(c_int)", false, [pa("alpha"), pa("beta")])
            @test_logs (:info, r"1 function\(s\) with scalar-looking args") apply_argkinds([m], load_metadata(path))
        end
        # A devptr buffer gets _devptr twins only beside another Fortran array: with
        # none left, the twins of every rank would be one procedure (gelsBatched).
        let p(n) = ArgInfo(n, "integer(c_int)", "(*)", false),
            v(n) = ArgInfo(n, "type(c_ptr)", ", value", false),
            dm = LibMeta(devptr_arrays = Dict("zgels" => Set(["devInfo"]), "zgetrf" => Set(["devInfo"])))
            @test !wants_rank_devptr(FuncInfo("zgels", "integer(c_int)", false,
                                              [v("A"), v("C"), ArgInfo("lwork", "integer(c_int)", "", false), p("devInfo")]), dm)
            @test wants_rank_devptr(FuncInfo("zgetrf", "integer(c_int)", false, [p("A"), p("devInfo")]), dm)
        end
        # A workspace name is a guess: type(c_ptr) unless the table names the argument.
        mktemp() do path, io
            write(io, "format = 1\n[lib_g]\nbuffer = \"1d\"\n"); close(io)
            md = load_metadata(path)
            buf(n) = ArgInfo(n, "real(c_double)", "(*)", false)
            g = only(apply_workspace_default([FuncInfo("lib_g_64", "integer(c_int)", false,
                                                       [buf("buffer"), buf("work"), buf("x")])], md))
            @test [a.suffix for a in g.args] == ["(*)", ", value", "(*)"]
            @test g.args[2].ftype == "type(c_ptr)"
        end
        # explain_defaults (gen.sh --explain): the defaults, and what the table does to them.
        mktemp() do path, io
            write(io, "format = 1\n[lib_axpy]\nalpha = \"scalar-pointer-mode\"\nbeta = \"scalar-host\"\nscratch = \"1d\"\n"); close(io)
            md = load_metadata(path)
            A(n, ct) = ArgInfo(n, "real(c_double)", "(*)", false, ct)
            rules = DefaultRules(pointer_mode = true)
            f = FuncInfo("lib_axpy_64", "integer(c_int)", false,
                         [A("alpha", "const double *"), A("beta", "const double *"), A("work", "double *"),
                          A("scratch", "double *"), A("x", "double *")])
            @test explain_defaults(f, md, rules) == [
                "alpha: the table only repeats the default \"scalar-pointer-mode\" (pointer mode: a const alpha or beta); remove it",
                "beta: the table (\"scalar-host\") overrides the default \"scalar-pointer-mode\" (pointer mode: a const alpha or beta)",
                "work   (default: workspace, type(c_ptr))",
                "scratch: the table (\"1d\") overrides the default (workspace, type(c_ptr))"]
            g = FuncInfo("lib_dot", "integer(c_int)", false, [A("alpha", "const double *")])
            @test explain_defaults(g, md, rules) == ["alpha = \"scalar-pointer-mode\"   (default: pointer mode: a const alpha or beta)"]
            @test isempty(explain_defaults(g, md, DefaultRules()))
        end

        # gen_files enum_rename: FROM_ -> TO_ applied to the emitted module
        let out = mktempdir()
            cfg = Dict("general" => Dict("name" => "mini"),
                       "library" => Dict("prefix" => "mini", "enum_rename" => ["MINI_", "MI_"]))
            enums = [EnumInfo("mini_status_t", ["MINI_OK" => Int64(0), "MINI_ERR" => Int64(1)])]
            gen_files(out, cfg,
                      [FuncInfo("miniDo", "integer(c_int)", false,
                                [ArgInfo("x", "type(c_ptr)", ", value", false)])],
                      enums, StructInfo[])
            en = read(joinpath(out, "mini.F90"), String)
            @test occursin("enumerator :: MI_OK = 0", en) && !occursin("MINI_OK", en)
        end

        # gen_files no-success path: enums empty but a macro present -> has_enums,
        # success const not found -> no check routine.
        let out = mktempdir()
            cfg = Dict("general" => Dict("name" => "mini"), "library" => Dict("prefix" => "mini"))
            gen_files(out, cfg, FuncInfo[], EnumInfo[], StructInfo[];
                      macros = ["MINI_VER" => Int64(7)])
            m = read(joinpath(out, "mini.F90"), String)
            @test occursin("integer(c_int), parameter :: MINI_VER = 7", m)   # macros still declared
            @test !occursin("miniCheck", m)
        end
    end

    @testset "rich header: mapper + struct-field + macro branches" begin
        hdr  = joinpath(@__DIR__, "fixtures", "rich.h")
        cfg  = Dict("general" => Dict("name" => "rich"),
                    "library" => Dict("prefix" => "rich"),
                    "clang"   => Dict("defines" => String[], "extra_include_dirs" => String[]))
        args = make_clang_args(cfg, dirname(hdr))
        ctx  = create_context([hdr], args)
        tu   = ctx.trans_units[1]
        root = Clang.getTranslationUnitCursor(tu)
        funcs   = GC.@preserve ctx tu collect_funcs(root, "rich")
        macros  = GC.@preserve ctx tu collect_macros(root; own = ["rich"])
        structs = GC.@preserve ctx tu collect_structs(root; skip = String[], own = ["rich"])
        F = Dict(f.name => f for f in funcs)

        # array parameters (_ftype_of_array): scalar element vs array-of-pointers
        a = F["rich_arrays"].args
        @test a[1].ftype == "integer(c_int)" && a[1].suffix == "(*)"     # int[]
        @test a[2].ftype == "type(c_ptr)"    && a[2].suffix == ", value" # void*[] -> c_ptr by value

        # typedefs used BY VALUE (elaborated-canonical branches)
        b = F["rich_byvalue"].args
        @test b[1].ftype == "integer(c_int)" && b[1].suffix == ", value" # typedef int
        @test b[2].ftype == "real(c_double)"                             # typedef double
        @test b[3].ftype == "type(c_ptr)"    && b[3].suffix == ", value" # typedef void* (canonical Pointer)
        @test b[4].ftype == "type(c_funptr)"                             # typedef fn-ptr
        # A struct BY VALUE maps to the derived type, never type(c_ptr) (e.g. dim3).
        @test b[5].ftype == "type(rich_byval_t)" && b[5].suffix == ", value"

        # pointers to complex / half structs (pointer-to-Record branch)
        c = F["rich_cplx"].args
        @test c[1].ftype == "complex(c_float_complex)"  && c[1].suffix == "(*)"
        @test c[2].ftype == "complex(c_double_complex)" && c[2].suffix == "(*)"
        @test c[3].ftype == "integer(c_short)"          && c[3].suffix == "(*)"   # half struct* -> data buffer
        @test occursin("rich_outer", F["rich_struct"].args[1].ftype)              # struct* -> derived type

        # macro value parsing: plain, parenthesised, 64-bit, out-of-range dropped
        md = Dict(macros)
        @test md["RICH_PLAIN"] == 7 && md["RICH_PAREN"] == 42 && md["RICH_BIG"] == 5000000000
        @test !haskey(md, "RICH_HUGE")                          # > Int64 -> dropped

        # struct fields: the header's field comments are not copied; function-pointer field
        S  = Dict(s.name => s for s in structs)
        of = S["rich_outer_t"]
        @test all(fld -> isempty(fld.doc), of.fields)
        @test any(fld -> fld.ftype == "type(c_funptr)", of.fields)      # funcptr field

        io = IOBuffer(); emit_type_decls(io, structs)
        @test occursin("rich_outer_t", String(take!(io)))
        io = IOBuffer(); emit_enum_decls(io, EnumInfo[], macros)
        es = String(take!(io))
        @test occursin("RICH_BIG", es) && occursin("c_int64_t", es)     # 64-bit macro parameter
    end

    @testset "silent fallbacks now handled (fallbacks.h)" begin
        hdr  = joinpath(@__DIR__, "fixtures", "fallbacks.h")
        cfg  = Dict("general" => Dict("name" => "fb"),
                    "library" => Dict("prefix" => "fb"),
                    "clang"   => Dict("defines" => String[], "extra_include_dirs" => String[]))
        ctx  = create_context([hdr], make_clang_args(cfg, dirname(hdr)))
        tu   = ctx.trans_units[1]
        root = Clang.getTranslationUnitCursor(tu)
        funcs   = GC.@preserve ctx tu collect_funcs(root, "fb")
        macros  = Dict(GC.@preserve ctx tu collect_macros(root; own = ["fallbacks"]))
        structs = Dict(s.name => s for s in GC.@preserve ctx tu collect_structs(root; own = ["fallbacks"]))
        F = Dict(f.name => f for f in funcs)

        # The definition wins over the forward declaration: real fields, no blob.
        @test [fl.name for fl in structs["fb_fwd"].fields] == ["a", "b"]
        # A flexible array member makes the struct an opaque blob, not a scalar field.
        @test !any(fl -> fl.name == "v", structs["fb_flex"].fields)
        # N and n are one Fortran name: the second is renamed.
        @test [a.name for a in F["fb_case"].args] == ["N", "n_2"]
        # C octal literals.
        @test macros["FB_OCT"] == 8 && macros["FB_DEC"] == 10 && macros["FB_HEX"] == 16
        # A struct by value that is not emitted cannot fall back to a pointer.
        @test_throws ErrorException withenv(() -> revert_unknown_structs(F["fb_takes"] |> f -> [f], StructInfo[]),
                                            "ROCM_FORTRAN_STRICT" => "1")
        @test revert_unknown_structs([F["fb_takes"]], [structs["fb_byval"]])[1].args[1].ftype ==
              "type(fb_byval)"

        # Metadata entries that match nothing are reported, keys and argument names.
        md = joinpath(mktempdir(), "fb.toml")
        write(md, "format = 1\n[fb_case]\nN = \"scalar-host\"\nnope = \"scalar-host\"\n" *
                  "[fb_missing]\nx = \"scalar-host\"\n[fb_takes]\nfortran-arrays = false\n[fb_gone]\nfortran-arrays = false\n")
        @test_logs (:warn, r"fb.toml: 2 table") (:warn, r"fb.toml: 1 argument name") match_mode=:any check_metadata_names(funcs, load_metadata(md))
    end

    @testset "typedef aliases (aliases.h)" begin
        hdr = joinpath(@__DIR__, "fixtures", "aliases.h")
        cfg = Dict("general" => Dict("name" => "aliases"),
                   "library" => Dict("prefix" => "aliases"),
                   "clang"   => Dict("defines" => String[], "extra_include_dirs" => String[]))
        args = make_clang_args(cfg, dirname(hdr))
        ctx  = create_context([hdr], args)
        tu   = ctx.trans_units[1]
        root = Clang.getTranslationUnitCursor(tu)
        structs = GC.@preserve ctx tu collect_structs(root; own=["aliases"])
        names   = Set(s.name for s in structs)

        @test "aliasesA_t" in names          # identity shorter -> wins
        @test !("aliasesA_tR0600" in names) # the versioned typedef must not take the tag
        @test "aliasesB_io" in names         # shorter alias -> wins over the identity
        @test !("aliasesB_iodim" in names)

        # The arguments keep their derived type rather than type(c_ptr),value.
        funcs = GC.@preserve ctx tu collect_funcs(root, "aliases")
        kept  = revert_unknown_structs(funcs, structs)
        fa    = Dict(a.name => a.ftype for a in first(f for f in kept if f.name == "aliases_use").args)
        @test fa["a"] == "type(aliasesA_t)"
        @test fa["b"] == "type(aliasesB_io)"
        fb    = first(f for f in kept if f.name == "aliases_usef").args[1]
        @test fb.ftype == "type(aliasesB_io)" && fb.suffix == ""   # other typedef: renamed
    end

    @testset "exhaustive type coverage (alltypes.h)" begin
        hdr = joinpath(@__DIR__, "fixtures", "alltypes.h")
        cfg = Dict("general" => Dict("name" => "at"),
                   "library" => Dict("prefix" => "at"),
                   "clang"   => Dict("defines" => String[], "extra_include_dirs" => String[]))
        args = make_clang_args(cfg, dirname(hdr))
        ctx  = create_context([hdr], args)
        tu   = ctx.trans_units[1]
        root = Clang.getTranslationUnitCursor(tu)
        funcs = GC.@preserve ctx tu collect_funcs(root, "at")
        F  = Dict(f.name => f for f in funcs)
        ft(fn) = Dict(a.name => (a.ftype, a.suffix) for a in F[fn].args)

        # builtin scalars, by value
        s = ft("at_scalars")
        @test s["b"]  == ("logical(c_bool)",    ", value")
        @test s["c"]  == ("character(c_char)",  ", value")
        @test s["sc"] == ("character(c_char)",  ", value")   # signed char
        @test s["s"]  == ("integer(c_short)",   ", value")
        @test s["us"] == ("integer(c_short)",   ", value")
        @test s["i"]  == ("integer(c_int)",     ", value")
        @test s["u"]  == ("integer(c_int)",     ", value")
        @test s["l"]  == ("integer(c_long)",    ", value")
        @test s["ul"] == ("integer(c_long)",    ", value")
        @test s["ll"] == ("integer(c_int64_t)", ", value")
        @test s["ull"]== ("integer(c_int64_t)", ", value")
        @test s["f"]  == ("real(c_float)",      ", value")
        @test s["d"]  == ("real(c_double)",     ", value")

        # pointers to builtin scalars; short/ushort deliberately -> c_ptr,value
        p = ft("at_ptrs")
        @test p["bp"]  == ("logical(c_bool)",  "(*)")
        @test p["ip"]  == ("integer(c_int)",   "(*)")
        @test p["up"]  == ("integer(c_int)",   "(*)")
        @test p["lp"]  == ("integer(c_long)",  "(*)")
        @test p["llp"] == ("integer(c_int64_t)", "(*)")
        @test p["fp"]  == ("real(c_float)",    "(*)")
        @test p["dp"]  == ("real(c_double)",   "(*)")
        @test p["sp"]  == ("type(c_ptr)", ", value")     # short*  -> deliberate fallthrough
        @test p["usp"] == ("type(c_ptr)", ", value")     # ushort* -> deliberate fallthrough
        @test p["vp"]  == ("type(c_ptr)", ", value")     # void*
        @test p["vpp"] == ("type(c_ptr)", "")            # void** by ref
        @test p["cp"]  == ("type(c_ptr)", ", value")     # char*
        @test p["ccp"] == ("type(c_ptr)", ", value")     # const char*

        # long double* -> unhandled pointee kind -> pointer fallthrough;
        # long double by value -> unhandled top-level kind -> dispatcher fallthrough
        @test ft("at_longdouble")["p"]  == ("type(c_ptr)", ", value")
        @test ft("at_oddscalar")["ld"]  == ("type(c_ptr)", ", value")

        # width-exact typedefs, by value and by pointer
        w = ft("at_widths")
        @test w["n"]   == ("integer(c_size_t)",  ", value")
        @test w["s64"] == ("integer(c_int64_t)", ", value")
        @test w["s32"] == ("integer(c_int32_t)", ", value")
        @test w["s16"] == ("integer(c_int16_t)", ", value")
        @test w["s8"]  == ("integer(c_int8_t)",  ", value")
        wp = ft("at_widthptrs")
        @test wp["np"] == ("integer(c_size_t)", "(*)") && wp["s64p"] == ("integer(c_int64_t)", "(*)")

        # char typedef by value -> character(c_char); by pointer -> c_ptr (char* policy)
        ch = ft("at_chartd")
        @test ch["c"] == ("character(c_char)", ", value") && ch["p"] == ("type(c_ptr)", ", value")

        # typedefs used by value (elaborated-canonical scalar/pointer/funcptr/record/enum)
        bv = ft("at_byval")
        @test bv["b"]  == ("logical(c_bool)",   ", value")
        @test bv["i"]  == ("integer(c_int)",    ", value")
        @test bv["d"]  == ("real(c_double)",    ", value")
        @test bv["vp"] == ("type(c_ptr)",       ", value")   # typedef void*
        @test bv["fp"] == ("type(c_funptr)",    ", value")   # typedef fn-ptr
        @test bv["r"]  == ("type(at_rec_t)",    ", value")   # struct by value -> derived type, NOT c_ptr
        @test occursin("integer(kind(", bv["e"][1])          # typedef enum by value

        # direct tagged-struct pointers: plain / half / complex (Elaborated pointee, canonical Record)
        dr = ft("at_directrecs")
        @test dr["p"] == ("type(at_plain)", "")                 # plain struct*
        @test dr["h"] == ("integer(c_short)", "(*)")            # half struct* -> data buffer
        @test dr["c"] == ("complex(c_float_complex)", "(*)")    # complex struct*

        # enum by value and by pointer both spell the enum's own kind
        en = ft("at_enums")
        @test occursin("integer(kind(", en["e"][1]) && en["ep"] == ("integer(kind(AT_A))", "(*)")

        # arrays: scalar element / array-of-pointers / fixed-size
        ar = ft("at_arrays")
        @test ar["scal"]  == ("integer(c_int)", "(*)")
        @test ar["ptrs"]  == ("type(c_ptr)", ", value")        # array-of-pointers -> c_ptr by value
        @test ar["fixed"] == ("integer(c_int)", "(*)")         # fixed-size array

        # function pointer by value
        @test ft("at_fptr")["cb"] == ("type(c_funptr)", ", value")
    end

end
