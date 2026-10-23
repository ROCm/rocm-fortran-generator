# rocm-fortran-generator

Generates the Fortran bindings of the HIP runtime, ROCTx and the ROCm math libraries from their C headers.

It parses the headers with [Clang.jl](https://github.com/JuliaInterop/Clang.jl) and emits, for each library,
a Fortran module with the `bind(C)` interfaces, the enum constants, the derived types,
an error-check helper, and overloads that take Fortran arrays and scalars directly.
The generated modules are committed next to the C headers in
[rocm-systems](https://github.com/ROCm/rocm-systems) and [rocm-libraries](https://github.com/ROCm/rocm-libraries).
This repository holds only the generator.

## Status and intent

Active development, maintained by AMD (see [Maintainers](#maintainers)).
The generator is build-time tooling: it is not shipped in ROCm, and nothing in it reaches a program that uses the bindings.
It exists so that the Fortran bindings of `rocm-systems` and `rocm-libraries` are regenerated from their C headers,
by the CI of those repositories and by their maintainers, instead of being written and updated by hand.

## Requirements

- Linux
- Julia 1.11, 1.12 or 1.13 ([install](https://julialang.org/install/), e.g. `curl -fsSL https://install.julialang.org | sh`);
  each has its pinned `src/Manifest-v<version>.toml`, and CI tests the three
- the ROCm headers, to generate bindings: an installed ROCm (`/opt/rocm/include` by default),
  or checkouts of rocm-systems and/or rocm-libraries; tested with ROCm 7.14, 10.0 and 10.1
  and with the `develop` branches of the two repositories
- a Fortran compiler, to compile them (gfortran 9 or later, or amdflang)

## Quick start

```bash
./gen.sh                                                # generate the bindings into fortran/
bash check_mods.sh                                      # compile them
```

`gen.sh` installs the Julia dependencies on its first run.
Every shell script prints its options with `-h`.

## Output

`gen.sh` writes one module per library, named after the library (`use hip`, `use rocblas`),
with its enums, types and, when the library has a status type, a `<lib>Check` routine,
into `fortran/rocm-systems/fortran/` (HIP, ROCTx) and `fortran/rocm-libraries/<lib>/` (the math libraries),
where it is committed upstream.
`fortran/.provenance` records the libraries generated, the headers read (installed ROCm or checkouts),
the HIP version, the array-interface setting and the generator commit that produced it.

With the default `ROCM_FORTRAN_ARRAY_INTERFACES=all`, the array overloads are selected when the module is compiled, with preprocessing (`gfortran -cpp`):
define `USE_ASSUMED_SHAPE` for the per-rank overloads (Fortran 2008)
or `USE_ASSUMED_RANK` for the `dimension(..)` ones (Fortran 2018, which wins if both are defined).
With neither, only the `bind(C)` interfaces and the typed forms are compiled.

## Regenerating

One library:

```bash
julia --project=src src/rocblas/generator.jl /opt/rocm/include <output-dir>
```

This writes `<output-dir>/rocblas.F90`, byte-for-byte what `./gen.sh` produces for rocBLAS.

All libraries at once, nested by upstream repository (`<output>/rocm-systems/fortran/hip.F90`, `<output>/rocm-libraries/rocblas/rocblas.F90`, ...):

```bash
julia --project=src src/generate_all.jl /opt/rocm/include <output-dir>
```

| Variable | Values | Effect |
|---|---|---|
| `ROCM_FORTRAN_ARRAY_INTERFACES` | `all` (default), `assumed-shape`, `assumed-rank`, `none` | `all` emits both array-overload tiers behind `#ifdef USE_ASSUMED_SHAPE` / `USE_ASSUMED_RANK`; the other values keep one tier, unguarded |
| `ROCM_INCLUDE` | a header directory | `gen.sh` only: the installed ROCm headers to read (default `/opt/rocm/include`), unless `ROCM_SYSTEMS` is set |
| `ROCM_SYSTEMS` | a rocm-systems checkout | generate HIP and ROCTx from it |
| `ROCM_LIBRARIES` | a rocm-libraries checkout | generate the math libraries from it |
| `ROCM_FORTRAN_OUT` | a directory | `gen.sh` only: where to generate (default `fortran/`) |

The checkouts select the libraries and where their headers come from:

| Set | Generated | Headers |
|---|---|---|
| neither | all | the installed ROCm |
| `ROCM_SYSTEMS` | HIP, ROCTx | the rocm-systems checkout only |
| `ROCM_LIBRARIES` | the math libraries | the rocm-libraries checkout; only the HIP headers from the installed ROCm |
| both | all | the two checkouts only |

A run rewrites only the modules it generates and leaves the others in place.
With `ROCM_SYSTEMS` set, no installed ROCm is read and `generate_all.jl` takes just `[output-dir]`;
otherwise it takes `[include-dir] [output-dir]`.
With `ROCM_LIBRARIES` alone, only the `hip/` headers of the installed include dir are visible, after the checkout,
so an older math library header installed next to HIP is never read: a header the checkout lacks fails the library.
The headers the builds generate (version, config and export headers) are synthesized from the templates and CMake files of the checkouts.
Any Clang error fails the library, and the run exits non-zero.

In CI, each repository generates its own modules from its own checkout:

```bash
# rocm-systems: no ROCm installation needed
ROCM_SYSTEMS=<rocm-systems checkout> ./gen.sh
# rocm-libraries: HIP from an installed ROCm (ROCM_INCLUDE, default /opt/rocm/include)
ROCM_LIBRARIES=<rocm-libraries checkout> ./gen.sh
```

A runner needs Julia, for example `curl -fsSL https://install.julialang.org | sh -s -- --yes`.
The first run downloads about 2 GB of dependencies (libclang), so cache `~/.julia` between runs.

### Regenerating one library in your checkout

After changing a library's C headers, regenerate its module in your checkout:
name the library, and pass `--overwrite` to write the module into the checkout.
Run from this repository:

| Library | Command | Writes |
|---|---|---|
| HIP | `ROCM_SYSTEMS=<rocm-systems> ./gen.sh --overwrite hip` | `projects/fortran/hip.F90` |
| ROCTx | `ROCM_SYSTEMS=<rocm-systems> ./gen.sh --overwrite roctx` | `projects/fortran/roctx.F90` |
| rocBLAS | `ROCM_LIBRARIES=<rocm-libraries> ./gen.sh --overwrite rocblas` | `projects/rocblas/fortran/rocblas.F90` |
| hipBLAS | `ROCM_LIBRARIES=<rocm-libraries> ./gen.sh --overwrite hipblas` | `projects/hipblas/fortran/hipblas.F90` |
| rocSOLVER | `ROCM_LIBRARIES=<rocm-libraries> ./gen.sh --overwrite rocsolver` | `projects/rocsolver/fortran/rocsolver.F90` |
| hipSOLVER | `ROCM_LIBRARIES=<rocm-libraries> ./gen.sh --overwrite hipsolver` | `projects/hipsolver/fortran/hipsolver.F90` |
| rocSPARSE | `ROCM_LIBRARIES=<rocm-libraries> ./gen.sh --overwrite rocsparse` | `projects/rocsparse/fortran/rocsparse.F90` |
| hipSPARSE | `ROCM_LIBRARIES=<rocm-libraries> ./gen.sh --overwrite hipsparse` | `projects/hipsparse/fortran/hipsparse.F90` |
| rocFFT | `ROCM_LIBRARIES=<rocm-libraries> ./gen.sh --overwrite rocfft` | `projects/rocfft/fortran/rocfft.F90` |
| hipFFT | `ROCM_LIBRARIES=<rocm-libraries> ./gen.sh --overwrite hipfft` | `projects/hipfft/fortran/hipfft.F90` |
| hipFFTW | `ROCM_LIBRARIES=<rocm-libraries> ./gen.sh --overwrite hipfftw` | `projects/hipfft/fortran/hipfftw.F90` |
| rocRAND | `ROCM_LIBRARIES=<rocm-libraries> ./gen.sh --overwrite rocrand` | `projects/rocrand/fortran/rocrand.F90` |
| hipRAND | `ROCM_LIBRARIES=<rocm-libraries> ./gen.sh --overwrite hiprand` | `projects/hiprand/fortran/hiprand.F90` |

`<rocm-systems>` and `<rocm-libraries>` are the paths of your checkouts, and the
last column is relative to them. Several libraries can be named in one run
(`./gen.sh --overwrite hipfft hipfftw`). A math library reads its own headers from
the checkout and HIP's from the installed ROCm (`ROCM_INCLUDE`, default
`/opt/rocm/include`); set `ROCM_SYSTEMS` as well to take HIP from a rocm-systems
checkout instead.

The module is identical to the one a full `./gen.sh` run produces for that
library. `--overwrite` checks that the library's `fortran/` directory exists in
the checkout before generating anything, and copies a module only once it has
generated, so a failure leaves the checkout as it was. Without `--overwrite`, the
module is written to `fortran/` only. Then review the change with `git diff` in
the checkout, and compile it with `bash check_mods.sh`.

## Adding a library

1. Create `src/<lib>/<lib>.toml` with `[general] name`, `[library] prefix` and `opaque_handles`.
   Exactly one header is parsed, the umbrella header `<include>/<subdir>/<file>`, or `<include>/<file>`
   when the project's headers are flat (as rocBLAS's are in rocm-libraries). `subdir` defaults to the
   library name and `file` to `<subdir>.h`; set them in a `[headers]` block when they differ
   (see `src/roctx/roctx.toml`).
2. Create `src/<lib>/generator.jl`. The minimal one is `src/roctx/generator.jl`:
   ```julia
   include("../common/fortran_gen.jl")

   function main()
     # Everything is configured in roctx.toml.
     run_library_generator(@__DIR__)
   end

   main()
   ```
   The others pass `argshook=` to add include directories or force-included headers (see `src/hipfft/generator.jl`).
3. Add `"<lib>"` to `LIBS` in `src/common/header_sources.jl`
   (and to `proj_of`, `repo_of` and `lib_include` there if its header directory is not `<lib>/` or it ships in rocm-systems).
4. Run `./gen.sh && bash check_mods.sh`, then add `src/<lib>/metadata/<lib>.toml` as needed (see [Fixing a binding](#fixing-a-binding)).

If the generator finds far fewer functions than expected, check the `prefix` spelling and the header it parses.

### The `<lib>.toml` keys

| Key | Default | Effect |
|---|---|---|
| `[general] name` | required | the library and module name, and the metadata file name |
| `[library] prefix` | required | only functions whose name starts with it are bound |
| `[library] opaque_handles` | required (may be `[]`) | struct tags never emitted as derived types (handles) |
| `[library] own_headers` | `[name]` | header-path markers of the files whose enums, structs and macros are this library's |
| `[library] reexport_enums` | `[]` | sibling libraries whose enums are `use`d from the sibling module instead of copied (rocSOLVER: `["rocblas"]`) |
| `[library] keep_structs` | `[]` | HIP vector types to emit anyway, when a function takes one by value (rocRAND: `["uint4"]`) |
| `[library] string_args` | `false` | `const char*` inputs also take a Fortran string in the `_typed` form |
| `[library] alias_function_macros` | `false` | bind the documented name of a forwarding macro to its ABI symbol (ROCTx: `roctxMark` to `roctxMarkA`) |
| `[library] enum_rename` | none | `["FROM_", "TO_"]`: respell the module's enumerators (hipSOLVER: `HIPBLAS_` to `HIPSOLVER_`) |
| `[library] metadata_dir` | `src/<lib>/metadata/` | the directory of `<lib>.toml`, the metadata (`generate_all.jl` passes a checkout's) |
| `[headers] subdir`, `file` | `name`, `<subdir>.h` | the one header parsed (see step 1) |
| `[clang] defines` | `[]` | `-D` definitions for the parse |
| `[clang] extra_include_dirs` | `[]` | `-I` directories, relative to the include dir; missing ones are skipped |
| `[clang] extra_args` | `[]` | other Clang arguments |
| `[check] success` | detected | the status constant meaning success, for the `<lib>Check` helper |
| `[check] name` | `<name>Check` | the name of that helper |

## Fixing a binding

The generated Fortran is never edited by hand.
A binding is fixed by regenerating it, after changing the generator or the library's **metadata**:
the few facts its C headers cannot express, in one file per module.

### What the generator does on its own

For every C function `X`, the module has a generic `X` with these forms:

| Form | Takes | When |
|---|---|---|
| `X_` (`bind(C)`) | every pointer as `type(c_ptr)`, exactly the C signature | always; out of the generic when `X_opt` takes its place |
| `X_typed` | each scalar the metadata names as a Fortran variable (`real :: alpha`), the other pointers as `type(c_ptr)` | it has a host or pointer-mode scalar |
| `X_devptr` | the pointer-mode scalars as `type(c_ptr)`, the host-only ones still typed | it has both kinds |
| `X_opt` | a `nullable` argument as `optional` | it has one that is not a scalar |
| `X_rank_0`, `X_rank_1`, `X_full_rank` (F2008) / `X_assumed_rank` (F2018) | each data buffer as a Fortran array, the scalars typed | it has a data buffer |
| `_devptr` twins of the array forms | the arrays, with the pointer-mode and device scalars as `type(c_ptr)` | it has such a scalar |

The array forms exist only in the F2008 (`USE_ASSUMED_SHAPE`) and F2018 (`USE_ASSUMED_RANK`) tiers;
`_rank_0` and `_rank_1` take every buffer as a scalar or a vector, `_full_rank` each buffer at its natural rank.

From the C declaration alone, the generator decides:

- **a typed pointer** (`float*`) is a data buffer: an array in the array forms;
  a pointer to a C struct is one element; `work`, `pBuffer` and other workspace names stay `type(c_ptr)`;
- **a buffer's natural rank** is 1, plus 1 when a leading dimension (`lda`, ...) follows it,
  plus 1 when a batch stride (`stride_A`, `stridex`, ...) follows that or its increment:
  `gemv`'s `A` is 2-D, `gemm_strided_batched`'s `A` 3-D, a strided-batched vector 2-D;
- **an array of pointers** written with an explicit `*` (`T* x[]`, `T* const* x`, the `A` of a batched routine)
  is passed by value: the caller passes a `c_ptr` to the array.
  A plain `T**` is an output (hipMalloc's pointer, a created handle) and an array of a pointer typedef
  (`const hipGraphNode_t*`) an array of handles: both stay by reference.

For example, from

```c
hipblasStatus_t hipblasSgemv(hipblasHandle_t handle, hipblasOperation_t trans, int m, int n,
                             const float* alpha, const float* AP, int lda, const float* x, int incx,
                             const float* beta, float* y, int incy);
```

and the metadata `alpha = "scalar-host-or-device"`, `beta = "scalar-host-or-device"`, a program can call

```fortran
real, pointer :: dA(:,:), dx(:), dy(:)
! host pointer mode: _full_rank, alpha and beta by value, A as a matrix
call hipblasCheck(hipblasSgemv(h, HIPBLAS_OP_N, m, n, 1.0, dA, lda, dx, 1, 0.0, dy, 1))
! device pointer mode: _full_rank_devptr, alpha and beta as device pointers
call hipblasCheck(hipblasSgemv(h, HIPBLAS_OP_N, m, n, d_alpha, dA, lda, dx, 1, d_beta, dy, 1))
! any mode: the bind(C) form, everything as type(c_ptr)
call hipblasCheck(hipblasSgemv(h, HIPBLAS_OP_N, m, n, c_loc(alpha), c_loc(dA), lda, &
                               c_loc(dx), 1, c_loc(beta), c_loc(dy), 1))
```

Without the metadata, `alpha` and `beta` would be buffers: arrays of one element.

### The metadata file

| | |
|---|---|
| **where** | `src/<lib>/metadata/<lib>.toml` in the generator; when a run reads a checkout, the checkout's own `metadata/` next to the module replaces it (`projects/fortran/metadata/` in rocm-systems, `projects/<proj>/fortran/metadata/` in rocm-libraries) |
| **none** | a missing or empty file means no metadata: the C declarations alone |
| **`format = 1`** | required as soon as there is an entry; the version of this schema, not of the generator |
| **tables** | one per C function, keyed by its arguments' names as the C header spells them |
| **braces** | a key names several functions as in a shell, `["hipsolver{S,D,C,Z}gebrd"]`, or `["x{,_64}"]` with an empty alternative; a function named by two keys is an error |
| **variants** | an `_spt` variant without a table takes the whole table of the same function without `_spt`, an ILP64 `_64` variant that of the 32-bit one; a table of its own replaces the base's entirely; a `_v2`, a new API, inherits nothing |

```toml
format = 1

["hipblas{S,D,C,Z}gemv"]
alpha = "scalar-host-or-device"
beta = "scalar-host-or-device"

["hipsolver{S,D,C,Z}gebrd"]
devInfo = "scalar-device"

["rocblas_{s,d}rotg_strided_batched"]
a = "1d"
```

### The values

An argument takes one value, or a list of values that answer different questions, each at most once:
`x = "scalar-host"`, `x = ["scalar-host", "nullable"]`.
Without an answer, the generator goes by the C declaration, as above.

**What is it?**

| Value | Meaning | Example |
|---|---|---|
| `scalar-host` | a pointer to one value, read or written on the host: `X_typed` takes the variable | `lwork` of a `_bufferSize` |
| `scalar-device` | a pointer to one value in device memory: no form takes a host variable | hipSOLVER's `devInfo` |
| `scalar-host-or-device` | a pointer to one value, on the host or the device as the handle's pointer mode says | BLAS `alpha`, `beta` |
| `struct-array` | a pointer to a C struct that is an array, `type(T) :: x(*)`, not one element | hipFFTW's `dims` |
| `function-pointer` | a function pointer declared `void*`: `type(c_funptr), value` | a kernel |

**How is it passed?**

| Value | Meaning | Example |
|---|---|---|
| `by-value` | by value although its C type is a pointer | `extra` of `hipModuleLaunchKernel` |
| `by-reference` | an array of pointers kept by reference, so a caller can pass one pointer variable | `rocfft_execute`'s buffers |

**Its rank in the array forms** (F2008 and F2018)

| Value | Meaning | Example |
|---|---|---|
| `1d`, `2d`, `3d` | that rank, where the natural rank above is wrong | `rotg_strided_batched`'s per-batch scalars: `1d` |
| `any-rank` | rank 0 to 3, all buffers alike, instead of `_full_rank` | an FFT's data, whose rank the plan decides |

**Adjustments**

| Value | Meaning | Example |
|---|---|---|
| `nullable` | the C API accepts NULL: `optional` in the forms that take Fortran variables | rocSPARSE's `p_error` |
| `always-c-ptr` | a buffer that stays `type(c_ptr)` in the array forms too; not for scalars, whose array forms already have a `_devptr` twin | a batch of results |

**A function** can also say `fortran-arrays = false` in its table: no array forms.
Every function with a data buffer gets them otherwise.

### Checking

- `./gen.sh --explain <c-function> ...` prints the table that applies to each function and where it comes from;
  with `ROCM_SYSTEMS` / `ROCM_LIBRARIES`, from the checkouts' metadata:

  ```text
  $ ./gen.sh --explain rocblas_ddot_64
  rocblas_ddot_64: src/rocblas/metadata/rocblas.toml
    ["rocblas_{s,d,h,bf}dot"] (inherited from rocblas_ddot)
      result = "scalar-host-or-device"
  ```

- A malformed file stops the generation: an unknown value, two answers to one question,
  `always-c-ptr` on a scalar, a function named twice, entries without `format = 1`.
- A table that matches no declared function, or an argument the function does not have,
  is reported as a warning (a typo, an API removed, or one newer than the headers read).
- A generation that adds a function whose arguments look like scalars (`alpha`, `beta`, ...) but are not classified
  reports it, so the bot's pull request can classify them.

## Checks

The first four run in CI on pushes to `main` and on pull requests; the others need the ROCm headers, and the last a GPU.

```bash
julia --project=src src/test/runtests.jl        # unit tests, no ROCm needed
julia --project=src src/test/compile_golden.jl  # the golden fixtures compile
julia --project=src src/test/array_ifaces.jl    # the array-overload tiers agree
bash src/test/gen_sh.sh                         # gen.sh's options and checks, no ROCm needed

./gen.sh                                        # the checks below need fortran/
bash check_mods.sh                              # the generated modules compile, under each array setting
bash check_compilers.sh                         # ... with every installed Fortran compiler

bash tests/run_all.sh                           # end-to-end tests, run on an AMD GPU
```

The end-to-end tests in `tests/` (a HIP kernel launch, rocBLAS SAXPY, hipBLAS DGEMM)
are built against `fortran/rocm-systems` and `fortran/rocm-libraries` and print `PASSED`.
Without a visible AMD GPU, `run_all.sh` only builds and links them.

## Versioning

The version is in `src/Project.toml` and follows semantic versioning; releases are tagged `vX.Y.Z`.

## Supported libraries

| Library | Module |
|---|---|
| HIP runtime | `hip` |
| ROCTx | `roctx` |
| rocBLAS | `rocblas` |
| rocSOLVER | `rocsolver` |
| rocSPARSE | `rocsparse` |
| rocFFT | `rocfft` |
| rocRAND | `rocrand` |
| hipBLAS | `hipblas` |
| hipSOLVER | `hipsolver` |
| hipSPARSE | `hipsparse` |
| hipFFT | `hipfft` |
| hipFFTW | `hipfftw` |
| hipRAND | `hiprand` |

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md). To report a vulnerability, see [`SECURITY.md`](SECURITY.md).

## Maintainers

| Role | Contact |
| --- | --- |
| Maintainer | Alexis Montoison ([@amontoison](https://github.com/amontoison)) |
| Product owner | Saad Rahim ([@saadrahim](https://github.com/saadrahim)) |

Pull requests are reviewed by [@ROCm/rocm-fortran-maintainers](https://github.com/orgs/ROCm/teams/rocm-fortran-maintainers).

## License

MIT, see [`LICENSE`](LICENSE).

## Acknowledgement

The generator was inspired by the Julia bindings that
[AMDGPU.jl](https://github.com/JuliaGPU/AMDGPU.jl) generates with Clang.jl.
It uses the same parser, [Clang.jl](https://github.com/JuliaInterop/Clang.jl), as a dependency;
the code that turns the parsed declarations into Fortran was written for this project.
