# Copyright (C) 2026 Advanced Micro Devices, Inc. All rights reserved.
# SPDX-License-Identifier: MIT
# Fixture CMake for synth_generated_headers: the version is declared the way rocRAND
# declares it (a literal to rocm_setup_version, then a math(EXPR) number in a
# lower-case variable), and a second, set()-driven version for the TWEAK/commit id
# that a build stamps from git and that must stay unresolved.
cmake_minimum_required(VERSION 3.16)
project(VerLib CXX)
set ( verlib_VERSION_COMMIT_ID "${GIT_HASH_VERLIB}" )
rocm_setup_version( VERSION "5.2.7" )
math(EXPR verlib_VERSION_NUMBER "${VerLib_VERSION_MAJOR} * 100000 + ${VerLib_VERSION_MINOR} * 100 + ${VerLib_VERSION_PATCH}")
