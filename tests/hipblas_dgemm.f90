!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! Copyright (C) 2026 Advanced Micro Devices, Inc. All rights reserved.
!
! SPDX-License-Identifier: MIT
!
! Permission is hereby granted, free of charge, to any person obtaining a copy
! of this software and associated documentation files (the "Software"), to deal
! in the Software without restriction, including without limitation the rights
! to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
! copies of the Software, and to permit persons to whom the Software is
! furnished to do so, subject to the following conditions:
!
! The above copyright notice and this permission notice shall be included in
! all copies or substantial portions of the Software.
!
! THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
! IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
! FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
! AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
! LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
! OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
! THE SOFTWARE.
!
!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!

! Ported from hipfort/test/f2008/hipblas/dgemm.f03. hipMemcpy counts are in elements.
program hipblas_dgemm_test

  use iso_c_binding
  use hip
  use hipblas
  implicit none

  integer(kind(HIPBLAS_OP_N)), parameter :: transa = HIPBLAS_OP_N, transb = HIPBLAS_OP_N
  double precision, parameter :: alpha = 1.1d0, beta = 0.9d0
  integer, parameter :: m = 1024, n = 1024, k = 1024

  double precision, allocatable, dimension(:,:) :: ha, hb, hc, hc_exact
  double precision, pointer,     dimension(:,:) :: da, db, dc
  type(c_ptr) :: handle = c_null_ptr

  integer :: i, j
  double precision :: error
  double precision, parameter :: error_max = 10*epsilon(error)

  write(*,"(a)",advance="no") "-- Running test 'DGEMM' (rocm-fortran-generator) - "

  call hipblasCheck(hipblasCreate(handle))

  allocate(ha(m,k), hb(k,n), hc(m,n), hc_exact(m,n))
  ha(:,:) = 1.d0
  hb(:,:) = 2.d0
  hc(:,:) = 3.d0
  hc_exact = alpha*k*2.d0 + beta*3.d0

  call hipCheck(hipMalloc(da, size(ha,1), size(ha,2)))
  call hipCheck(hipMalloc(db, size(hb,1), size(hb,2)))
  call hipCheck(hipMalloc(dc, size(hc,1), size(hc,2)))
  call hipCheck(hipMemcpy(da, ha, int(size(ha), c_size_t), hipMemcpyHostToDevice))
  call hipCheck(hipMemcpy(db, hb, int(size(hb), c_size_t), hipMemcpyHostToDevice))
  call hipCheck(hipMemcpy(dc, hc, int(size(hc), c_size_t), hipMemcpyHostToDevice))

  call hipblasCheck(hipblasDgemm(handle, transa, transb, m, n, k, &
       alpha, da, size(da,1), db, size(db,1), beta, dc, size(dc,1)))
  call hipCheck(hipDeviceSynchronize())

  call hipCheck(hipMemcpy(hc, dc, int(size(hc), c_size_t), hipMemcpyDeviceToHost))

  do j = 1, n
    do i = 1, m
      error = abs((hc_exact(i,j) - hc(i,j))/hc_exact(i,j))
      if (error > error_max) then
        write(*,*) "FAILED! Error = ", error
        stop 1
      end if
    end do
  end do

  call hipCheck(hipFree(da))
  call hipCheck(hipFree(db))
  call hipCheck(hipFree(dc))
  call hipblasCheck(hipblasDestroy(handle))
  deallocate(ha, hb, hc, hc_exact)

  write(*,*) "PASSED!"

end program hipblas_dgemm_test
