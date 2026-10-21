# Security Policy

## Reporting a vulnerability

If you have discovered a security vulnerability in rocm-fortran-generator,
do NOT report it publicly using a GitHub issue. Instead, report the issue
through the [AMD Product Security website](https://www.amd.com/en/resources/product-security.html).

Please include: a description and the impact, the steps to reproduce, and the affected versions or commits.

## Scope

This repository contains a code generator, not a library that ships in ROCm.
It runs offline (by a developer or in CI) and reads public C headers to write
Fortran source files, which are then reviewed and committed to
[rocm-libraries](https://github.com/ROCm/rocm-libraries) and
[rocm-systems](https://github.com/ROCm/rocm-systems).
A vulnerability in the generated bindings should be reported the same way.
For a vulnerability in a third-party dependency (Clang.jl, libclang, Julia), report it upstream.
