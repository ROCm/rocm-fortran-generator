# rocm-fortran-generator

Generates the Fortran bindings of the HIP runtime, ROCTx and the ROCm math libraries from their C headers.

It parses the headers with [Clang.jl](https://github.com/JuliaInterop/Clang.jl) and emits, for each library,
a Fortran module with the `bind(C)` interfaces, the enum constants, the derived types,
an error-check helper, and overloads that take Fortran arrays and scalars directly.
The generated modules are committed next to the C headers in
[rocm-systems](https://github.com/ROCm/rocm-systems) and [rocm-libraries](https://github.com/ROCm/rocm-libraries).
This repository holds only the generator.
[docs/design-notes.md](docs/design-notes.md) explains the design: the build artifacts, why a `.mod` only works with the compiler that built it,
how C constructs without a Fortran equivalent are mapped, the curated metadata, and how the generator is tested.

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
4. Run `./gen.sh && bash check_mods.sh`, then add metadata files in `src/<lib>/metadata/` as needed (see [Fixing a binding](#fixing-a-binding)).

If the generator finds far fewer functions than expected, check the `prefix` spelling and the header it parses.

### The `<lib>.toml` keys

| Key | Default | Effect |
|---|---|---|
| `[general] name` | required | the library and module name, and the metadata file prefix |
| `[library] prefix` | required | only functions whose name starts with it are bound |
| `[library] opaque_handles` | required (may be `[]`) | struct tags never emitted as derived types (handles) |
| `[library] own_headers` | `[name]` | header-path markers of the files whose enums, structs and macros are this library's |
| `[library] reexport_enums` | `[]` | sibling libraries whose enums are `use`d from the sibling module instead of copied (rocSOLVER: `["rocblas"]`) |
| `[library] keep_structs` | `[]` | HIP vector types to emit anyway, when a function takes one by value (rocRAND: `["uint4"]`) |
| `[library] string_args` | `false` | `const char*` inputs also take a Fortran string in the `_typed` form |
| `[library] alias_function_macros` | `false` | bind the documented name of a forwarding macro to its ABI symbol (ROCTx: `roctxMark` to `roctxMarkA`) |
| `[library] enum_rename` | none | `["FROM_", "TO_"]`: respell the module's enumerators (hipSOLVER: `HIPBLAS_` to `HIPSOLVER_`) |
| `[library] metadata_dir` | `src/<lib>/metadata/` | the metadata files' directory (`generate_all.jl` passes a checkout's) |
| `[headers] subdir`, `file` | `name`, `<subdir>.h` | the one header parsed (see step 1) |
| `[clang] defines` | `[]` | `-D` definitions for the parse |
| `[clang] extra_include_dirs` | `[]` | `-I` directories, relative to the include dir; missing ones are skipped |
| `[clang] extra_args` | `[]` | other Clang arguments |
| `[check] success` | detected | the status constant meaning success, for the `<lib>Check` helper |
| `[check] name` | `<name>Check` | the name of that helper |

## Fixing a binding

The generated Fortran is never edited by hand.
What the C headers cannot express is supplied by small metadata files in `src/<lib>/metadata/`,
one entry per line, keyed by the C function name; then regenerate the library.
When a run reads a checkout, the `metadata/` directory next to the library's Fortran module in that checkout
(`projects/fortran/metadata/` in rocm-systems, `projects/<proj>/fortran/metadata/` in rocm-libraries)
replaces the generator's copy.

| File | Entry | Effect |
|---|---|---|
| `<lib>.argkinds` | `func arg ...` | a pointer argument is a scalar, not a buffer: the `bind(C)` form keeps `type(c_ptr)` and a `_typed` form takes the Fortran variable |
| `<lib>.native` | `func`, `func <rank>`, `func full` | the routine gets overloads that take Fortran arrays (up to that rank, or a full 2-D matrix) |
| `<lib>.cptrargs` | `func arg ...` | a buffer stays a plain `type(c_ptr)` in the array overloads |
| `<lib>.optional` | `func arg ...` | a by-reference argument the C API allows to be NULL is `optional` |
| `<lib>.arrayargs` | `func arg ...` | a `const T*` to a derived type is an array, `type(T) :: x(*)` |
| `<lib>.byvalue` | `func arg ...` | the argument is passed by value |
| `<lib>.funptrargs` | `func arg ...` | the argument is a `type(c_funptr)` |
| `<lib>.ptrmode`, `<lib>.devonly` | `func arg ...` | scalars read per the library's pointer mode (a subset of `.argkinds`), and scalars written by the device |

An ILP64 (`_64`) or `_v2` variant inherits its base function's entry in `.argkinds`, `.native`,
`.cptrargs`, `.ptrmode` and `.devonly`, so the base name is listed once for all of them.

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
