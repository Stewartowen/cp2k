!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright (C) 2000 - 2019  CP2K developers group                                               !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief constants for the different operators of the 2c-integrals
!> \par History
!>      10.2016 created Dorothea Golze
!>      05.2019 added truncated Coulomb operator (A. Bussy)
! **************************************************************************************************
MODULE constants_operator

   IMPLICIT NONE
   PRIVATE

   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'constants_operator'

   ! operators for integrals
   INTEGER, PARAMETER, PUBLIC                :: operator_coulomb = 0, &
                                                operator_verf = 1, &
                                                operator_verfc = 2, &
                                                operator_vgauss = 3, &
                                                operator_gauss = 4, &
                                                operator_truncated = 5

END MODULE constants_operator
