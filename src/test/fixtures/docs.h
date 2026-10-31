// Copyright (C) 2026 Advanced Micro Devices, Inc. All rights reserved.
// SPDX-License-Identifier: MIT
/* Fixture for the doc comments collect_funcs records (FUNC_DOCS): a doxygen block
   documents a group of declarations, and is carried to those without one. */

/*! \brief dot, in the rocBLAS style: the name on the line after @param.

    @param[in]
    n         [int]
              the number of elements.
    @param[in]
    x         device pointer storing vector x.
    @param[in, out]
    result
              device pointer or host pointer to store the dot product.

    ********************************************************************/
int docs_sdot(int n, const float* x, float* result);
/* not a doc comment: the block above is carried here */
int docs_ddot(int n, const double* x, double* result);

/**
 * @brief Another group, in the HIP style.
 * @param [out] bytes The size in bytes
 * @returns #docsSuccess
 */
int docs_mem(unsigned long* bytes);
/* Names none of the block's arguments: nothing carried. */
int docs_other(float* y, float* z);
