# Design notes

These notes explain why the Fortran bindings and their build artifacts look the way they do, and how the generator handles the parts of a C API that do not map directly to Fortran.
They started as appendices of [RFC0015](https://github.com/ROCm/TheRock/blob/main/docs/rfcs/RFC0015-Fortran-Bindings-Split.md), which decided where the bindings live and how they are built and shipped; the RFC keeps the decisions, and these notes keep the reasoning and the details.
Following the RFC, the *packaged track* is the bindings co-located in rocm-systems and rocm-libraries and shipped with ROCm, and the *compatibility track* is hipfort under its current name, kept until ROCm 11.0.

## Build artifacts: the `.mod` files and the static archive

This section describes how hipfort installs today, and why its artifacts take the shape that the co-located bindings keep.

After `make install`, under `$CMAKE_INSTALL_PREFIX`:

```text
├── lib/fortran/<compiler> (HIPFORT_MULTITOOLCHAIN_LAYOUT=ON)
│   ├── libhipfort-amdgcn.a              ← AMD backend  (default)
│   └── libhipfort-nvptx.a               ← NVIDIA backend (compatibility track only, until 11.0)
├── lib/cmake/hipfort/                   ← find_package(hipfort): hipfort::rocblas ...
├── include/fortran/<compiler>/hipfort/{amdgcn,nvptx}/*.mod ← read on `use hipfort...`
```

The install layout has a toolchain dimension.
A `.mod` is the compiled interface file that a Fortran `use` statement reads.
It is specific to the compiler that produced it, and even to that compiler's version, so two Fortran compilers cannot share one `.mod`.
`HIPFORT_MULTITOOLCHAIN_LAYOUT` selects the layout.
When it is ON (the default), each compiler gets its own `<compiler>` subdirectory, for example `lib/fortran/gfortran/`, and several toolchains coexist under one prefix, as in the diagram above.
When it is OFF, the `.a` goes directly under `lib/` and the `.mod` tree under `include/hipfort/`, and a second compiler's install would conflict.
The backend (`amdgcn` for AMD, `nvptx` for NVIDIA) is a second, independent axis, because compiling for CUDA also produces a different `.mod` (see *One source set, two backends*, below).

`find_package(hipfort)` resolves to the subdirectory matching the consuming project's compiler and the AMD backend.
A presence check reports which pieces are installed for the user's compiler, so a user can confirm the Fortran extension is available before building.
Under the split, this becomes a per-library check with per-library targets (`find_package(rocblas-fortran)`, `roc::rocblas_fortran`); see [Building the bindings](https://github.com/ROCm/TheRock/blob/main/docs/rfcs/RFC0015-Fortran-Bindings-Split.md#building-the-bindings).

The root cause is that Fortran has no portable ABI: `.mod` files and compiled `.a` archives are specific to the compiler and its version.
The only stable ABI is C's, exposed by the vendor `.so`, and the `bind(C)` layer calls through it.
That constraint drives the whole packaging design, which ships source plus a precompiled set for `amdflang`.
The [next section](#why-a-mod-or-a-only-works-with-the-compiler-that-built-it) sets it out in full.

Both `.mod` and `.a` are needed, for different phases.

```text
   lib/hipfort/*.F90
         │  compile
         ▼
   ┌────────────────────────────┬────────────────────────────────┐
   │  *.mod  (declarations)     │   *.o  (only for real bodies)  │
   │  interfaces, enums, types  │   generic wrappers             │
   └─────────────┬──────────────┴───────────────┬────────────────┘
   COMPILE phase │                              │ ar → archive
   your_app.F90 ─┘ reads *.mod          libhipfort-amdgcn.a
         │                                      │
         ▼ compile                              ▼ LINK phase
   your_app.o ── unresolved symbols ──► libhipfort-amdgcn.a  (rocblas_dgemm_rank_0, rocblas_dgemm_full_rank, ...)
                                       ► librocblas.so       (rocblas_dgemm)
                                       ► libamdhip64.so      (HIP runtime)
```

The `.mod` is a compile-time artifact that carries declarations; the `.a` is a link-time artifact that carries compiled bodies.
A math-library call has two forms.
The raw `bind(C)` interface (`rocblas_dgemm_`) is a pure declaration: it sits in the `.mod`, adds nothing to the `.a`, and its symbol is resolved from the vendor `.so`.
The ergonomic variants (`rocblas_dgemm_rank_1`, `rocblas_dgemm_full_rank`, ...) take Fortran arrays and are real wrappers.
They call `c_loc`, which returns the C address of a Fortran variable, and forward to the raw form, so their bodies are compiled into the `.a`.
There are many of them, about 2,700 for rocBLAS alone in the default tier, alongside the HIP runtime wrappers (`hipMalloc`, `hipMemcpy`, `hipCheck`).
The `.a` therefore holds more than the memory wrappers, since every math library with ergonomic variants contributes bodies to it, and both the `.mod` and the `.a` must ship.

**Why a static archive, not a shared library.**
The `.a` holds thin forwarding shims, each of which does `c_loc` and calls the raw `bind(C)` form, and a shared library would buy nothing for them.
There is nothing substantial to share in memory.
The caller is bound to the module's interfaces at compile time through the `.mod`, so an interface change means recompiling anyway.
And a prebuilt `.so` is compiler- and version-locked just like a `.mod`.
A `.so` would only add a runtime dependency and a PLT indirection.

**Why not fuse with the vendor library.**
We keep the Fortran `.a` separate from the vendor `.so`.
Fusing them would tie the binding's version to the vendor release and make that `.so` carry Fortran symbols, and it would gain nothing: with amdflang, the wrapper object is under 2% of `librocblas.so`.
Keeping them apart causes no C-side clash either, since the C and Fortran objects compile in different directories.

A separate static `.a` also keeps unused wrappers out of the binary, but only at the granularity of its members, because the linker extracts whole object files from an archive, not single symbols.
Each library's module compiles to one object, so a program that calls one rocBLAS wrapper links all of them.
Compiling the archive with `-ffunction-sections -fdata-sections` puts each wrapper in its own section, and a program linked with `-Wl,--gc-sections` then keeps only the wrappers it calls.
A shared library that links the archive exports every wrapper, and the linker never removes an exported symbol.
Such a library therefore also links with `-Wl,--exclude-libs,librocblas_fortran.a:libhip_fortran.a`, with the archives separated by colons because `-Wl,` splits on commas.
The wrappers still work but are no longer exported; the migration guide documents this flag.

Per-procedure sections also decide whether a program links at all when the binding and the vendor library do not come from the same headers.
That can happen in either direction:

- a binding newer than the library (generated from development headers, or from a later 10.x) has wrappers for routines the installed `.so` does not export yet;
- a binding older than the library has wrappers for routines the library has since removed or renamed, such as entry points that were marked deprecated.

Either way the archive member holds an undefined symbol.
Without per-procedure sections, every program that calls any wrapper of that module then fails to link, whether or not it calls that routine.
With them and `-Wl,--gc-sections`, only a program that calls that routine fails, which is the failure it should get.
A binding and its library built together, as in a ROCm release, never hit this, but mixing releases, which the `SameMajorVersion` promise invites, does.

**One source set, two backends.**
The same sources compile twice under the CUDA switch (`-DUSE_CUDA_NAMES`), producing a per-backend archive and `.mod`: `libhipfort-amdgcn.a` for AMD, `libhipfort-nvptx.a` for NVIDIA.
A compiled `.mod`/`.o` is backend-specific, so the two cannot share one archive.
The packaged track keeps only the AMD backend.

## Why a `.mod` or `.a` only works with the compiler that built it

This constraint shapes the whole packaging design.

Unlike C, Fortran has no standard ABI and no standard module format.
Two artifacts are affected.

The first is the `.mod` file, a compiler-private serialization of a module's interface: its names, kinds and generic-resolution tables.
Its format is undocumented and specific to each compiler.
It is not stable across versions of the same compiler either.
gfortran, for instance, changes its module format between some releases (format 15 since GCC 8) and promises no compatibility, so a `.mod` written by one gfortran can be rejected by another.
Across compilers there is no interoperability at all: a gfortran `.mod` is meaningless to ifx, amdflang or Cray, and the reverse is also true.

The second is the compiled `.a`.
The wrapper bodies compile to objects whose symbols are name-mangled by a compiler-specific scheme, with trailing underscores or module-name decoration such as `__rocblas_MOD_`.
The archive is therefore tied to the same compiler as the `.mod` it accompanies, and in practice to its version too, since the two must match.

The only portable thing to ship is the Fortran source.
A prebuilt `.mod`/`.a` set works only with the exact compiler that produced it, at essentially the exact version.

On the compiler we ship, there is one relaxation.
Since ROCm 10.1, amdflang has an opt-in `-fmodule-mismatch-check=warn` that downgrades the module-version check to a warning, so a newer amdflang can read a `.mod` written by an older one.
That helps with version skew in the precompiled amdflang set we ship, which is the case our users are most likely to hit: a ROCm-shipped `.mod` used with a slightly different amdflang.
It does nothing across compilers, and that is the problem that forces us to ship source.
No flag makes a gfortran `.mod` readable by amdflang.

This is why the design:

- ships **source** so any site can compile with its own compiler, and additionally ships a **precompiled set for the default compiler (`amdflang`)** for the common case;
- keys the install tree by **compiler** under `lib/fortran/<compiler>/` and `include/fortran/<compiler>/` (a site keeping two versions of one compiler sets `<LIB>_FORTRAN_COMPILER_DIR`, for example `gfortran-13`);
- treats the only stable ABI as the **C one**, the vendor `.so`, which the `bind(C)` layer rides on and which every compiler agrees about.

NVIDIA avoids all of this by owning the single compiler its users run (`nvfortran`), which is why it can ship prebuilt `.mod` files and we cannot (see [How NVIDIA does it](#how-nvidia-does-it)).

## How NVIDIA does it

The closest analog is NVIDIA's Fortran support for its GPU math libraries.

NVIDIA ships precompiled Fortran modules for cuBLAS, cuFFT, cuRAND, cuSOLVER, cuSPARSE, cuTENSOR and more.
They come inside the HPC SDK, next to `nvfortran`.
You write `use cublas` and link with `-cudalib=cublas`.
The big difference is that NVIDIA owns the only compiler its users use.
With a single supported compiler, the fact that a `.mod` cannot cross compilers never comes up, so shipping prebuilt `.mod` files works for them.
We cannot copy that, because our users are on gfortran, amdflang, Cray CCE, ifx and others.
So we ship the source for every compiler, plus a precompiled set for `amdflang`.

The other differences, point by point:

- **Location.** NVIDIA's interfaces live in the compiler and SDK, not in each library's source repository.
  Ours live next to the C headers in `rocm-systems` and `rocm-libraries`, and each monorepo's own workflow regenerates them.
- **Naming.** NVIDIA uses no prefix: the module is `use cublas`, not `nvfort_cublas`.
  The module name is the library name.
- **Backward compatibility.** NVIDIA keeps the legacy and the v2 calling conventions side by side (`cublas` and `cublas_v2`).
- **Array handling.** NVIDIA does not use assumed-rank arrays.
  It relies on the CUDA Fortran `device` attribute instead.
  `nvfortran` tells host arrays from device arrays, and the interfaces declare device arrays, so the language itself resolves host/device dispatch.
  gfortran and flang do not know `device`.
  Our `bind(C)` interfaces, `c_loc` and generated variants are the portable substitute for what `nvfortran` does natively.
- **Scalar host-vs-device (alpha/beta).** Because `nvfortran` knows host from device, its non-v2 `cublas` module sets the library pointer mode implicitly on each call, depending on whether the scalar argument has the `device` attribute.
  We cannot rely on the compiler for this, so `.argkinds` records which scalar pointers are host values.
  Static metadata cannot fully settle the question, though, because the host-versus-device choice for `alpha`/`beta` is also runtime handle state (`rocblas_set_pointer_mode`).
  The convenient host-scalar form is only correct when the handle is in host-pointer mode.
  The wrappers must not silently set or restore that mode: it is shared, mutable handle state, and touching it would race other threads.
  For device-pointer mode, users fall back on the raw `type(c_ptr)` interface.
- **Tooling.** NVIDIA's tooling is the compiler driver, with `-cudalib` and an automatic module search path.
  It needs no separate installation checker, since the bindings come with the compiler.
  Ours do not come with any one compiler, so explicit packaging and a presence check are worth having.

Most of the hard questions in RFC0015 exist because we do not own the one compiler our users run: the `.mod` and the ABI across compilers, where the bindings live, and how they are generated.
NVIDIA answers them with a single compiler; we answer them with generation, source shipping and co-location.

## C constructs that are ambiguous or have no Fortran equivalent

Some valid C constructs are ambiguous or have no Fortran equivalent.
For those, the generator falls back to a defined, ABI-correct form instead of dropping them or guessing.

- **Bit-fields, unions, anonymous members.** A struct that is not field-mappable is emitted as an opaque byte blob of the exact C size and alignment.
  Structs that embed an opaque struct keep their field offsets, so nothing downstream breaks, at the cost of not being able to access the opaque struct's own members individually.
  This is how `hipDeviceProp_t` survives, even though it embeds the bit-field struct `hipDeviceArch_t`.
  A union is handled more narrowly: it becomes one field of its enclosing struct, so the struct's other fields stay accessible.
  That field is a blob of the union's size when the union's members differ in type.
  A struct with an incomplete or zero-size layout is skipped.

- **Opaque handles.** A pointer to an incomplete struct, such as `rocblas_handle`, is a `type(c_ptr)`, as it was in hipfort.

- **Opaque workspace pointers.** A typed pointer that is really scratch memory is always bound as a `type(c_ptr)` passed by value, never as a Fortran array.

- **C strings.** `char*` is bound as the C API spells it, a `type(c_ptr)`, in every role:

  - an input string;
  - a `const char*` return value, such as the status-to-string helpers and `hipGetErrorString`;
  - a caller-supplied output buffer.

  This is hipfort's surface, so code written against hipfort compiles unchanged.
  A library can opt in to a typed form for its input strings.
  ROCTx does: its routines also accept a `character(kind=c_char)` string, passed without a copy, so the caller appends the terminating NUL (`"zone"//c_null_char`).

- **Null pointers as a mode selector.** Across rocSPARSE, rocBLAS and rocSOLVER, `NULL` is sometimes a mode selector, not an error.
  This is the buffer-size query/execute idiom: call once with `NULL` to get the size, then again with the buffer.
  A Fortran array argument cannot be "absent", and `OPTIONAL`, Fortran's marker for an argument the caller may omit, is illegal on the raw surface.
  Fortran 2018 constraint C865 forbids `OPTIONAL` with `VALUE` in a `bind(C)` procedure, and every raw pointer is passed by value.
  Fortran 2018 does allow `OPTIONAL` on a by-reference `bind(C)` argument, but Fortran 2008, the level of the default tier, does not.
  So the `<lib>.optional` metadata records which by-reference arguments accept `NULL`.
  For those, the generator adds a plain (non-`bind(C)`) procedure to the same generic, where `OPTIONAL` is legal.
  That procedure passes `c_null_ptr` for an omitted argument, so omitting it from a call passes `NULL` to C.
  The raw specific `X_` stays callable by name.

- **Complex numbers.** A rocBLAS or rocSPARSE complex is a two-float C struct, which the C type system does not distinguish from any other two-float struct.
  Mapping it to a Fortran intrinsic `complex` is therefore a curated fact.
  It rests on an ABI assumption: the struct is passed the same way as `complex(c_float_complex)` on the supported platforms.
  That assumption is to be checked by a size-and-alignment check, which is not implemented yet.
  The alternative, a `bind(C)` derived type, would break every existing user and the shipped examples that pass a plain `complex`.

- **Macros and vector types.** Function-like and internal (`__`-prefixed) macros are skipped, while `#define` constants are extracted as parameters.
  The low-level HIP vector types (`float4`, `int4` and the rest) are skipped, and functions taking a pointer to one keep `type(c_ptr)`.
  A library that passes one by value lists it to be emitted (rocRAND's `uint4`).

Two ambiguities the C type system cannot resolve on its own are left to the curated metadata (see [Curated metadata](#curated-metadata)):

- a scalar host value versus a data buffer (`const double* alpha` versus `double* x`, identical in C);
- device-side output scalars.

Invalid C is a separate case: the generator fails on it (see [C-header hygiene](https://github.com/ROCm/TheRock/blob/main/docs/rfcs/RFC0015-Fortran-Bindings-Split.md#free-side-effect-c-header-hygiene)).

## Curated metadata

The generator emits everything the C ABI carries: signatures, enums and structs.
A few Fortran-side facts are not in the C headers and cannot be inferred, so they live in small per-library files that a maintainer curates.
These files sit in a `metadata/` directory next to the library's module:

- `projects/fortran/metadata/` in `rocm-systems`;
- `projects/<lib>/fortran/metadata/` in `rocm-libraries`.

The generator reads that directory when it runs on a checkout, so the metadata is curated next to the header it describes, in the same repository (P1).
It is the one part that stays manual: the bindings are generated, but this thin layer of per-argument intent is not in the C API.
Several files concern the *pointer mode*, a per-handle setting that says whether scalar arguments such as `alpha` and `beta` are read from host or device memory.

| File               | What it encodes                                                                     | Why the headers cannot give it                                                           |
| ------------------ | ----------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| `<lib>.argkinds`   | which pointer args are scalars (`alpha`, `beta`, an output) vs data buffers         | `const double* alpha` and `double* x` are identical in C                                 |
| `<lib>.ptrmode`    | the subset of those scalars the library reads per its pointer mode (host or device) | the pointer mode is runtime handle state                                                 |
| `<lib>.devonly`    | scalars the device writes (hipSOLVER's `devInfo`), which get no host form           | the C type does not say which side writes                                                |
| `<lib>.cptrargs`   | pointers kept as pass-through `type(c_ptr)` in the array overloads (a dot `result`) | pointer-mode outputs live on the device, so binding them as host Fortran arrays is wrong |
| `<lib>.native`     | which functions get the array (`_rank_*`) overloads, and the max rank               | rank is a Fortran-side choice, absent from the ABI                                       |
| `<lib>.optional`   | by-reference arguments the C API accepts as `NULL`                                  | a nullable pointer and a required one are identical in C                                 |
| `<lib>.byvalue`    | arguments passed by value although their C type is a pointer (HIP's `extra`)        | the C type does not say how the API reads it                                             |
| `<lib>.funptrargs` | arguments that are function pointers declared `void*`                               | the C type erased the function type                                                      |
| `<lib>.arrayargs`  | pointers to a derived type that are arrays (hipFFTW's `fftw_iodim`)                 | a pointer to one element and to an array are identical in C                              |

A library carries only the files it needs: none for ROCTx, one to three for the FFT and RAND libraries, and four to six for HIP and the BLAS, SOLVER and SPARSE libraries.

The generator configuration, `<lib>.toml`, holds the name prefix, opaque handles, own headers and check overrides.
Those are project conventions, not facts from the headers, so the file stays with the generator, which owns the code that reads it.
The HIP binding's pull request carries its `metadata/` (ROCTx needs none).
The `rocm-libraries` pull requests add theirs before they leave draft; until then, the generator keeps a copy of each.

The maintenance cost is bounded, because these files were bootstrapped and are validated by the tool.
Every `.argkinds` was derived from the original hipfort sources in one run.
The `.ptrmode` and `.devonly` files were first derived from `.argkinds` by a script, minus a short per-library list of host-only arguments; they are now curated by hand.
The generator's `apply_argkinds` step reports scalar-looking arguments that are still unclassified.
What remains is small, and it is maintenance rather than authoring: when a new ROCm function has a scalar pointer argument the bootstrap did not cover, that argument must be classified by hand, and the report points at it.

**Keeping the classifications correct.**
The `apply_argkinds` report catches an *unclassified* argument, but not a *stale* one, which stays well-formed after a function is renamed or its signature changes.
So on each run the generator also checks the entries against the parsed C declarations and reports any that match nothing.
Today that check covers every metadata file, function names and parameter names alike, but it only warns.
Before the regeneration workflow is enabled (see [Rollout](https://github.com/ROCm/TheRock/blob/main/docs/rfcs/RFC0015-Fortran-Bindings-Split.md#rollout-and-success-criteria)), an unmatched entry **fails generation** instead, so the bot never proposes a binding built from a stale entry.
No such check can catch an entry that matches but is wrong.
That case is covered two ways:

- a one-time audit of the classifications bootstrapped from hipfort;
- runtime tests that exercise **both host-pointer and device-pointer modes** for a representative set of entry points.

Those tests prioritize the pointer-mode-ambiguous families (`alpha`/`beta`/`result`), where a wrong classification turns into a fault or a silently wrong answer.

## How the generator is tested

The generator is tested at three levels: its own logic, the shape of its output and the output at runtime.

Its logic has a unit-test suite in the generator repository that exercises the pure transforms, with no ROCm headers:

- C-type to Fortran mapping;
- name and spec helpers;
- the metadata loaders;
- the bind, wrapper, enum and struct emitters;
- 132-column line wrapping;
- the selection of header sources from checkouts.

Small fixture headers are parsed with the libclang Clang.jl ships.
The suite also includes:

- a byte-for-byte golden test, which asserts the emitters still produce the same output as before;
- `compile_golden.jl`, which runs `gfortran -fsyntax-only` on regenerated fixtures to prove the output is valid Fortran;
- `array_ifaces.jl`, which checks that each `FORTRAN_ARRAY_INTERFACES` setting yields the same API as the `.F90` compiled with the matching preprocessor macro, since the array forms are guarded by macros.

The suite runs in the generator repository's CI on every supported Julia version.

The output is checked in CI in two places, and those checks double as regression tests.
The generator repository's CI compiles its own output for its test fixtures (`compile_golden.jl`) and checks the array tiers against each other.
In each monorepo, the CI of the bot's pull request builds the regenerated modules with the project's compilers, in each array configuration, and compiles each library's Fortran tests (`fortran/test/`, where present) against them.
This catches interface drift without a GPU.

These gates are compile-only, so they need no GPU.
At runtime, the same `fortran/test/` tests exercise the bindings on an AMD GPU, as GPU-labeled CTest tests of each library.
That runtime suite must cover both pointer modes, host and device, for the `argkinds`-classified entry points.
A misclassified scalar pointer compiles and links cleanly, so it is the one correctness property no compile-only gate can see (see [Keeping the classifications correct](#curated-metadata)).

Because the transforms are unit-tested, the trust the regeneration workflow needs is largely in place: the bindings team, reviewing the bot's pull request, relies on a tool whose logic is checked, and not only on its output.

