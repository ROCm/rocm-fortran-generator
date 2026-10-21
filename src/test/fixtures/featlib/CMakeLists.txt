# Copyright (C) 2026 Advanced Micro Devices, Inc. All rights reserved.
# SPDX-License-Identifier: MIT
# Fixture CMake defaults for auto_feature_defines. Exercises every resolution
# path: a direct option(), the set(WITH ${ENABLE}) indirection, an OFF default,
# the BUILD_WITH_ variant, and a flag with no matching option (unresolved).
option(FEATLIB_WITH_FOO "direct ON" ON)
set(FEATLIB_WITH_BAR ${ENABLE_BAR})
option(ENABLE_BAR "indirection ON" ON)
option(FEATLIB_WITH_OFF "default OFF" OFF)
option(BUILD_WITH_BUILD "BUILD_WITH_ variant ON" ON)
# FEATLIB_WITH_MISSING has no option() -> stays unresolved
