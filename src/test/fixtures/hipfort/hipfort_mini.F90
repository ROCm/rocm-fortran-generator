!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!
! Copyright (C) 2020-2026 Advanced Micro Devices, Inc. All rights reserved.
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

module hipfort_mini
  use hipfort_mini_enums
  use hipfort_mini_types
  implicit none

  !>  @brief Create a mini handle.
  interface mini_create
#ifdef USE_CUDA_NAMES
    function mini_create_(handle) bind(c, name="cuminiCreate")
#else
    function mini_create_(handle) bind(c, name="mini_create")
#endif
      import
      implicit none
      integer(c_int) :: mini_create_
      type(c_ptr) :: handle
    end function
  end interface

  !>  @brief Single-precision complex scale.
#ifndef USE_CUDA_NAMES
  interface mini_cscal
    function mini_cscal_(handle,n,x,op) bind(c, name="mini_cscal")
      import
      implicit none
      integer(c_int) :: mini_cscal_
      type(c_ptr),value :: handle
      integer(c_int),value :: n
      type(c_ptr),value :: x
      integer(c_int),value :: op
    end function

#ifdef USE_ASSUMED_RANK
    module procedure mini_cscal_assumed_rank
#else
#ifdef USE_ASSUMED_SHAPE
    module procedure &
      mini_cscal_rank_0,&
      mini_cscal_rank_1
#endif
#endif
  end interface
#endif

  !>  @brief Double scale with a tag and a host output.
  interface mini_dscal
#ifdef USE_CUDA_NAMES
    function mini_dscal_(handle,n,x,tag,myInfo) bind(c, name="cuminiDscal")
#else
    function mini_dscal_(handle,n,x,tag,myInfo) bind(c, name="mini_dscal")
#endif
      import
      implicit none
      integer(c_int) :: mini_dscal_
      type(c_ptr),value :: handle
      integer(c_int),value :: n
      type(c_ptr),value :: x
      type(c_ptr),value :: tag
      type(c_ptr),value :: myInfo
    end function

    module procedure mini_dscal_typed

#ifdef USE_ASSUMED_RANK
    module procedure mini_dscal_assumed_rank
#else
#ifdef USE_ASSUMED_SHAPE
    module procedure &
      mini_dscal_rank_0,&
      mini_dscal_rank_1
#endif
#endif
  end interface

#ifndef USE_CUDA_NAMES
  interface mini_destroy
    function mini_destroy_(handle) bind(c, name="mini_destroy")
      import
      implicit none
      integer(c_int) :: mini_destroy_
      type(c_ptr),value :: handle
    end function
  end interface
#endif

  !>  @brief Read the handle's parameters into a struct.
#ifndef USE_CUDA_NAMES
  interface mini_get_params
    function mini_get_params_(handle,params) bind(c, name="mini_get_params")
      import
      implicit none
      integer(c_int) :: mini_get_params_
      type(c_ptr),value :: handle
      type(mini_params_t) :: params
    end function
  end interface
#endif

  !>  @brief Record a tagged sample (returns nothing).
#ifndef USE_CUDA_NAMES
  interface mini_record
    subroutine mini_record_(handle,x,tag) bind(c, name="mini_record")
      import
      implicit none
      type(c_ptr),value :: handle
      type(c_ptr),value :: x
      type(c_ptr),value :: tag
    end subroutine

#ifdef USE_ASSUMED_RANK
    module procedure mini_record_assumed_rank
#else
#ifdef USE_ASSUMED_SHAPE
    module procedure &
      mini_record_rank_0,&
      mini_record_rank_1
#endif
#endif
  end interface
#endif

#ifndef USE_CUDA_NAMES
  interface mini_set_mode_v2
    function mini_set_mode_v2_(mode) bind(c, name="mini_set_mode_v2")
      import
      implicit none
      integer(c_int) :: mini_set_mode_v2_
      integer(c_int),value :: mode
    end function
  end interface
#endif

#ifndef USE_CUDA_NAMES
  interface mini_reset
    function mini_reset_() bind(c, name="mini_reset")
      import
      implicit none
      integer(c_int) :: mini_reset_
    end function
  end interface
#endif

  !>  @brief Choose a device (documented on the forwarder only).
#ifndef USE_CUDA_NAMES
  interface mini_choose_R0600
    function mini_choose_R0600_(device) bind(c, name="mini_choose_R0600")
      import
      implicit none
      integer(c_int) :: mini_choose_R0600_
      integer(c_int),value :: device
    end function
  end interface
#endif

  !>  @brief Choose a device (documented on the forwarder only).
#ifndef USE_CUDA_NAMES
  interface mini_choose
    procedure mini_choose_R0600_
  end interface
#endif

  !>  @brief Double scale with a tag and a host output.
  interface miniScale
    procedure mini_dscal_

    module procedure mini_dscal_typed

#ifdef USE_ASSUMED_RANK
    module procedure mini_dscal_assumed_rank
#else
#ifdef USE_ASSUMED_SHAPE
    module procedure &
      mini_dscal_rank_0,&
      mini_dscal_rank_1
#endif
#endif
  end interface

#ifndef USE_CUDA_NAMES
  interface mini_set_mode
    procedure mini_set_mode_v2_
  end interface
#endif


  contains

    function mini_dscal_typed(handle,n,x,tag,myInfo)
      implicit none
      integer(kind(MINI_STATUS_SUCCESS)) :: mini_dscal_typed
      type(c_ptr), value :: handle
      integer(c_int) :: n
      type(c_ptr) :: x
      type(c_ptr), value :: tag
      integer(c_int),target :: myInfo
      !
      mini_dscal_typed = mini_dscal_(handle,n,x,tag,c_loc(myInfo))
    end function


#if defined(USE_ASSUMED_SHAPE) || defined(USE_ASSUMED_RANK)

#ifndef USE_CUDA_NAMES
#ifdef USE_ASSUMED_RANK
    function mini_cscal_assumed_rank(handle,n,x,op)
      implicit none
      integer(kind(MINI_STATUS_SUCCESS)) :: mini_cscal_assumed_rank
      type(c_ptr), value :: handle
      integer(c_int) :: n
      complex(c_float_complex),target,dimension(..) :: x
      integer(kind(MINI_OP_N)) :: op
      !
      mini_cscal_assumed_rank = mini_cscal_(handle,n,c_loc(x),op)
    end function

#else
    function mini_cscal_rank_0(handle,n,x,op)
      implicit none
      integer(kind(MINI_STATUS_SUCCESS)) :: mini_cscal_rank_0
      type(c_ptr), value :: handle
      integer(c_int) :: n
      complex(c_float_complex),target :: x
      integer(kind(MINI_OP_N)) :: op
      !
      mini_cscal_rank_0 = mini_cscal_(handle,n,c_loc(x),op)
    end function

    function mini_cscal_rank_1(handle,n,x,op)
      implicit none
      integer(kind(MINI_STATUS_SUCCESS)) :: mini_cscal_rank_1
      type(c_ptr), value :: handle
      integer(c_int) :: n
      complex(c_float_complex),target,dimension(:) :: x
      integer(kind(MINI_OP_N)) :: op
      !
      mini_cscal_rank_1 = mini_cscal_(handle,n,c_loc(x),op)
    end function

#endif
#endif
#ifdef USE_ASSUMED_RANK
    function mini_dscal_assumed_rank(handle,n,x,tag,myInfo)
      implicit none
      integer(kind(MINI_STATUS_SUCCESS)) :: mini_dscal_assumed_rank
      type(c_ptr), value :: handle
      integer(c_int) :: n
      real(c_double),target,dimension(..) :: x
      type(c_ptr), value :: tag
      integer(c_int),target :: myInfo
      !
      mini_dscal_assumed_rank = mini_dscal_(handle,n,c_loc(x),tag,c_loc(myInfo))
    end function

#else
    function mini_dscal_rank_0(handle,n,x,tag,myInfo)
      implicit none
      integer(kind(MINI_STATUS_SUCCESS)) :: mini_dscal_rank_0
      type(c_ptr), value :: handle
      integer(c_int) :: n
      real(c_double),target :: x
      type(c_ptr), value :: tag
      integer(c_int),target :: myInfo
      !
      mini_dscal_rank_0 = mini_dscal_(handle,n,c_loc(x),tag,c_loc(myInfo))
    end function

    function mini_dscal_rank_1(handle,n,x,tag,myInfo)
      implicit none
      integer(kind(MINI_STATUS_SUCCESS)) :: mini_dscal_rank_1
      type(c_ptr), value :: handle
      integer(c_int) :: n
      real(c_double),target,dimension(:) :: x
      type(c_ptr), value :: tag
      integer(c_int),target :: myInfo
      !
      mini_dscal_rank_1 = mini_dscal_(handle,n,c_loc(x),tag,c_loc(myInfo))
    end function

#endif
#ifndef USE_CUDA_NAMES
#ifdef USE_ASSUMED_RANK
    subroutine mini_record_assumed_rank(handle,x,tag)
      implicit none
      type(c_ptr), value :: handle
      real(c_double),target,dimension(..) :: x
      type(c_ptr), value :: tag
      !
      call mini_record_(handle,c_loc(x),tag)
    end subroutine

#else
    subroutine mini_record_rank_0(handle,x,tag)
      implicit none
      type(c_ptr), value :: handle
      real(c_double),target :: x
      type(c_ptr), value :: tag
      !
      call mini_record_(handle,c_loc(x),tag)
    end subroutine

    subroutine mini_record_rank_1(handle,x,tag)
      implicit none
      type(c_ptr), value :: handle
      real(c_double),target,dimension(:) :: x
      type(c_ptr), value :: tag
      !
      call mini_record_(handle,c_loc(x),tag)
    end subroutine

#endif
#endif
#endif
end module hipfort_mini
