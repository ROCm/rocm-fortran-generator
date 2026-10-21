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

! Ported from hipfort/test/f2008/rocblas/saxpy.f03. hipMemcpy counts are in elements.
program rocblas_saxpy_test

  use iso_c_binding
  use hip
  use rocblas
  implicit none

  integer, parameter :: N = 12000
  real(c_float), target :: alpha = 12.5

  real, allocatable, target, dimension(:) :: hx, hy, hz
  real, pointer,     dimension(:) :: dx, dy

  real :: error, result
  real, parameter :: error_max = 10 * epsilon(error_max)
  type(c_ptr) :: handle
  integer :: i

  write(*,"(a)",advance="no") "-- Running test 'saxpy' (rocm-fortran-generator) - "

  call rocblasCheck(rocblas_create_handle(handle))

  allocate(hx(N), hy(N), hz(N))
  do i = 1, N
    hx(i) = i
    hy(i) = N - i
    hz(i) = N - i
  end do

  call hipCheck(hipMalloc(dx, N))
  call hipCheck(hipMalloc(dy, N))
  call hipCheck(hipMemcpy(dx, hx, int(N, c_size_t), hipMemcpyHostToDevice))
  call hipCheck(hipMemcpy(dy, hy, int(N, c_size_t), hipMemcpyHostToDevice))

  call rocblasCheck(rocblas_set_pointer_mode(handle, 0))   ! host pointer mode
  call rocblasCheck(rocblas_saxpy(handle, N, alpha, dx, 1, dy, 1))
  call hipCheck(hipDeviceSynchronize())

  call hipCheck(hipMemcpy(hy, dy, int(N, c_size_t), hipMemcpyDeviceToHost))

  do i = 1, N
    result = alpha * hx(i) + hz(i)
    error  = abs(hy(i) - result)
    if (error > error_max) then
      write(*,*) "FAILED! Error = ", error, " hy(", i, ") = ", hy(i)
      stop 1
    end if
  end do

  call hipCheck(hipFree(dx))
  call hipCheck(hipFree(dy))
  deallocate(hx, hy, hz)
  call rocblasCheck(rocblas_destroy_handle(handle))

  write(*,*) "PASSED!"

end program rocblas_saxpy_test
