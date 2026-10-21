# Contributing to rocm-fortran-generator

Contributions are welcome: bug reports, missing or wrong bindings, and support
for new ROCm libraries.

> [!IMPORTANT]
> AMD employees must also follow the ROCm open source software
> contributing policies at http://u.amd.com/rocm-oss-policies.

## Governance

This project follows the [ROCm project governance](https://github.com/ROCm/ROCm/blob/develop/GOVERNANCE.md),
which includes the code of conduct.

## Licensing

Code contributions to this project are covered under the terms of the
[LICENSE](LICENSE) file.

## Reporting issues

Use GitHub issues. For a wrong or missing binding, include the C declaration
from the header, the Fortran you expected, and the ROCm version
(`/opt/rocm/.info/version`; after `./gen.sh`, `fortran/.provenance` also records
the HIP version, the generation settings and the generator commit).
Security issues follow [SECURITY.md](SECURITY.md) instead.

## Pull requests

- External contributors open the pull request from a fork.
  AMD employees open it from a branch of this repository (`users/<github-user>/<topic>`),
  not from a personal fork, so the ROCm organization's security checks apply before anything is pushed.
- Run the unit tests before submitting:
  `julia --project=src src/test/runtests.jl`.
  A change to the generated output should also pass the [checks](README.md#checks).
- Most binding fixes are a one-line change to a library's metadata file;
  see [Fixing a binding](README.md#fixing-a-binding).
- Every pull request needs an approving review from a code owner
  ([.github/CODEOWNERS](.github/CODEOWNERS)) before it is merged.
