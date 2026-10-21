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

! Ported from hipfort/test/f2008/vecadd/main.f03: launches the HIP C++ kernel in
! vecadd_kernel.cpp and checks out = a + b. hipMemcpy counts are in elements.
program vecadd

  use iso_c_binding
  use hip
  implicit none

  interface
    subroutine launch(grid, block, shmem, stream, out, a, b, N) bind(c)
      use iso_c_binding
      use hip, only: dim3
      implicit none
      type(dim3)            :: grid, block
      integer(c_int), value :: shmem, N
      type(c_ptr),    value :: stream, out, a, b
    end subroutine launch
  end interface

  integer(c_int), parameter :: N = 1000000

  real(8), allocatable, target, dimension(:) :: a, b, out
  real(8), pointer,             dimension(:) :: da => null(), db => null(), dout => null()

  write(*,"(a)",advance="no") "-- Running test 'vecadd' (rocm-fortran-generator) - "

  allocate(a(N), b(N), out(N))
  a(:) = 1.0d0
  b(:) = 1.0d0

  call hipCheck(hipMalloc(da,   N))
  call hipCheck(hipMalloc(db,   N))
  call hipCheck(hipMalloc(dout, N))

  call hipCheck(hipMemcpy(da, a, int(N, c_size_t), hipMemcpyHostToDevice))
  call hipCheck(hipMemcpy(db, b, int(N, c_size_t), hipMemcpyHostToDevice))

  call launch(dim3(320,1,1), dim3(256,1,1), 0, c_null_ptr, &
              c_loc(dout), c_loc(da), c_loc(db), N)
  call hipCheck(hipDeviceSynchronize())

  call hipCheck(hipMemcpy(out, dout, int(N, c_size_t), hipMemcpyDeviceToHost))

  if (sum(out) == N * 2.0d0) then
    write(*,*) "PASSED!"
  else
    write(*,*) "FAILED!"
    stop 1
  end if

  call hipCheck(hipFree(da))
  call hipCheck(hipFree(db))
  call hipCheck(hipFree(dout))
  deallocate(a, b, out)

end program vecadd
