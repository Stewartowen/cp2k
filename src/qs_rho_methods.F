!--------------------------------------------------------------------------------------------------!
!   CP2K: A general program to perform molecular dynamics simulations                              !
!   Copyright (C) 2000 - 2019  CP2K developers group                                               !
!--------------------------------------------------------------------------------------------------!

! **************************************************************************************************
!> \brief methods of the rho structure (defined in qs_rho_types)
!> \par History
!>      08.2002 created [fawzi]
!>      08.2014 kpoints [JGH]
!> \author Fawzi Mohamed
! **************************************************************************************************
MODULE qs_rho_methods
   USE atomic_kind_types,               ONLY: atomic_kind_type
   USE cp_control_types,                ONLY: dft_control_type
   USE cp_dbcsr_cp2k_link,              ONLY: cp_dbcsr_alloc_block_from_nbl
   USE cp_dbcsr_operations,             ONLY: dbcsr_allocate_matrix_set,&
                                              dbcsr_deallocate_matrix_set
   USE cp_log_handling,                 ONLY: cp_to_string
   USE cp_para_types,                   ONLY: cp_para_env_type
   USE dbcsr_api,                       ONLY: dbcsr_copy,&
                                              dbcsr_create,&
                                              dbcsr_p_type,&
                                              dbcsr_set,&
                                              dbcsr_type,&
                                              dbcsr_type_symmetric
   USE kinds,                           ONLY: default_string_length,&
                                              dp
   USE kpoint_types,                    ONLY: get_kpoint_info,&
                                              kpoint_type
   USE lri_environment_methods,         ONLY: calculate_lri_densities
   USE lri_environment_types,           ONLY: lri_density_type,&
                                              lri_environment_type
   USE pw_env_types,                    ONLY: pw_env_get,&
                                              pw_env_type
   USE pw_methods,                      ONLY: pw_zero
   USE pw_pool_types,                   ONLY: pw_pool_create_pw,&
                                              pw_pool_type
   USE pw_types,                        ONLY: COMPLEXDATA1D,&
                                              REALDATA3D,&
                                              REALSPACE,&
                                              RECIPROCALSPACE,&
                                              pw_p_type,&
                                              pw_release
   USE qs_collocate_density,            ONLY: calculate_drho_elec,&
                                              calculate_rho_elec
   USE qs_environment_types,            ONLY: get_qs_env,&
                                              qs_environment_type,&
                                              set_qs_env
   USE qs_ks_types,                     ONLY: get_ks_env,&
                                              qs_ks_env_type
   USE qs_local_rho_types,              ONLY: local_rho_type
   USE qs_neighbor_list_types,          ONLY: neighbor_list_set_p_type
   USE qs_rho_atom_methods,             ONLY: calculate_rho_atom_coeff
   USE qs_rho_types,                    ONLY: qs_rho_clear,&
                                              qs_rho_get,&
                                              qs_rho_set,&
                                              qs_rho_type
   USE ri_environment_methods,          ONLY: calculate_ri_densities
   USE task_list_types,                 ONLY: task_list_type
#include "./base/base_uses.f90"

   IMPLICIT NONE
   PRIVATE

   LOGICAL, PRIVATE, PARAMETER :: debug_this_module = .TRUE.
   CHARACTER(len=*), PARAMETER, PRIVATE :: moduleN = 'qs_rho_methods'

   PUBLIC :: qs_rho_update_rho, qs_rho_rebuild, duplicate_rho_type

CONTAINS

! **************************************************************************************************
!> \brief rebuilds rho (if necessary allocating and initializing it)
!> \param rho the rho type to rebuild (defaults to qs_env%rho)
!> \param qs_env the environment to which rho belongs
!> \param rebuild_ao if it is necessary to rebuild rho_ao. Defaults to true.
!> \param rebuild_grids if it in necessary to rebuild rho_r and rho_g.
!>        Defaults to false.
!> \param admm (use aux_fit basis)
!> \param pw_env_external external plane wave environment
!> \par History
!>      11.2002 created replacing qs_rho_create and qs_env_rebuild_rho[fawzi]
!> \author Fawzi Mohamed
!> \note
!>      needs updated  pw pools, s, s_mstruct and h in qs_env.
!>      The use of p to keep the structure of h (needed for the forces)
!>      is ugly and should be removed.
!>      Change so that it does not allocate a subcomponent if it is not
!>      associated and not requested?
! **************************************************************************************************
   SUBROUTINE qs_rho_rebuild(rho, qs_env, rebuild_ao, rebuild_grids, admm, pw_env_external)
      TYPE(qs_rho_type), POINTER                         :: rho
      TYPE(qs_environment_type), POINTER                 :: qs_env
      LOGICAL, INTENT(in), OPTIONAL                      :: rebuild_ao, rebuild_grids, admm
      TYPE(pw_env_type), OPTIONAL, POINTER               :: pw_env_external

      CHARACTER(LEN=*), PARAMETER :: routineN = 'qs_rho_rebuild', routineP = moduleN//':'//routineN

      CHARACTER(LEN=default_string_length)               :: headline
      INTEGER                                            :: handle, i, ic, nimg, nspins
      LOGICAL                                            :: do_kpoints, my_admm, my_rebuild_ao, &
                                                            my_rebuild_grids
      REAL(KIND=dp), DIMENSION(:), POINTER               :: tot_rho_r
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: matrix_s
      TYPE(dbcsr_p_type), DIMENSION(:, :), POINTER       :: matrix_s_kp, rho_ao_kp
      TYPE(dbcsr_type), POINTER                          :: refmatrix, tmatrix
      TYPE(dft_control_type), POINTER                    :: dft_control
      TYPE(kpoint_type), POINTER                         :: kpoints
      TYPE(neighbor_list_set_p_type), DIMENSION(:), &
         POINTER                                         :: sab_orb
      TYPE(pw_env_type), POINTER                         :: pw_env
      TYPE(pw_p_type), DIMENSION(:), POINTER             :: drho_g, drho_r, rho_g, rho_r, tau_g, &
                                                            tau_r
      TYPE(pw_p_type), POINTER                           :: rho_r_sccs
      TYPE(pw_pool_type), POINTER                        :: auxbas_pw_pool

      CALL timeset(routineN, handle)

      NULLIFY (pw_env, auxbas_pw_pool, matrix_s, matrix_s_kp, dft_control)
      NULLIFY (tot_rho_r, rho_ao_kp, rho_r, rho_g, drho_r, drho_g, tau_r, tau_g)
      NULLIFY (rho_r_sccs)
      NULLIFY (sab_orb)
      my_rebuild_ao = .TRUE.
      my_rebuild_grids = .TRUE.
      my_admm = .FALSE.
      IF (PRESENT(rebuild_ao)) my_rebuild_ao = rebuild_ao
      IF (PRESENT(rebuild_grids)) my_rebuild_grids = rebuild_grids
      IF (PRESENT(admm)) my_admm = admm

      CALL get_qs_env(qs_env, &
                      kpoints=kpoints, &
                      do_kpoints=do_kpoints, &
                      pw_env=pw_env, &
                      dft_control=dft_control)
      IF (PRESENT(pw_env_external)) &
         pw_env => pw_env_external

      nimg = dft_control%nimages

      IF (my_admm) THEN
         CPASSERT(.NOT. do_kpoints)
         CALL get_qs_env(qs_env, matrix_s_aux_fit=matrix_s, sab_aux_fit=sab_orb)
         refmatrix => matrix_s(1)%matrix
      ELSE
         CALL get_qs_env(qs_env, matrix_s_kp=matrix_s_kp, sab_orb=sab_orb)
         refmatrix => matrix_s_kp(1, 1)%matrix
      END IF

      CALL pw_env_get(pw_env, auxbas_pw_pool=auxbas_pw_pool)
      nspins = dft_control%nspins

      IF (.NOT. ASSOCIATED(rho)) CPABORT("rho not associated")
      CALL qs_rho_get(rho, &
                      tot_rho_r=tot_rho_r, &
                      rho_ao_kp=rho_ao_kp, &
                      rho_r=rho_r, &
                      rho_g=rho_g, &
                      drho_r=drho_r, &
                      drho_g=drho_g, &
                      tau_r=tau_r, &
                      tau_g=tau_g, &
                      rho_r_sccs=rho_r_sccs)

      IF (.NOT. ASSOCIATED(tot_rho_r)) THEN
         ALLOCATE (tot_rho_r(nspins))
         tot_rho_r = 0.0_dp
         CALL qs_rho_set(rho, tot_rho_r=tot_rho_r)
      END IF

      ! rho_ao
      IF (my_rebuild_ao .OR. (.NOT. ASSOCIATED(rho_ao_kp))) THEN
         IF (ASSOCIATED(rho_ao_kp)) &
            CALL dbcsr_deallocate_matrix_set(rho_ao_kp)
         ! Create a new density matrix set
         CALL dbcsr_allocate_matrix_set(rho_ao_kp, nspins, nimg)
         CALL qs_rho_set(rho, rho_ao_kp=rho_ao_kp)
         DO i = 1, nspins
            DO ic = 1, nimg
               IF (nspins > 1) THEN
                  IF (i == 1) THEN
                     headline = "DENSITY MATRIX FOR ALPHA SPIN"
                  ELSE
                     headline = "DENSITY MATRIX FOR BETA SPIN"
                  END IF
               ELSE
                  headline = "DENSITY MATRIX"
               END IF
               ALLOCATE (rho_ao_kp(i, ic)%matrix)
               tmatrix => rho_ao_kp(i, ic)%matrix
               CALL dbcsr_create(matrix=tmatrix, template=refmatrix, name=TRIM(headline), &
                                 matrix_type=dbcsr_type_symmetric, nze=0)
               CALL cp_dbcsr_alloc_block_from_nbl(tmatrix, sab_orb)
               CALL dbcsr_set(tmatrix, 0.0_dp)
            END DO
         END DO
      END IF

      ! rho_r
      IF (my_rebuild_grids .OR. .NOT. ASSOCIATED(rho_r)) THEN
         IF (ASSOCIATED(rho_r)) THEN
            DO i = 1, SIZE(rho_r)
               CALL pw_release(rho_r(i)%pw)
            END DO
            DEALLOCATE (rho_r)
         END IF
         ALLOCATE (rho_r(nspins))
         CALL qs_rho_set(rho, rho_r=rho_r)
         DO i = 1, nspins
            CALL pw_pool_create_pw(auxbas_pw_pool, rho_r(i)%pw, &
                                   use_data=REALDATA3D, in_space=REALSPACE)
         END DO
      END IF

      ! rho_g
      IF (my_rebuild_grids .OR. .NOT. ASSOCIATED(rho_g)) THEN
         IF (ASSOCIATED(rho_g)) THEN
            DO i = 1, SIZE(rho_g)
               CALL pw_release(rho_g(i)%pw)
            END DO
            DEALLOCATE (rho_g)
         END IF
         ALLOCATE (rho_g(nspins))
         CALL qs_rho_set(rho, rho_g=rho_g)
         DO i = 1, nspins
            CALL pw_pool_create_pw(auxbas_pw_pool, rho_g(i)%pw, &
                                   use_data=COMPLEXDATA1D, in_space=RECIPROCALSPACE)
         END DO
      END IF

      ! SCCS
      IF (dft_control%do_sccs) THEN
         IF (my_rebuild_grids .OR. (.NOT. ASSOCIATED(rho_r_sccs))) THEN
            IF (ASSOCIATED(rho_r_sccs)) THEN
               CALL pw_release(rho_r_sccs%pw)
               DEALLOCATE (rho_r_sccs)
            END IF
            ALLOCATE (rho_r_sccs)
            CALL qs_rho_set(rho, rho_r_sccs=rho_r_sccs)
            CALL pw_pool_create_pw(auxbas_pw_pool, rho_r_sccs%pw, &
                                   use_data=REALDATA3D, &
                                   in_space=REALSPACE)
            CALL pw_zero(rho_r_sccs%pw)
         END IF
      END IF

      ! allocate drho_r and drho_g if xc_deriv_collocate
      IF (dft_control%drho_by_collocation) THEN
         ! drho_r
         IF (my_rebuild_grids .OR. .NOT. ASSOCIATED(drho_r)) THEN
            IF (ASSOCIATED(drho_r)) THEN
               DO i = 1, SIZE(drho_r)
                  CALL pw_release(drho_r(i)%pw)
               END DO
               DEALLOCATE (drho_r)
            END IF
            ALLOCATE (drho_r(3*nspins))
            CALL qs_rho_set(rho, drho_r=drho_r)
            DO i = 1, 3*nspins
               CALL pw_pool_create_pw(auxbas_pw_pool, drho_r(i)%pw, &
                                      use_data=REALDATA3D, in_space=REALSPACE)
            END DO
         END IF
         ! drho_g
         IF (my_rebuild_grids .OR. .NOT. ASSOCIATED(drho_g)) THEN
            IF (ASSOCIATED(drho_g)) THEN
               DO i = 1, SIZE(drho_g)
                  CALL pw_release(drho_g(i)%pw)
               END DO
               DEALLOCATE (drho_g)
            END IF
            ALLOCATE (drho_g(3*nspins))
            CALL qs_rho_set(rho, drho_g=drho_g)
            DO i = 1, 3*nspins
               CALL pw_pool_create_pw(auxbas_pw_pool, drho_g(i)%pw, &
                                      use_data=COMPLEXDATA1D, in_space=RECIPROCALSPACE)
            END DO
         END IF
      END IF

      ! allocate tau_r and tau_g if use_kinetic_energy_density
      IF (dft_control%use_kinetic_energy_density) THEN
         ! tau_r
         IF (my_rebuild_grids .OR. .NOT. ASSOCIATED(tau_r)) THEN
            IF (ASSOCIATED(tau_r)) THEN
               DO i = 1, SIZE(tau_r)
                  CALL pw_release(tau_r(i)%pw)
               END DO
               DEALLOCATE (tau_r)
            END IF
            ALLOCATE (tau_r(nspins))
            CALL qs_rho_set(rho, tau_r=tau_r)
            DO i = 1, nspins
               CALL pw_pool_create_pw(auxbas_pw_pool, tau_r(i)%pw, &
                                      use_data=REALDATA3D, in_space=REALSPACE)
            END DO
         END IF

         ! tau_g
         IF (my_rebuild_grids .OR. .NOT. ASSOCIATED(tau_g)) THEN
            IF (ASSOCIATED(tau_g)) THEN
               DO i = 1, SIZE(tau_g)
                  CALL pw_release(tau_g(i)%pw)
               END DO
               DEALLOCATE (tau_g)
            END IF
            ALLOCATE (tau_g(nspins))
            CALL qs_rho_set(rho, tau_g=tau_g)
            DO i = 1, nspins
               CALL pw_pool_create_pw(auxbas_pw_pool, tau_g(i)%pw, &
                                      use_data=COMPLEXDATA1D, in_space=RECIPROCALSPACE)
            END DO
         END IF
      END IF ! use_kinetic_energy_density

      CALL timestop(handle)

   END SUBROUTINE qs_rho_rebuild

! **************************************************************************************************
!> \brief updates rho_r and rho_g to the rho%rho_ao.
!>      if use_kinetic_energy_density also computes tau_r and tau_g
!> \param rho_struct the rho structure that should be updated
!> \param qs_env the qs_env rho_struct refers to
!>        the integrated charge in r space
!> \param local_rho_set ...
!> \param pw_env_external    external plane wave environment
!> \param task_list_external external task list
!> \par History
!>      08.2002 created [fawzi]
!> \author Fawzi Mohamed
! **************************************************************************************************
   SUBROUTINE qs_rho_update_rho(rho_struct, qs_env, local_rho_set, pw_env_external, task_list_external)
      TYPE(qs_rho_type), POINTER                         :: rho_struct
      TYPE(qs_environment_type), POINTER                 :: qs_env
      TYPE(local_rho_type), OPTIONAL, POINTER            :: local_rho_set
      TYPE(pw_env_type), OPTIONAL, POINTER               :: pw_env_external
      TYPE(task_list_type), OPTIONAL, POINTER            :: task_list_external

      CHARACTER(len=*), PARAMETER :: routineN = 'qs_rho_update_rho', &
         routineP = moduleN//':'//routineN

      INTEGER                                            :: handle, img, ispin, nimg, nspins
      INTEGER, DIMENSION(:, :, :), POINTER               :: cell_to_index
      LOGICAL                                            :: gapw, gapw_xc
      REAL(KIND=dp)                                      :: dum
      REAL(KIND=dp), DIMENSION(:), POINTER               :: tot_rho_r, tot_rho_r_xc
      TYPE(atomic_kind_type), DIMENSION(:), POINTER      :: atomic_kind_set
      TYPE(cp_para_env_type), POINTER                    :: para_env
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: rho_ao
      TYPE(dbcsr_p_type), DIMENSION(:, :), POINTER       :: rho_ao_kp, rho_xc_ao
      TYPE(dft_control_type), POINTER                    :: dft_control
      TYPE(kpoint_type), POINTER                         :: kpoints
      TYPE(lri_density_type), POINTER                    :: lri_density
      TYPE(lri_environment_type), POINTER                :: lri_env
      TYPE(pw_env_type), POINTER                         :: pw_env
      TYPE(pw_p_type), DIMENSION(:), POINTER             :: drho_g, drho_r, drho_xc_g, rho_g, rho_r, &
                                                            rho_xc_g, rho_xc_r, tau_g, tau_r, &
                                                            tau_xc_g, tau_xc_r
      TYPE(pw_p_type), POINTER                           :: rho_r_sccs
      TYPE(qs_ks_env_type), POINTER                      :: ks_env
      TYPE(qs_rho_type), POINTER                         :: rho_xc
      TYPE(task_list_type), POINTER                      :: task_list

      CALL timeset(routineN, handle)

      NULLIFY (dft_control, rho_xc, ks_env, rho_ao, rho_r, rho_g, drho_r, drho_g, tau_r, tau_g)
      NULLIFY (rho_xc_ao, rho_xc_g, rho_xc_r, drho_xc_g, tau_xc_r, tau_xc_g, tot_rho_r, tot_rho_r_xc)
      NULLIFY (lri_env, para_env, pw_env, atomic_kind_set)

      CPASSERT(ASSOCIATED(rho_struct))

      CALL get_qs_env(qs_env, &
                      ks_env=ks_env, &
                      dft_control=dft_control, &
                      task_list=task_list, &
                      lri_env=lri_env, &
                      atomic_kind_set=atomic_kind_set, &
                      para_env=para_env, &
                      pw_env=pw_env)

      CALL qs_rho_get(rho_struct, &
                      rho_r=rho_r, &
                      rho_g=rho_g, &
                      tot_rho_r=tot_rho_r, &
                      drho_r=drho_r, &
                      drho_g=drho_g, &
                      tau_r=tau_r, &
                      tau_g=tau_g, &
                      rho_r_sccs=rho_r_sccs)

      IF (PRESENT(pw_env_external)) pw_env => pw_env_external
      IF (PRESENT(task_list_external)) task_list => task_list_external

      nspins = dft_control%nspins
      nimg = dft_control%nimages
      gapw = dft_control%qs_control%gapw
      gapw_xc = dft_control%qs_control%gapw_xc

      IF (dft_control%qs_control%semi_empirical) THEN
         !
         CALL qs_rho_set(rho_struct, rho_r_valid=.FALSE., rho_g_valid=.FALSE.)
      ELSEIF (dft_control%qs_control%dftb .OR. dft_control%qs_control%xtb) THEN
         !
         CALL qs_rho_set(rho_struct, rho_r_valid=.FALSE., rho_g_valid=.FALSE.)
      ELSEIF (dft_control%qs_control%lrigpw) THEN
         CPASSERT(.NOT. dft_control%use_kinetic_energy_density)
         CALL get_ks_env(ks_env=ks_env, kpoints=kpoints)
         CALL get_kpoint_info(kpoint=kpoints, cell_to_index=cell_to_index)
         CALL qs_rho_get(rho_struct, rho_ao_kp=rho_ao_kp)
         CALL get_qs_env(qs_env, lri_density=lri_density)
         CALL calculate_lri_densities(lri_env, lri_density, qs_env, rho_ao_kp, cell_to_index, &
                                      lri_rho_struct=rho_struct, &
                                      atomic_kind_set=atomic_kind_set, &
                                      para_env=para_env)
         CALL set_qs_env(qs_env, lri_density=lri_density)
         CALL qs_rho_set(rho_struct, rho_r_valid=.TRUE., rho_g_valid=.TRUE.)
      ELSEIF (dft_control%qs_control%rigpw) THEN
         CPASSERT(.NOT. dft_control%use_kinetic_energy_density)
         CALL qs_rho_get(rho_struct, rho_ao=rho_ao)
         CALL calculate_ri_densities(lri_env, qs_env, rho_ao, &
                                     lri_rho_struct=rho_struct, &
                                     atomic_kind_set=atomic_kind_set, &
                                     para_env=para_env)
         CALL qs_rho_set(rho_struct, rho_r_valid=.TRUE., rho_g_valid=.TRUE.)
      ELSE
         CALL qs_rho_get(rho_struct, rho_ao_kp=rho_ao_kp)
         DO ispin = 1, nspins
            rho_ao => rho_ao_kp(ispin, :)
            CALL calculate_rho_elec(matrix_p_kp=rho_ao, &
                                    rho=rho_r(ispin), &
                                    rho_gspace=rho_g(ispin), &
                                    total_rho=tot_rho_r(ispin), &
                                    ks_env=ks_env, soft_valid=gapw, &
                                    task_list_external=task_list, &
                                    pw_env_external=pw_env)
         END DO
         CALL qs_rho_set(rho_struct, rho_r_valid=.TRUE., rho_g_valid=.TRUE.)

         ! if needed compute also the gradient of the density
         IF (dft_control%drho_by_collocation) THEN
            CALL qs_rho_get(rho_struct, rho_ao_kp=rho_ao_kp)
            CPASSERT(.NOT. PRESENT(task_list_external))
            CPASSERT(.NOT. PRESENT(pw_env_external))
            DO ispin = 1, nspins
               rho_ao => rho_ao_kp(ispin, :)
               CALL calculate_drho_elec(matrix_p_kp=rho_ao, &
                                        drho=drho_r(3*(ispin-1)+1:3*ispin), &
                                        drho_gspace=drho_g(3*(ispin-1)+1:3*ispin), &
                                        qs_env=qs_env, soft_valid=gapw)
            END DO
            CALL qs_rho_set(rho_struct, drho_r_valid=.TRUE., drho_g_valid=.TRUE.)
         ENDIF

         ! if needed compute also the kinetic energy density
         IF (dft_control%use_kinetic_energy_density) THEN
            CALL qs_rho_get(rho_struct, rho_ao_kp=rho_ao_kp)
            DO ispin = 1, nspins
               rho_ao => rho_ao_kp(ispin, :)
               CALL calculate_rho_elec(matrix_p_kp=rho_ao, &
                                       rho=tau_r(ispin), &
                                       rho_gspace=tau_g(ispin), &
                                       total_rho=dum, & ! presumably not meaningful
                                       ks_env=ks_env, soft_valid=gapw, &
                                       compute_tau=.TRUE., &
                                       task_list_external=task_list, &
                                       pw_env_external=pw_env)
            END DO
            CALL qs_rho_set(rho_struct, tau_r_valid=.TRUE., tau_g_valid=.TRUE.)
         ENDIF
      END IF

      ! GAPW o GAPW_XC require the calculation of hard and soft local densities
      IF (gapw) THEN
         CPASSERT(.NOT. PRESENT(task_list_external))
         CPASSERT(.NOT. PRESENT(pw_env_external))
         CALL qs_rho_get(rho_struct, rho_ao_kp=rho_ao_kp)
         IF (PRESENT(local_rho_set)) THEN
            CALL calculate_rho_atom_coeff(qs_env, rho_ao_kp, local_rho_set%rho_atom_set)
         ELSE
            CALL calculate_rho_atom_coeff(qs_env, rho_ao_kp)
         ENDIF
      ENDIF
      IF (gapw_xc) THEN
         CPASSERT(.NOT. PRESENT(task_list_external))
         CPASSERT(.NOT. PRESENT(pw_env_external))
         CALL get_qs_env(qs_env=qs_env, rho_xc=rho_xc)
         CALL qs_rho_get(rho_xc, &
                         rho_ao_kp=rho_xc_ao, &
                         rho_r=rho_xc_r, &
                         rho_g=rho_xc_g, &
                         tot_rho_r=tot_rho_r_xc, &
                         drho_g=drho_xc_g, &
                         tau_r=tau_xc_r, &
                         tau_g=tau_xc_g)
         CALL calculate_rho_atom_coeff(qs_env, rho_ao_kp)
         ! copy rho_ao into rho_xc_ao
         DO ispin = 1, nspins
            DO img = 1, nimg
               CALL dbcsr_copy(rho_xc_ao(ispin, img)%matrix, rho_ao_kp(ispin, img)%matrix)
            END DO
         END DO
         DO ispin = 1, nspins
            rho_ao => rho_xc_ao(ispin, :)
            CALL calculate_rho_elec(matrix_p_kp=rho_ao, &
                                    rho=rho_xc_r(ispin), &
                                    rho_gspace=rho_xc_g(ispin), &
                                    total_rho=tot_rho_r_xc(ispin), &
                                    ks_env=ks_env, soft_valid=gapw_xc)
         END DO
         CALL qs_rho_set(rho_xc, rho_r_valid=.TRUE., rho_g_valid=.TRUE.)
         ! if needed compute also the gradient of the density
         IF (dft_control%drho_by_collocation) THEN
            DO ispin = 1, nspins
               rho_ao => rho_xc_ao(ispin, :)
               CALL calculate_drho_elec(matrix_p_kp=rho_ao, &
                                        drho=rho_xc_r(3*(ispin-1)+1:3*ispin), &
                                        drho_gspace=drho_xc_g(3*(ispin-1)+1:3*ispin), &
                                        qs_env=qs_env, soft_valid=gapw_xc)
            END DO
            CALL qs_rho_set(rho_xc, drho_r_valid=.TRUE., drho_g_valid=.TRUE.)
         ENDIF
         ! if needed compute also the kinetic energy density
         IF (dft_control%use_kinetic_energy_density) THEN
            DO ispin = 1, nspins
               rho_ao => rho_xc_ao(ispin, :)
               CALL calculate_rho_elec(matrix_p_kp=rho_ao, &
                                       rho=tau_xc_r(ispin), &
                                       rho_gspace=tau_xc_g(ispin), &
                                       total_rho=dum, & ! presumably not meaningful
                                       ks_env=ks_env, soft_valid=gapw_xc, &
                                       compute_tau=.TRUE.)
            END DO
            CALL qs_rho_set(rho_xc, tau_r_valid=.TRUE., tau_g_valid=.TRUE.)
         ENDIF
      ENDIF

      CALL timestop(handle)

   END SUBROUTINE qs_rho_update_rho

! **************************************************************************************************
!> \brief Duplicates a pointer physically
!> \param rho_input The rho structure to be duplicated
!> \param rho_output The duplicate rho structure
!> \param qs_env The QS environment from which the auxiliary PW basis-set
!>                pool is taken
!> \par History
!>      07.2005 initial create [tdk]
!> \author Thomas D. Kuehne (tkuehne@phys.chem.ethz.ch)
!> \note
!>      Associated pointers are deallocated, nullified pointers are NOT accepted!
! **************************************************************************************************
   SUBROUTINE duplicate_rho_type(rho_input, rho_output, qs_env)

      TYPE(qs_rho_type), POINTER                         :: rho_input, rho_output
      TYPE(qs_environment_type), POINTER                 :: qs_env

      CHARACTER(len=*), PARAMETER :: routineN = 'duplicate_rho_type', &
         routineP = moduleN//':'//routineN

      INTEGER                                            :: handle, i, nspins, rebuild_each_in
      LOGICAL :: drho_g_valid_in, drho_r_valid_in, rho_g_valid_in, rho_r_valid_in, soft_valid_in, &
         tau_g_valid_in, tau_r_valid_in
      REAL(KIND=dp), DIMENSION(:), POINTER               :: tot_rho_g_in, tot_rho_g_out, &
                                                            tot_rho_r_in, tot_rho_r_out
      TYPE(dbcsr_p_type), DIMENSION(:), POINTER          :: rho_ao_in, rho_ao_out
      TYPE(dft_control_type), POINTER                    :: dft_control
      TYPE(pw_env_type), POINTER                         :: pw_env
      TYPE(pw_p_type), DIMENSION(:), POINTER :: drho_g_in, drho_g_out, drho_r_in, drho_r_out, &
         rho_g_in, rho_g_out, rho_r_in, rho_r_out, tau_g_in, tau_g_out, tau_r_in, tau_r_out
      TYPE(pw_p_type), POINTER                           :: rho_r_sccs_in, rho_r_sccs_out
      TYPE(pw_pool_type), POINTER                        :: auxbas_pw_pool

      CALL timeset(routineN, handle)

      NULLIFY (dft_control, pw_env, auxbas_pw_pool)
      NULLIFY (rho_ao_in, rho_ao_out)
      NULLIFY (rho_r_in, rho_r_out, rho_g_in, rho_g_out, drho_r_in, drho_r_out)
      NULLIFY (drho_g_in, drho_g_out, tau_r_in, tau_r_out, tau_g_in, tau_g_out)
      NULLIFY (tot_rho_r_in, tot_rho_r_out, tot_rho_g_in, tot_rho_g_out)
      NULLIFY (rho_r_sccs_in, rho_r_sccs_out)

      CPASSERT(ASSOCIATED(rho_input))
      CPASSERT(ASSOCIATED(rho_output))
      CPASSERT(ASSOCIATED(qs_env))
      CPASSERT(qs_env%ref_count > 0)

      CALL get_qs_env(qs_env=qs_env, pw_env=pw_env, dft_control=dft_control)
      CALL pw_env_get(pw_env=pw_env, auxbas_pw_pool=auxbas_pw_pool)
      nspins = dft_control%nspins

      CALL qs_rho_clear(rho_output)

      CALL qs_rho_get(rho_input, &
                      rho_ao=rho_ao_in, &
                      rho_r=rho_r_in, &
                      rho_g=rho_g_in, &
                      drho_r=drho_r_in, &
                      drho_g=drho_g_in, &
                      tau_r=tau_r_in, &
                      tau_g=tau_g_in, &
                      tot_rho_r=tot_rho_r_in, &
                      tot_rho_g=tot_rho_g_in, &
                      rho_g_valid=rho_g_valid_in, &
                      rho_r_valid=rho_r_valid_in, &
                      drho_g_valid=drho_g_valid_in, &
                      drho_r_valid=drho_r_valid_in, &
                      tau_r_valid=tau_r_valid_in, &
                      tau_g_valid=tau_g_valid_in, &
                      rho_r_sccs=rho_r_sccs_in, &
                      soft_valid=soft_valid_in, &
                      rebuild_each=rebuild_each_in)

      ! rho_ao
      IF (ASSOCIATED(rho_ao_in)) THEN
         CALL dbcsr_allocate_matrix_set(rho_ao_out, nspins)
         CALL qs_rho_set(rho_output, rho_ao=rho_ao_out)
         DO i = 1, nspins
            ALLOCATE (rho_ao_out(i)%matrix)
            CALL dbcsr_copy(rho_ao_out(i)%matrix, rho_ao_in(i)%matrix, &
                            name="myDensityMatrix_for_Spin_"//TRIM(ADJUSTL(cp_to_string(i))))
            CALL dbcsr_set(rho_ao_out(i)%matrix, 0.0_dp)
         END DO
      END IF

      ! rho_r
      IF (ASSOCIATED(rho_r_in)) THEN
         ALLOCATE (rho_r_out(nspins))
         CALL qs_rho_set(rho_output, rho_r=rho_r_out)
         DO i = 1, nspins
            CALL pw_pool_create_pw(auxbas_pw_pool, rho_r_out(i)%pw, &
                                   use_data=REALDATA3D, in_space=REALSPACE)
            rho_r_out(i)%pw%cr3d(:, :, :) = rho_r_in(i)%pw%cr3d(:, :, :)
         END DO
      END IF

      ! rho_g
      IF (ASSOCIATED(rho_g_in)) THEN
         ALLOCATE (rho_g_out(nspins))
         CALL qs_rho_set(rho_output, rho_g=rho_g_out)
         DO i = 1, nspins
            CALL pw_pool_create_pw(auxbas_pw_pool, rho_g_out(i)%pw, &
                                   use_data=COMPLEXDATA1D, &
                                   in_space=RECIPROCALSPACE)
            rho_g_out(i)%pw%cc(:) = rho_g_in(i)%pw%cc(:)
         END DO
      END IF

      ! SCCS
      IF (ASSOCIATED(rho_r_sccs_in)) THEN
         CALL qs_rho_set(rho_output, rho_r_sccs=rho_r_sccs_out)
         CALL pw_pool_create_pw(auxbas_pw_pool, rho_r_sccs_out%pw, &
                                in_space=REALSPACE, &
                                use_data=REALDATA3D)
         rho_r_sccs_out%pw%cr3d(:, :, :) = rho_r_sccs_in%pw%cr3d(:, :, :)
      END IF

      ! drho_r and drho_g are only needed if calculated by collocation
      IF (dft_control%drho_by_collocation) THEN
         ! drho_r
         IF (ASSOCIATED(drho_r_in)) THEN
            ALLOCATE (drho_r_out(3*nspins))
            CALL qs_rho_set(rho_output, drho_r=drho_r_out)
            DO i = 1, 3*nspins
               CALL pw_pool_create_pw(auxbas_pw_pool, drho_r_out(i)%pw, &
                                      use_data=REALDATA3D, in_space=REALSPACE)
               drho_r_out(i)%pw%cr3d(:, :, :) = drho_r_in(i)%pw%cr3d(:, :, :)
            END DO
         END IF

         ! drho_g
         IF (ASSOCIATED(drho_g_in)) THEN
            ALLOCATE (drho_g_out(3*nspins))
            CALL qs_rho_set(rho_output, drho_g=drho_g_out)
            DO i = 1, 3*nspins
               CALL pw_pool_create_pw(auxbas_pw_pool, drho_g_out(i)%pw, &
                                      use_data=COMPLEXDATA1D, &
                                      in_space=RECIPROCALSPACE)
               drho_g_out(i)%pw%cc(:) = drho_g_in(i)%pw%cc(:)
            END DO
         END IF
      END IF

      ! tau_r and tau_g are only needed in the case of Meta-GGA XC-functionals
      ! are used. Therefore they are only allocated if
      ! dft_control%use_kinetic_energy_density is true
      IF (dft_control%use_kinetic_energy_density) THEN
         ! tau_r
         IF (ASSOCIATED(tau_r_in)) THEN
            ALLOCATE (tau_r_out(nspins))
            CALL qs_rho_set(rho_output, tau_r=tau_r_out)
            DO i = 1, nspins
               CALL pw_pool_create_pw(auxbas_pw_pool, tau_r_out(i)%pw, &
                                      use_data=REALDATA3D, in_space=REALSPACE)
               tau_r_out(i)%pw%cr3d(:, :, :) = tau_r_in(i)%pw%cr3d(:, :, :)
            END DO
         END IF

         ! tau_g
         IF (ASSOCIATED(tau_g_in)) THEN
            ALLOCATE (tau_g_out(nspins))
            CALL qs_rho_set(rho_output, tau_g=tau_g_out)
            DO i = 1, nspins
               CALL pw_pool_create_pw(auxbas_pw_pool, tau_g_out(i)%pw, &
                                      use_data=COMPLEXDATA1D, &
                                      in_space=RECIPROCALSPACE)
               tau_g_out(i)%pw%cc(:) = tau_g_in(i)%pw%cc(:)
            END DO
         END IF
      END IF

      CALL qs_rho_set(rho_output, &
                      rho_g_valid=rho_g_valid_in, &
                      rho_r_valid=rho_r_valid_in, &
                      drho_g_valid=drho_g_valid_in, &
                      drho_r_valid=drho_r_valid_in, &
                      tau_r_valid=tau_r_valid_in, &
                      tau_g_valid=tau_g_valid_in, &
                      soft_valid=soft_valid_in, &
                      rebuild_each=rebuild_each_in)

      ! tot_rho_r
      IF (ASSOCIATED(tot_rho_r_in)) THEN
         ALLOCATE (tot_rho_r_out(nspins))
         CALL qs_rho_set(rho_output, tot_rho_r=tot_rho_r_out)
         DO i = 1, nspins
            tot_rho_r_out(i) = tot_rho_r_in(i)
         END DO
      END IF

      ! tot_rho_g
      IF (ASSOCIATED(tot_rho_g_in)) THEN
         ALLOCATE (tot_rho_g_out(nspins))
         CALL qs_rho_set(rho_output, tot_rho_g=tot_rho_g_out)
         DO i = 1, nspins
            tot_rho_g_out(i) = tot_rho_g_in(i)
         END DO

      END IF

      CALL timestop(handle)

   END SUBROUTINE duplicate_rho_type

END MODULE qs_rho_methods
