!!  Take an initial model from a Lagrangian code and put it onto
!!  a uniform grid and make sure that it is happy with the EOS in
!!  our code.  The output is a .hse file that can be read directly
!!  by Maestro.
!!
!!  The model is placed into HSE by the following differencing:
!!
!!   (1/dr) [ <P>_i - <P>_{i-1} ] = (1/2) [ <rho>_i + <rho>_{i-1} ] g
!!
!!
!!  We take the temperature structure directly from the original
!!  initial model.  We adjust the density and pressure according to
!!  HSE using the EOS.
!!
!!***

program init_1d

  use bl_types
  use bl_constants_module
  use bl_error_module
  use eos_module, only: eos, eos_init
  use eos_type_module, only : eos_t, eos_input_rt, eos_input_re, eos_input_rp
  use network
  use fundamental_constants_module
  use extern_probin_module, only: use_eos_coulomb
  use mesa_reader

  implicit none

  integer :: i, j, k, n

  real (kind=dp_t), allocatable :: xzn_hse(:), xznl(:), xznr(:)
  real (kind=dp_t), allocatable :: M_enclosed(:)
  real (kind=dp_t), allocatable :: model_mesa_hse(:,:)
  real (kind=dp_t), allocatable :: model_isentropic_hse(:,:)
  real (kind=dp_t), allocatable :: model_hybrid_hse(:,:)
  real (kind=dp_t), allocatable :: model_conservative(:,:)
  real (kind=dp_t), allocatable :: model_convective(:,:)
  real (kind=dp_t), allocatable :: model_ad_excess(:,:)
  real (kind=dp_t), allocatable :: entropy_want(:)
  real (kind=dp_t), allocatable :: model_ener(:)

  integer, parameter :: nx = 6144

  ! define convenient indices for the scalars
  integer, parameter :: idens = 1, &
       itemp = 2, &
       ipres = 3, &
       ientr = 4, &
       isndspd = 5, &
       imass = 6, &
       igradT = 7, &
       ispec = 8
  integer, parameter :: nvar = igradT + nspec

  real (kind=dp_t), save :: xmin, xmax, delx

  real (kind=dp_t) :: dens_zone, temp_zone, pres_zone, entropy, temp_min, temp_max

  real (kind=dp_t) :: A, B, dAdT, dAdrho, dBdT, dBdrho
  real (kind=dp_t) :: dpd, dpt, dsd, dst

  real (kind=dp_t) :: central_density

  real (kind=dp_t) :: p_want, drho, dtemp, gradP

  real (kind=dp_t) :: g_zone, hse_error, ad_error, ad_tol, adiabatic_excess, err_min, err_max

  real (kind=dp_t) :: max_hse_error, dpdr, rhog

  real (kind=dp_t), parameter :: TOL = 1.d-10

  integer, parameter :: MAX_ITER = 250, AD_ITER = 2500

  integer :: iter, iter_dens, status

  integer :: igood
  real (kind=dp_t) :: slope

  logical :: converged_hse, converged_central_density, fluff, isentropic, print_n

  real (kind=dp_t) :: max_temp

  integer :: index_hse_fluff

  real (kind=dp_t), dimension(nspec) :: xn

  real (kind=dp_t), save :: low_density_cutoff, temp_fluff, temp_fluff_cutoff, smallx

  integer, parameter :: MAX_VARNAME_LENGTH=80
  integer :: npts_model, nvars_model_file, nparams_model

  real(kind=dp_t), allocatable :: base_state(:,:), base_r(:), base_ener(:)
  real(kind=dp_t), allocatable :: base_ad(:), model_ad(:)
  real(kind=dp_t), allocatable :: vars_stored(:), params_stored(:)
  character(len=MAX_VARNAME_LENGTH), allocatable :: paramnames_stored(:)
  character(len=MAX_VARNAME_LENGTH), allocatable :: varnames_stored(:)
  logical :: found

  integer :: ipos
  character (len=5000) :: header_line, model_file, outfile
  character (len=8) num

  real(kind=dp_t) :: summ

  integer :: ibegin
  integer :: i_isentropic

  real(kind=dp_t) :: anelastic_cutoff = 9.e4  ! this is for diagnostics only -- not used in the HSEing
  real(kind=dp_t) :: M_enclosed_anel
  real(kind=dp_t) :: grav_ener, M_center
  real(kind=dp_t) :: eint_hybrid

  type (eos_t) :: eos_state

  smallx = 1.d-10

  ! set the parameters
  model_file = "18m_500_s_rot_b_eq_1.dat"

  xmin = 0.d0
  xmax = 1.d10

  low_density_cutoff =1.d-7

  ! temp_fluff_cutoff is the density below which we hold the temperature
  ! constant for the MESA model

  ! MAESTRO
  ! temp_fluff_cutoff = 1.d-4

  ! CASTRO
  temp_fluff_cutoff = 2.d-7
  temp_fluff = 1.d5

  ! this comes in via extern_probin_module -- override the default
  ! here if we want
  use_eos_coulomb = .true.


  ! initialize the EOS and network
  call eos_init()
  call network_init()

  !===========================================================================
  ! Create a 1-d uniform grid that is identical to the mesh that we are
  ! mapping onto, and then we want to force it into HSE on that mesh.
  !===========================================================================

  ! allocate storage
  allocate(xzn_hse(nx))
  allocate(xznl(nx))
  allocate(xznr(nx))
  allocate(model_mesa_hse(nx,nvar))
  allocate(model_isentropic_hse(nx,nvar))
  allocate(model_hybrid_hse(nx,nvar))
  allocate(model_convective(nx,nvar))
  allocate(M_enclosed(nx))
  allocate(entropy_want(nx))

  ! compute the coordinates of the new gridded function
  delx = (xmax - xmin) / dble(nx)

  do i = 1, nx
     xznl(i) = xmin + (dble(i) - 1.0d0)*delx
     xznr(i) = xmin + (dble(i))*delx
     xzn_hse(i) = 0.5d0*(xznl(i) + xznr(i))
  enddo

  !===========================================================================
  ! read in the MESA model
  !===========================================================================

  allocate(varnames_stored(7))
  varnames_stored(idens) = "rho"
  varnames_stored(itemp) = "temperature"
  varnames_stored(ipres) = "pressure"
  varnames_stored(ientr) = "entropy"
  varnames_stored(isndspd) = "csound"
  varnames_stored(imass) = "mass"
  varnames_stored(igradT) = "gradT"

  call read_mesa(model_file, base_state, base_r, varnames_stored, 7, npts_model)

  !===========================================================================
  ! put the model onto our new uniform grid
  !===========================================================================

  igood = -1

  do i = 1, nx

     do n = 1, nvar

        if (xzn_hse(i) < base_r(npts_model)) then

           model_mesa_hse(i,n) = interpolate(xzn_hse(i), npts_model, &
                base_r, base_state(:,n))

           igood = i
        else
           model_mesa_hse(i,n) = base_state(npts_model,n)
        endif

     enddo

     ! make sure that the species (mass fractions) summ to 1
     summ = 0.0d0
     do n = ispec,ispec-1+nspec
        model_mesa_hse(i,n) = max(model_mesa_hse(i,n),smallx)
        summ = summ + model_mesa_hse(i,n)
     enddo

     do n = ispec,ispec-1+nspec
        model_mesa_hse(i,n) = model_mesa_hse(i,n)/summ
     enddo

  enddo

  print *, "model_hse(1,idens) =", model_mesa_hse(1,idens)

  open (unit=30, file="model.uniform", status="unknown")

1000 format (1x, 30(g26.16, 1x))

  write (30,*) "# initial model just after putting onto a uniform grid"

  do i = 1, nx

     write (30,1000) xzn_hse(i), model_mesa_hse(i,idens), model_mesa_hse(i,itemp), &
          model_mesa_hse(i,ipres), (model_mesa_hse(i,ispec-1+n), n=1,nspec)

  enddo

  close (unit=30)

  !===========================================================================
  ! iterate to find the central density
  !===========================================================================

  ! because the MESA model likely begins at a larger radius than our first
  ! HSE model zone, simple interpolation will not do a good job.  We want to
  ! integrate in from the zone that best matches the first MESA model zone,
  ! assumming HSE and constant entropy.

  ! find the zone in the uniformly gridded model that corresponds to the
  ! first zone of the original model
  ibegin = -1

  do i = 1, nx
     if (xzn_hse(i) >= base_r(1)) then
        ibegin = i
        exit
     endif
  enddo

  ! store the central density.  We will iterate until the central density
  ! converges
  central_density = model_mesa_hse(1,idens)
  print *, 'interpolated central density = ', central_density

  do iter_dens = 1, max_iter

     ! compute the enclosed mass
     M_enclosed(1) = FOUR3RD*M_PI*delx**3*model_mesa_hse(1,idens)

     do i = 2, ibegin
        M_enclosed(i) = M_enclosed(i-1) + &
             FOUR3RD*M_PI*(xznr(i) - xznl(i)) * &
             (xznr(i)**2 +xznl(i)*xznr(i) + xznl(i)**2)*model_mesa_hse(i,idens)
     enddo

     ! now start at ibegin and integrate inward
     eos_state%T     = model_mesa_hse(ibegin,itemp)
     eos_state%rho   = model_mesa_hse(ibegin,idens)
     eos_state%xn(:) = model_mesa_hse(ibegin,ispec:nvar)

     call eos(eos_input_rt, eos_state)

     model_mesa_hse(ibegin,ipres) = eos_state%p
     model_mesa_hse(ibegin,ientr) = eos_state%s
     model_mesa_hse(ibegin,isndspd) = &
          sqrt(eos_state%gam1*eos_state%p/eos_state%rho)

     entropy_want(:) = eos_state%s

     do i = ibegin-1, 1, -1

        ! as the initial guess for the temperature and density, use
        ! the previous zone
        dens_zone = model_mesa_hse(i+1,idens)
        temp_zone = model_mesa_hse(i+1,itemp)
        xn(:) = model_mesa_hse(i,ispec:nvar)

        ! compute the gravitational acceleration on the interface between zones
        ! i and i+1
        g_zone = -Gconst*M_enclosed(i)/(xznr(i)*xznr(i))

        !-----------------------------------------------------------------------
        ! iteration loop
        !-----------------------------------------------------------------------

        ! start off the Newton loop by saying that the zone has not converged
        converged_hse = .FALSE.

        do iter = 1, MAX_ITER

           p_want = model_mesa_hse(i+1,ipres) - &
                delx*0.5d0*(dens_zone + model_mesa_hse(i+1,idens))*g_zone

           ! now we have two functions to zero:
           !   A = p_want - p(rho,T)
           !   B = entropy_want - s(rho,T)
           ! We use a two dimensional Taylor expansion and find the deltas
           ! for both density and temperature

           ! (t, rho) -> (p, s)

           eos_state%T     = temp_zone
           eos_state%rho   = dens_zone
           eos_state%xn(:) = xn(:)

           call eos(eos_input_rt, eos_state)

           entropy = eos_state%s
           pres_zone = eos_state%p

           dpt = eos_state%dpdt
           dpd = eos_state%dpdr
           dst = eos_state%dsdt
           dsd = eos_state%dsdr

           A = p_want - pres_zone
           B = entropy_want(i) - entropy

           dAdT = -dpt
           dAdrho = -0.5d0*delx*g_zone - dpd
           dBdT = -dst
           dBdrho = -dsd

           dtemp = (B - (dBdrho/dAdrho)*A)/ &
                ((dBdrho/dAdrho)*dAdT - dBdT)

           drho = -(A + dAdT*dtemp)/dAdrho

           dens_zone = max(0.9d0*dens_zone, &
                min(dens_zone + drho, 1.1d0*dens_zone))

           temp_zone = max(0.9d0*temp_zone, &
                min(temp_zone + dtemp, 1.1d0*temp_zone))

           ! if (A < TOL .and. B < ETOL) then
           if (abs(drho) < TOL*dens_zone .and. abs(dtemp) < TOL*temp_zone) then
              converged_hse = .TRUE.
              exit
           endif

        enddo

        if (.NOT. converged_hse) then

           print *, 'Error zone', i, ' did not converge in init_1d'
           print *, 'integrate up'
           print *, 'dens_zone, temp_zone = ', dens_zone, temp_zone
           print *, "p_want = ", p_want
           print *, "drho = ", drho
           call bl_error('Error: HSE non-convergence')

        endif

        ! call the EOS one more time for this zone and then go on to the next
        ! (t, rho) -> (p, s)

        eos_state%T     = temp_zone
        eos_state%rho   = dens_zone
        eos_state%xn(:) = xn(:)

        call eos(eos_input_rt, eos_state)

        pres_zone = eos_state%p

        dpd = eos_state%dpdr

        ! update the thermodynamics in this zone
        model_mesa_hse(i,idens) = dens_zone
        model_mesa_hse(i,itemp) = temp_zone
        model_mesa_hse(i,ipres) = pres_zone
        model_mesa_hse(i,ientr) = eos_state%s
        model_mesa_hse(i,isndspd) = &
             sqrt(eos_state%gam1*eos_state%p/eos_state%rho)

     enddo

     if (abs(model_mesa_hse(1,idens) - central_density) < TOL*central_density) then
        converged_central_density = .true.
        exit
     endif

     central_density = model_mesa_hse(1,idens)

  enddo

  if (.NOT. converged_central_density) then
     print *, 'ERROR: central density iterations did not converge'
     call bl_error('ERROR: non-convergence')
  endif

  print *, 'converged central density = ', model_mesa_hse(1,idens)
  print *, ' '

  !===========================================================================
  ! compute the full HSE model using our new central density and temperature,
  ! and the temperature structure as dictated by the MESA model.
  !===========================================================================

  print *, 'putting MESA model into HSE on our grid...'

  ! compute the enclosed mass
  M_enclosed(1) = FOUR3RD*M_PI*delx**3*model_mesa_hse(1,idens)

  fluff = .FALSE.

  do i = 2, nx

     ! use previous zone as initial guess for T, rho
     dens_zone = model_mesa_hse(i-1,idens)
     temp_zone = model_mesa_hse(i-1,itemp)

     xn(:) = model_mesa_hse(i,ispec:nvar)

     ! compute the gravitational acceleration on the interface between zones
     ! i-1 and i
     g_zone = -Gconst*M_enclosed(i-1)/(xznr(i-1)*xznr(i-1))

     !-----------------------------------------------------------------------
     ! iteration loop
     !-----------------------------------------------------------------------

     converged_hse = .FALSE.

     if (.not. fluff) then

        do iter = 1, MAX_ITER

           ! HSE differencing
           p_want = model_mesa_hse(i-1,ipres) + &
                delx*0.5d0*(dens_zone + model_mesa_hse(i-1,idens))*g_zone

           temp_zone = model_mesa_hse(i,itemp)

           if (model_mesa_hse(i-1,idens) .lt. temp_fluff_cutoff) then
              temp_zone = temp_fluff
           end if

           ! (t, rho) -> (p)
           eos_state%T     = temp_zone
           eos_state%rho   = dens_zone
           eos_state%xn(:) = xn(:)

           call eos(eos_input_rt, eos_state)

           pres_zone = eos_state%p

           dpd = eos_state%dpdr
           drho = (p_want - pres_zone)/(dpd - 0.5d0*delx*g_zone)

           dens_zone = max(0.9d0*dens_zone, &
                min(dens_zone + drho, 1.1d0*dens_zone))

           if (abs(drho) < TOL*dens_zone) then
              converged_hse = .TRUE.
              exit
           endif

           if (dens_zone < low_density_cutoff) then
              dens_zone = low_density_cutoff
              temp_zone = temp_fluff
              converged_hse = .TRUE.
              fluff = .TRUE.
              index_hse_fluff = i
              exit

           endif

        enddo

        if (.NOT. converged_hse) then

           print *, 'Error zone', i, ' did not converge in init_1d'
           print *, 'integrate up'
           print *, 'dens_zone, temp_zone = ', dens_zone, temp_zone
           print *, "p_want = ", p_want
           print *, "drho = ", drho
           call bl_error('Error: HSE non-convergence')

        endif

        if (temp_zone < temp_fluff) then
           temp_zone = temp_fluff
        endif

     else
        dens_zone = low_density_cutoff
        temp_zone = temp_fluff
     endif

     ! call the EOS one more time for this zone and then go on to the next
     ! (t, rho) -> (p)

     eos_state%T     = temp_zone
     eos_state%rho   = dens_zone
     eos_state%xn(:) = xn(:)

     call eos(eos_input_rt, eos_state)

     pres_zone = eos_state%p

     ! update the thermodynamics in this zone
     model_mesa_hse(i,idens) = dens_zone
     model_mesa_hse(i,itemp) = temp_zone
     model_mesa_hse(i,ipres) = pres_zone
     model_mesa_hse(i,ientr) = eos_state%s
     model_mesa_hse(i,isndspd) = &
          sqrt(eos_state%gam1*eos_state%p/eos_state%rho)

     M_enclosed(i) = M_enclosed(i-1) + &
          FOUR3RD*M_PI*(xznr(i) - xznl(i)) * &
          (xznr(i)**2 +xznl(i)*xznr(i) + xznl(i)**2)*model_mesa_hse(i,idens)

  enddo

  !===========================================================================
  ! compute the alternate model using the same central density and
  ! temperature, but assumming that we are isentropic (and in HSE).
  !===========================================================================

  print *, 'creating isentropic model...'

  ! as an initial guess, use the MESA HSE model
  model_isentropic_hse(:,:) = model_mesa_hse(:,:)

  entropy_want(:) = model_isentropic_hse(1,ientr)

  fluff = .false.
  isentropic = .true.

  ! keep track of the mass enclosed below the current zone
  M_enclosed(1) = FOUR3RD*M_PI*delx**3*model_isentropic_hse(1,idens)

  do i = 2, nx

     ! use previous zone as initial guess for T, rho
     dens_zone = model_isentropic_hse(i-1,idens)
     temp_zone = model_isentropic_hse(i-1,itemp)

     xn(:) = model_isentropic_hse(i,ispec:nvar)

     g_zone = -Gconst*M_enclosed(i-1)/(xznr(i-1)*xznr(i-1))

     !-----------------------------------------------------------------------
     ! iteration loop
     !-----------------------------------------------------------------------

     ! start off the Newton loop by saying that the zone has not converged
     converged_hse = .FALSE.

     if (.not. fluff) then

        do iter = 1, MAX_ITER

           if (isentropic) then

              p_want = model_isentropic_hse(i-1,ipres) + &
                   delx*0.5d0*(dens_zone + model_isentropic_hse(i-1,idens))*g_zone

              ! now we have two functions to zero:
              !   A = p_want - p(rho,T)
              !   B = entropy_want - s(rho,T)
              ! We use a two dimensional Taylor expansion and find the deltas
              ! for both density and temperature

              ! (t, rho) -> (p, s)

              eos_state%T     = temp_zone
              eos_state%rho   = dens_zone
              eos_state%xn(:) = xn(:)

              call eos(eos_input_rt, eos_state)

              entropy = eos_state%s
              pres_zone = eos_state%p

              dpt = eos_state%dpdt
              dpd = eos_state%dpdr
              dst = eos_state%dsdt
              dsd = eos_state%dsdr

              A = p_want - pres_zone
              B = entropy_want(i) - entropy

              dAdT = -dpt
              dAdrho = 0.5d0*delx*g_zone - dpd
              dBdT = -dst
              dBdrho = -dsd

              dtemp = (B - (dBdrho/dAdrho)*A)/ &
                   ((dBdrho/dAdrho)*dAdT - dBdT)

              drho = -(A + dAdT*dtemp)/dAdrho

              dens_zone = max(0.9d0*dens_zone, &
                   min(dens_zone + drho, 1.1d0*dens_zone))

              temp_zone = max(0.9d0*temp_zone, &
                   min(temp_zone + dtemp, 1.1d0*temp_zone))


              if (dens_zone < low_density_cutoff) then

                 dens_zone = low_density_cutoff
                 temp_zone = temp_fluff
                 converged_hse = .TRUE.
                 fluff = .TRUE.
                 exit

              endif

              ! if (A < TOL .and. B < ETOL) then
              if (abs(drho) < TOL*dens_zone .and. abs(dtemp) < TOL*temp_zone) then
                 converged_hse = .TRUE.
                 exit
              endif

           else

              ! do isothermal
              p_want = model_isentropic_hse(i-1,ipres) + &
                   delx*0.5*(dens_zone + model_isentropic_hse(i-1,idens))*g_zone

              temp_zone = temp_fluff

              ! (t, rho) -> (p, s)

              eos_state%T     = temp_zone
              eos_state%rho   = dens_zone
              eos_state%xn(:) = xn(:)

              call eos(eos_input_rt, eos_state)

              entropy = eos_state%s
              pres_zone = eos_state%p

              dpd = eos_state%dpdr

              drho = (p_want - pres_zone)/(dpd - 0.5*delx*g_zone)

              dens_zone = max(0.9*dens_zone, &
                   min(dens_zone + drho, 1.1*dens_zone))

              if (abs(drho) < TOL*dens_zone) then
                 converged_hse = .TRUE.
                 exit
              endif

              if (dens_zone < low_density_cutoff) then

                 dens_zone = low_density_cutoff
                 temp_zone = temp_fluff
                 converged_hse = .TRUE.
                 fluff = .TRUE.
                 exit

              endif

           endif

        enddo

        if (.NOT. converged_hse) then

           print *, 'Error zone', i, ' did not converge in init_1d'
           print *, 'integrate up'
           print *, 'dens_zone, temp_zone = ', dens_zone, temp_zone
           print *, "p_want = ", p_want
           print *, "drho = ", drho
           call bl_error('Error: HSE non-convergence')

        endif

        if (temp_zone < temp_fluff) then
           temp_zone = temp_fluff
           isentropic = .false.
        endif

     else
        dens_zone = low_density_cutoff
        temp_zone = temp_fluff
     endif

     ! call the EOS one more time for this zone and then go on to the next
     ! (t, rho) -> (p, s)

     eos_state%T     = temp_zone
     eos_state%rho   = dens_zone
     eos_state%xn(:) = xn(:)

     call eos(eos_input_rt, eos_state)

     pres_zone = eos_state%p

     dpd = eos_state%dpdr

     ! update the thermodynamics in this zone
     model_isentropic_hse(i,idens) = dens_zone
     model_isentropic_hse(i,itemp) = temp_zone
     model_isentropic_hse(i,ipres) = pres_zone
     model_isentropic_hse(i,ientr) = eos_state%s
     model_isentropic_hse(i,isndspd) = &
          sqrt(eos_state%gam1*eos_state%p/eos_state%rho)

     M_enclosed(i) = M_enclosed(i-1) + &
          FOUR3RD*M_PI*(xznr(i) - xznl(i))* &
          (xznr(i)**2 +xznl(i)*xznr(i) + xznl(i)**2)*model_isentropic_hse(i,idens)

  enddo

  !===========================================================================
  ! compute a hybrid model -- isentropic in the interior, MESA's temperature
  ! structure outside.
  !===========================================================================

  print *, 'creating hybrid model...'
  eint_hybrid = 0.0

  max_temp = maxval(model_mesa_hse(:,itemp))
  i_isentropic = -1
  do i = 1, nx
     model_hybrid_hse(i,:) = model_isentropic_hse(i,:)

     if (model_mesa_hse(i,itemp) > model_isentropic_hse(i,itemp)) then

        ! there will be a few regions in the very, very center where
        ! the MESA temperature may be slightly higher than the
        ! isentropic, but we are still not done with isentropic.
        ! i_isentropic is an index that keeps track of when we switch
        ! to the original MESA model "for real".  This is used for
        ! diagnostics.  We require the temperature to have dropped by
        ! 10% from the central value at least...
        if (i_isentropic == -1 .and. &
             model_isentropic_hse(i,itemp) < 0.9*max_temp) i_isentropic = i

        model_hybrid_hse(i,itemp) = model_mesa_hse(i,itemp)
     endif

  enddo

  ! the outer part of the star will be using the original MESA
  ! temperature structure.  Because the hybrid model might hit the
  ! fluff region earlier or later than the MESA model, reset the
  ! temperatures in the fluff region to the last valid MESA zone.
  if (index_hse_fluff > 1) then
     model_hybrid_hse(index_hse_fluff:,itemp) = model_mesa_hse(index_hse_fluff-1,itemp)
  endif

  ! compute the enclosed mass
  M_enclosed(1) = FOUR3RD*M_PI*delx**3*model_hybrid_hse(1,idens)

  fluff = .FALSE.

  do i = 2, nx

     ! use previous zone as initial guess for T, rho
     dens_zone = model_hybrid_hse(i-1,idens)
     temp_zone = model_hybrid_hse(i-1,itemp)

     xn(:) = model_hybrid_hse(i,ispec:nvar)

     ! compute the gravitational acceleration on the interface between zones
     ! i-1 and i
     g_zone = -Gconst*M_enclosed(i-1)/(xznr(i-1)*xznr(i-1))

     !-----------------------------------------------------------------------
     ! iteration loop
     !-----------------------------------------------------------------------

     converged_hse = .FALSE.

     if (.not. fluff) then

        do iter = 1, MAX_ITER

           ! HSE differencing
           p_want = model_hybrid_hse(i-1,ipres) + &
                delx*0.5d0*(dens_zone + model_hybrid_hse(i-1,idens))*g_zone

           temp_zone = model_hybrid_hse(i,itemp)

           ! (t, rho) -> (p)
           eos_state%T     = temp_zone
           eos_state%rho   = dens_zone
           eos_state%xn(:) = xn(:)

           call eos(eos_input_rt, eos_state)

           pres_zone = eos_state%p

           dpd = eos_state%dpdr
           drho = (p_want - pres_zone)/(dpd - 0.5d0*delx*g_zone)

           dens_zone = max(0.9d0*dens_zone, &
                min(dens_zone + drho, 1.1d0*dens_zone))

           if (abs(drho) < TOL*dens_zone) then
              converged_hse = .TRUE.
              exit
           endif

           if (dens_zone <= low_density_cutoff) then
              dens_zone = low_density_cutoff
              temp_zone = temp_fluff
              converged_hse = .TRUE.
              fluff = .TRUE.
              exit

           endif

        enddo

        if (.NOT. converged_hse) then

           print *, 'Error zone', i, ' did not converge in init_1d'
           print *, 'integrate up'
           print *, 'dens_zone, temp_zone = ', dens_zone, temp_zone
           print *, "p_want = ", p_want
           print *, "drho = ", drho
           call bl_error('Error: HSE non-convergence')

        endif

        if (temp_zone < temp_fluff) then
           temp_zone = temp_fluff
        endif

     else
        dens_zone = low_density_cutoff
        temp_zone = temp_fluff
     endif

     ! call the EOS one more time for this zone and then go on to the next
     ! (t, rho) -> (p)

     eos_state%T     = temp_zone
     eos_state%rho   = dens_zone
     eos_state%xn(:) = xn(:)

     call eos(eos_input_rt, eos_state)

     pres_zone = eos_state%p

     ! update the thermodynamics in this zone
     model_hybrid_hse(i,idens) = dens_zone
     model_hybrid_hse(i,itemp) = temp_zone
     model_hybrid_hse(i,ipres) = pres_zone
     model_hybrid_hse(i,ientr) = eos_state%s
     model_hybrid_hse(i,isndspd) = &
          sqrt(eos_state%gam1*eos_state%p/eos_state%rho)

     eint_hybrid = eint_hybrid + &
          dens_zone*eos_state%e*FOUR3RD*M_PI*(xznr(i) - xznl(i)) * &
          (xznr(i)**2 +xznl(i)*xznr(i) + xznl(i)**2)

     M_enclosed(i) = M_enclosed(i-1) + &
          FOUR3RD*M_PI*(xznr(i) - xznl(i)) * &
          (xznr(i)**2 +xznl(i)*xznr(i) + xznl(i)**2)*model_hybrid_hse(i,idens)

  enddo

  !===========================================================================
  ! compute the conservative model
  !===========================================================================

  print *, 'creating conservative model...'
  print *, ' '

  allocate(model_conservative(nx,nvar+1))

  model_conservative(:,1:nvar) = model_mesa_hse(:,:)

  allocate(base_ener(npts_model))
  allocate(model_ener(nx))

  ! first calculate the eden across the model
  do i = 1, npts_model

     eos_state%rho = base_state(i,idens)
     eos_state%p = base_state(i,ipres)
     eos_state%xn(:) = base_state(i,ispec:ispec-1+nspec)

     if (eos_state%rho .gt. 1.d-10) then

        call eos(eos_input_rp, eos_state)
        base_ener(i) = eos_state%e * base_state(i,idens)

     else

        base_ener(i) = 0.0d0

     endif
  enddo

  do i = 1, nx

     model_conservative(i,n) = model_mesa_hse(i,n)

     call conservative_interpolate(model_ener(i), xzn_hse(i),npts_model,base_r, base_ener, delx, status)

     if (model_ener(i) < 0.0d0 .or. model_ener(i) /= model_ener(i) .or. (status .eq. 1)) then
        print *, "conservative interpolate of eden_model failed :("
        model_ener(i) = centered_interpolate(xzn_hse(i),npts_model,base_r,base_ener)
     endif
     !
     !
     do k = 1, nspec
        call conservative_interpolate(model_conservative(i,ispec-1+k),xzn_hse(i),npts_model,&
             base_r,base_state(:,ispec-1+k)*base_state(:,idens), delx, status)

        if (model_conservative(i,ispec-1+k) < 0.0d0 .or. &
             model_conservative(i,ispec-1+k) /= model_conservative(i,ispec-1+k) .or. &
             (status .eq. 1)) then
           print *, "conservative interpolate of X_i*dens_model failed :(", model_conservative(i,ispec-1+k)
           model_conservative(i,ispec-1+k) = centered_interpolate(xzn_hse(i),npts_model,base_r,&
                base_state(:,ispec-1+k)*base_state(:,idens))
        endif
     enddo

     model_conservative(i,idens) = sum(model_conservative(i,ispec:ispec+nspec-1))

     if (model_conservative(i,idens) < 0.0d0 .or. &
          model_conservative(i,idens) /= model_conservative(i,idens)) then
        print *, "summming of species' partial densities failed"
        model_conservative(i,idens) = centered_interpolate(xzn_hse(i),npts_model,base_r,&
             base_state(:,idens))
     endif

     model_conservative(i,nvar+1) = centered_interpolate(xzn_hse(i), npts_model, &
          base_r, base_state(:, imass))

  enddo

  do i = 1, nx
     eos_state%rho = model_conservative(i,idens)
     eos_state%e = model_ener(i) / model_conservative(i,idens)
     eos_state%xn(:) = model_conservative(i,ispec:ispec+nspec-1) / model_conservative(i,idens)

     call eos(eos_input_re, eos_state)

     model_conservative(i,itemp) = eos_state%T
     model_conservative(i,ipres) = eos_state%p
     model_conservative(i,ientr) = eos_state%s

     ! make sure that the species (mass fractions) sum to 1
     summ = 0.0d0
     do n = 1, nspec
        summ = summ + model_conservative(i,ispec+n-1)
     enddo

     do n = 1,nspec
        model_conservative(i,ispec+n-1) = max(smallx, model_conservative(i,ispec+n-1)/summ)
     enddo

  enddo

  ! print *, model_conservative(:, itemp)


  !-------------------
  ! Now do HSE
  !--------------------

  ! compute the enclosed mass
  M_enclosed(1) = FOUR3RD*M_PI*delx**3*model_conservative(1,idens)

  fluff = .FALSE.

  do i = 2, nx

     dens_zone = model_conservative(i,idens)
     temp_zone = model_conservative(i,itemp)

     xn(:) = model_conservative(i,ispec:ispec+nspec-1)

     ! compute the gravitational acceleration on the interface between zones
     ! i-1 and i
     g_zone = -Gconst*M_enclosed(i-1)/(xznr(i-1)*xznr(i-1))

     !-----------------------------------------------------------------------
     ! iteration loop
     !-----------------------------------------------------------------------

     ! HSE differencing
     p_want = model_conservative(i-1,ipres) + &
          delx*0.5d0*(dens_zone + model_conservative(i-1,idens))*g_zone

     temp_zone = model_conservative(i,itemp)

     ! (t, rho) -> (p)
     eos_state%T     = temp_zone
     eos_state%p     = p_want
     eos_state%rho   = dens_zone
     eos_state%xn(:) = xn(:)

     call eos(eos_input_rp, eos_state)

     pres_zone = eos_state%p

     temp_zone = eos_state%T

     ! update the thermodynamics in this zone
     ! model_conservative(i,idens) = dens_zone
     model_conservative(i,itemp) = temp_zone
     model_conservative(i,ipres) = pres_zone
     model_conservative(i,ientr) = eos_state%s
     model_conservative(i,isndspd) = &
          sqrt(eos_state%gam1*eos_state%p/eos_state%rho)
     model_conservative(i,ispec:ispec+nspec-1) = eos_state%xn

     M_enclosed(i) = M_enclosed(i-1) + &
          FOUR3RD*M_PI*(xznr(i) - xznl(i)) * &
          (xznr(i)**2 +xznl(i)*xznr(i) + xznl(i)**2)*model_conservative(i,idens)

  enddo

  deallocate(base_ener, model_ener)


  !===========================================================================
  ! compute the adiabatic excess model
  !===========================================================================

  print *, 'creating conserved adiabatic excess model...'
  print *, ' '

  allocate(model_ad_excess(nx,nvar))

  model_ad_excess(:,:) = model_mesa_hse(:,:)

  allocate(base_ad(npts_model))
  allocate(model_ad(nx))

  low_density_cutoff =1.d-8
  temp_fluff_cutoff = 2.d-8
  temp_fluff = 1.d4

  ! first calculate the adiabatic excess across the model
  do i = 2, npts_model

     eos_state%rho = base_state(i,idens)
     eos_state%p = base_state(i,ipres)
     eos_state%xn(:) = base_state(i,ispec:ispec-1+nspec)

     call eos(eos_input_rp, eos_state)

     ! gradP = base_gradr(i) * base_state(i, isndspd)**2

     ! if (i > 1) then
     !    print *, "gradr = ", base_gradr(i), "drhodr = ", (base_state(i,idens) - base_state(i-1,idens)) / (base_r(i) - base_r(i-1))
     ! endif

     ! base_ad(i) = base_gradT(i) / gradP * base_state(i, ipres) / base_state(i, itemp) - &
     !      eos_state%dpde / base_state(i,idens) / eos_state%gam1

     base_ad(i) = base_state(i, igradT) - eos_state%dpde / base_state(i,idens) / eos_state%gam1

  enddo

  do i = 1, nx

     model_ad_excess(i,n) = model_mesa_hse(i,n)

     call conservative_interpolate(model_ad(i), xzn_hse(i),npts_model,base_r, base_ad, delx, status)

     if (model_ad(i) /= model_ad(i) .or. (status .eq. 1)) then
        print *, "conservative interpolate of eden_model failed :("
        model_ad(i) = centered_interpolate(xzn_hse(i),npts_model,base_r,base_ad)
     endif

     do k = 1, nspec
        call conservative_interpolate(model_ad_excess(i,ispec-1+k),xzn_hse(i),npts_model,&
             base_r,base_state(:,ispec-1+k)*base_state(:,idens), delx, status)

        if (model_ad_excess(i,ispec-1+k) < 0.0d0 .or. &
             model_ad_excess(i,ispec-1+k) /= model_ad_excess(i,ispec-1+k) .or. &
             (status .eq. 1)) then
           print *, "conservative interpolate of X_i*dens_model failed :(", model_ad_excess(i,ispec-1+k)
           model_ad_excess(i,ispec-1+k) = centered_interpolate(xzn_hse(i),npts_model,base_r,&
                base_state(:,ispec-1+k)*base_state(:,idens))
        endif
     enddo

     model_ad_excess(i,idens) = sum(model_ad_excess(i,ispec:ispec+nspec-1))

     if (model_ad_excess(i,idens) < 0.0d0 .or. &
          model_ad_excess(i,idens) /= model_ad_excess(i,idens)) then
        print *, "summming of species' partial densities failed"
        model_ad_excess(i,idens) = centered_interpolate(xzn_hse(i),npts_model,base_r,&
             base_state(:,idens))
     endif

     ! model_ad_excess(i,nvar+1) = centered_interpolate(xzn_hse(i), npts_model, &
     !      base_r, base_m)

  enddo

  do i = 1, nx

     ! make sure that the species (mass fractions) sum to 1
     summ = 0.0d0
     do n = 1, nspec
        summ = summ + model_ad_excess(i,ispec+n-1)
     enddo

     do n = 1,nspec
        model_ad_excess(i,ispec+n-1) = max(smallx, model_ad_excess(i,ispec+n-1)/summ)
     enddo

  enddo

  ! print *, model_ad_excess(:, itemp)


  !-------------------
  ! Now do HSE
  !--------------------

  ! compute the enclosed mass
  M_enclosed(1) = FOUR3RD*M_PI*delx**3*model_ad_excess(1,idens)

  fluff = .FALSE.

  do i = 2, nx

     xn(:) = model_ad_excess(i,ispec:ispec+nspec-1)

     ! compute the gravitational acceleration on the interface between zones
     ! i-1 and i
     g_zone = -Gconst*M_enclosed(i-1)/(xznr(i-1)*xznr(i-1))

     !-----------------------------------------------------------------------
     ! iteration loop
     !-----------------------------------------------------------------------

     !------------------------
     ! first try HSE
     !-----------------------

     converged_hse = .FALSE.
     dens_zone = model_ad_excess(i-1,idens)
     temp_zone = model_ad_excess(i-1,itemp)

     do iter = 1, MAX_ITER

        ! HSE differencing
        p_want = model_ad_excess(i-1,ipres) + &
             delx*0.5d0*(dens_zone + model_ad_excess(i-1,idens))*g_zone

        ! if (model_ad_excess(i-1,idens) .lt. temp_fluff_cutoff) then
        !    temp_zone = temp_fluff
        ! end if

        ! (t, rho) -> (p)
        eos_state%T     = temp_zone
        eos_state%rho   = dens_zone
        eos_state%xn(:) = xn(:)

        call eos(eos_input_rt, eos_state)

        pres_zone = eos_state%p

        dpd = eos_state%dpdr
        drho = (p_want - pres_zone)/(dpd - 0.5d0*delx*g_zone)

        dens_zone = max(0.9d0*dens_zone, &
             min(dens_zone + drho, 1.1d0*dens_zone))

        if (abs(drho) < TOL*dens_zone) then
           converged_hse = .TRUE.
           exit
        endif

        ! if (dens_zone < low_density_cutoff) then
        !    dens_zone = low_density_cutoff
        !    temp_zone = temp_fluff
        !    converged_hse = .TRUE.
        !    fluff = .TRUE.
        !    index_hse_fluff = i
        !    exit
        !
        ! endif

     enddo

     temp_min = temp_zone!model_ad_excess(i-1,itemp)
     temp_max = temp_zone!model_ad_excess(i-1,itemp)
     err_min = 1.0d0
     err_max = 1.0d0
     ad_tol = 1.d-10

     n = 0

     do while (err_min * err_max > 0.0d0 .and. n < 10)

        temp_min = temp_min * 0.99d0
        temp_max = temp_max * 1.01d0

        eos_state%T = temp_min
        eos_state%rho = dens_zone
        eos_state%xn = xn(:)

        call eos(eos_input_rt, eos_state)

        pres_zone = eos_state%p

        adiabatic_excess = (temp_min - model_ad_excess(i-1,itemp)) / &
             (pres_zone - model_ad_excess(i-1,ipres)) * pres_zone / temp_min - &
             eos_state%dpde / dens_zone / eos_state%gam1

        err_min = model_ad(i) - adiabatic_excess

        eos_state%T = temp_max
        eos_state%rho = dens_zone
        eos_state%xn = xn(:)

        call eos(eos_input_rt, eos_state)

        pres_zone = eos_state%p

        adiabatic_excess = (temp_max - model_ad_excess(i-1,itemp)) / &
             (pres_zone - model_ad_excess(i-1,ipres)) * pres_zone / temp_max - &
             eos_state%dpde / dens_zone / eos_state%gam1

        err_max = model_ad(i) - adiabatic_excess

        n = n + 1

     enddo

     print_n = .FALSE.

     if (n > 5) then
        print *, 'err_min =' , err_min, "err_max = ", err_max, "n = ", n, "logR = ", log10(xzn_hse(i)/R_solar)
        print_n = .TRUE.
     endif

     if (err_min * err_max > 0.0d0) then

        ! set temperature to the one that minimises the error
        temp_zone = model_mesa_hse(i,itemp)

        eos_state%T = temp_max
        eos_state%rho = dens_zone
        eos_state%xn = xn(:)

        call eos(eos_input_rt, eos_state)

        pres_zone = eos_state%p

        adiabatic_excess = (temp_max - model_ad_excess(i-1,itemp)) / &
             (pres_zone - model_ad_excess(i-1,ipres)) * pres_zone / temp_max - &
             eos_state%dpde / dens_zone / eos_state%gam1

        ad_error = model_ad(i) - adiabatic_excess

        if (err_min < ad_error .and. err_min < err_max) then
           temp_zone = temp_min
        else if (err_max < ad_error) then
           temp_zone = temp_max
        endif

        dens_zone = model_mesa_hse(i, idens)

        eos_state%T = temp_zone
        eos_state%rho = dens_zone
        eos_state%xn = xn(:)

        call eos(eos_input_rt, eos_state)

        pres_zone = eos_state%p

        p_want = model_ad_excess(i-1,ipres) + &
             delx*0.5d0*(dens_zone + model_ad_excess(i-1,idens))*g_zone
     else

        n = 0
        ad_error = 1.0d0

        do while (abs(ad_error) > ad_tol .and. n < AD_ITER)

           temp_zone = 0.5d0 * (temp_min + temp_max)

           ! HSE differencing
           p_want = model_ad_excess(i-1,ipres) + &
                delx*0.5d0*(dens_zone + model_ad_excess(i-1,idens))*g_zone

           eos_state%T = temp_zone
           eos_state%rho = dens_zone
           eos_state%xn = xn(:)

           call eos(eos_input_rt, eos_state)

           pres_zone = eos_state%p
           !
           ! dpd = eos_state%dpdr
           ! drho = (p_want - pres_zone)/(dpd - 0.5d0*delx*g_zone)
           !
           ! hse_error = abs(drho) / dens_zone

           if (temp_zone .eq. 0.0d0 .or. dens_zone .eq. 0.0d0) then
              print *, "temp_zone =", temp_zone, "dens_zone =", dens_zone
           endif

           if (abs(pres_zone - model_ad_excess(i-1,ipres) ) < 1e-12) then
              adiabatic_excess = (temp_zone - model_ad_excess(i-1,itemp)) / &
                   smallx * pres_zone / temp_zone - &
                   eos_state%dpde / dens_zone / eos_state%gam1

              ! print *, "hack"

           else

              adiabatic_excess = (temp_zone - model_ad_excess(i-1,itemp)) / &
                   (pres_zone - model_ad_excess(i-1,ipres)) * pres_zone / temp_zone - &
                   eos_state%dpde / dens_zone / eos_state%gam1
           endif

           ! print * , adiabatic_excess, model_ad(i)

           ad_error = model_ad(i) - adiabatic_excess

           if (err_min * ad_error < 0) then
              temp_max = temp_zone
           else
              temp_min = temp_zone
           endif

           n = n + 1

        enddo

        if (abs(ad_error) > ad_tol) then
           temp_zone = model_mesa_hse(i,itemp)
           dens_zone = model_mesa_hse(i, idens)

           eos_state%T = temp_zone
           eos_state%rho = dens_zone
           eos_state%xn = xn(:)

           call eos(eos_input_rt, eos_state)

           pres_zone = eos_state%p

           p_want = model_ad_excess(i-1,ipres) + &
                delx*0.5d0*(dens_zone + model_ad_excess(i-1,idens))*g_zone
        endif

        ! enddo

        if (print_n) then
           print *, "error = ", ad_error, "rel_err = ", ad_error / model_ad(i), "n = ", n, "logR = ", log10(xzn_hse(i)/R_solar)
        endif
     endif

     !------------------------
     ! Now do HSE
     !-----------------------

     converged_hse = .FALSE.

     do iter = 1, MAX_ITER

        ! HSE differencing
        p_want = model_ad_excess(i-1,ipres) + &
             delx*0.5d0*(dens_zone + model_ad_excess(i-1,idens))*g_zone

        ! if (model_ad_excess(i-1,idens) .lt. temp_fluff_cutoff) then
        !    temp_zone = temp_fluff
        ! end if

        ! (t, rho) -> (p)
        eos_state%T     = temp_zone
        eos_state%rho   = dens_zone
        eos_state%xn(:) = xn(:)

        call eos(eos_input_rt, eos_state)

        pres_zone = eos_state%p

        dpd = eos_state%dpdr
        drho = (p_want - pres_zone)/(dpd - 0.5d0*delx*g_zone)

        dens_zone = max(0.9d0*dens_zone, &
             min(dens_zone + drho, 1.1d0*dens_zone))

        if (abs(drho) < TOL*dens_zone) then
           converged_hse = .TRUE.
           exit
        endif

        ! if (dens_zone < low_density_cutoff) then
        !    dens_zone = low_density_cutoff
        !    temp_zone = temp_fluff
        !    converged_hse = .TRUE.
        !    fluff = .TRUE.
        !    index_hse_fluff = i
        !    exit
        !
        ! endif

     enddo

     ! (t, rho) -> (p)
     eos_state%T     = temp_zone
     eos_state%p     = p_want
     eos_state%rho   = dens_zone
     eos_state%xn(:) = xn(:)

     call eos(eos_input_rp, eos_state)

     pres_zone = eos_state%p

     temp_zone = eos_state%T

     ! update the thermodynamics in this zone
     ! model_conservative(i,idens) = dens_zone
     model_ad_excess(i,itemp) = temp_zone
     model_ad_excess(i,ipres) = pres_zone
     model_ad_excess(i,ientr) = eos_state%s
     model_ad_excess(i,isndspd) = &
          sqrt(eos_state%gam1*eos_state%p/eos_state%rho)
     model_ad_excess(i,ispec:ispec+nspec-1) = eos_state%xn

     M_enclosed(i) = M_enclosed(i-1) + &
          FOUR3RD*M_PI*(xznr(i) - xznl(i)) * &
          (xznr(i)**2 +xznl(i)*xznr(i) + xznl(i)**2)*model_ad_excess(i,idens)

  enddo

  deallocate(base_ad, model_ad)!, base_gradT, base_gradr)


  !===========================================================================
  ! output
  !===========================================================================

  !---------------------------------------------------------------------------
  ! MESA model
  !---------------------------------------------------------------------------

  ipos = index(model_file, '.dat')
  outfile = model_file(1:ipos-1) // '.hse'

  write(num,'(i8)') nx

  outfile = trim(outfile) // '.' // trim(adjustl(num))

  print *, 'writing HSE MESA model to ', trim(outfile)

  open (unit=50, file=outfile, status="unknown")

  write (50,1001) "# npts = ", nx
  write (50,1001) "# num of variables = ", 3 + nspec
  write (50,1002) "# density"
  write (50,1002) "# temperature"
  write (50,1002) "# pressure"

  do n = 1, nspec
     write (50,1003) "# ", spec_names(n)
  enddo

1001 format(a, i5)
1002 format(a)
1003 format(a,a)

  do i = 1, nx

     write (50,1000) xzn_hse(i), model_mesa_hse(i,idens), model_mesa_hse(i,itemp), model_mesa_hse(i,ipres), &
          (model_mesa_hse(i,ispec-1+n), n=1,nspec)

  enddo

  close (unit=50)

  ! compute the enclosed mass
  M_enclosed(1) = FOUR3RD*M_PI*delx**3*model_mesa_hse(1,idens)

  do i = 2, nx
     M_enclosed(i) = M_enclosed(i-1) + &
          FOUR3RD*M_PI*(xznr(i) - xznl(i)) * &
          (xznr(i)**2 +xznl(i)*xznr(i) + xznl(i)**2)*model_mesa_hse(i,idens)
  enddo

  print *, 'summ mass = ', real(M_enclosed(nx)), ' g = ', real(M_enclosed(nx)/M_solar), ' solar masses'

  ! compute the maximum HSE error
  max_hse_error = -1.d30

  do i = 2, nx-1
     g_zone = -Gconst*M_enclosed(i-1)/xznr(i-1)**2
     dpdr = (model_mesa_hse(i,ipres) - model_mesa_hse(i-1,ipres))/delx
     rhog = HALF*(model_mesa_hse(i,idens) + model_mesa_hse(i-1,idens))*g_zone

     if (dpdr /= ZERO .and. model_mesa_hse(i+1,idens) > low_density_cutoff) then
        max_hse_error = max(max_hse_error, abs(dpdr - rhog)/abs(dpdr))
     endif
  enddo

  print *, 'maximum HSE error = ', max_hse_error
  print *, ' '

  !---------------------------------------------------------------------------
  ! isentropic model
  !---------------------------------------------------------------------------

  ipos = index(model_file, '.dat')
  outfile = model_file(1:ipos-1) // '.isentropic.hse'

  write(num,'(i8)') nx

  outfile = trim(outfile) // '.' // trim(adjustl(num))

  print *, 'writing HSE isentropic model to ', trim(outfile)

  open (unit=50, file=outfile, status="unknown")

  write (50,1001) "# npts = ", nx
  write (50,1001) "# num of variables = ", 3 + nspec
  write (50,1002) "# density"
  write (50,1002) "# temperature"
  write (50,1002) "# pressure"

  do n = 1, nspec
     write (50,1003) "# ", spec_names(n)
  enddo

  do i = 1, nx

     write (50,1000) xzn_hse(i), model_isentropic_hse(i,idens), model_isentropic_hse(i,itemp), model_isentropic_hse(i,ipres), &
          (model_isentropic_hse(i,ispec-1+n), n=1,nspec)

  enddo

  close (unit=50)

  ! compute the enclosed mass
  M_enclosed(1) = FOUR3RD*M_PI*delx**3*model_isentropic_hse(1,idens)

  do i = 2, nx
     M_enclosed(i) = M_enclosed(i-1) + &
          FOUR3RD*M_PI*(xznr(i) - xznl(i)) * &
          (xznr(i)**2 +xznl(i)*xznr(i) + xznl(i)**2)*model_isentropic_hse(i,idens)
  enddo

  print *, 'summ mass = ', real(M_enclosed(nx)), ' g = ', real(M_enclosed(nx)/M_solar), ' solar masses'


  ! compute the maximum HSE error
  max_hse_error = -1.d30

  do i = 2, nx-1
     g_zone = -Gconst*M_enclosed(i-1)/xznr(i-1)**2
     dpdr = (model_isentropic_hse(i,ipres) - model_isentropic_hse(i-1,ipres))/delx
     rhog = HALF*(model_isentropic_hse(i,idens) + model_isentropic_hse(i-1,idens))*g_zone

     if (dpdr /= ZERO .and. model_isentropic_hse(i+1,idens) > low_density_cutoff) then
        max_hse_error = max(max_hse_error, abs(dpdr - rhog)/abs(dpdr))
     endif
  enddo

  print *, 'maximum HSE error = ', max_hse_error
  print *, ' '


  !---------------------------------------------------------------------------
  ! hybrid model
  !---------------------------------------------------------------------------

  ipos = index(model_file, '.dat')
  outfile = model_file(1:ipos-1) // '.hybrid.hse'

  write(num,'(i8)') nx

  outfile = trim(outfile) // '.' // trim(adjustl(num))

  print *, 'writing HSE hybrid model to ', trim(outfile)

  open (unit=50, file=outfile, status="unknown")

  write (50,1001) "# npts = ", nx
  write (50,1001) "# num of variables = ", 3 + nspec
  write (50,1002) "# density"
  write (50,1002) "# temperature"
  write (50,1002) "# pressure"

  do n = 1, nspec
     write (50,1003) "# ", spec_names(n)
  enddo

  do i = 1, nx

     write (50,1000) xzn_hse(i), model_hybrid_hse(i,idens), model_hybrid_hse(i,itemp), model_hybrid_hse(i,ipres), &
          (model_hybrid_hse(i,ispec-1+n), n=1,nspec)

  enddo

  close (unit=50)

  ! compute the enclosed mass
  M_enclosed(1) = FOUR3RD*M_PI*delx**3*model_hybrid_hse(1,idens)

  do i = 2, nx
     M_enclosed(i) = M_enclosed(i-1) + &
          FOUR3RD*M_PI*(xznr(i) - xznl(i)) * &
          (xznr(i)**2 +xznl(i)*xznr(i) + xznl(i)**2)*model_hybrid_hse(i,idens)
  enddo

  print *, 'summ mass = ', real(M_enclosed(nx)), ' g = ', real(M_enclosed(nx)/M_solar), ' solar masses'

  if (i_isentropic == -1) then
     print *, "there is no convective region :("
  else
     print *, 'mass of convective region = ', real(M_enclosed(i_isentropic)), ' g = ', &
          real(M_enclosed(i_isentropic)/M_solar), ' solar masses'
     print *, 'radius of convective region = ', real(xzn_hse(i_isentropic)), ' cm'
  endif

  ! compute the maximum HSE error
  max_hse_error = -1.d30

  do i = 2, nx-1
     g_zone = -Gconst*M_enclosed(i-1)/xznr(i-1)**2
     dpdr = (model_hybrid_hse(i,ipres) - model_hybrid_hse(i-1,ipres))/delx
     rhog = HALF*(model_hybrid_hse(i,idens) + model_hybrid_hse(i-1,idens))*g_zone

     if (dpdr /= ZERO .and. model_hybrid_hse(i+1,idens) > low_density_cutoff) then
        max_hse_error = max(max_hse_error, abs(dpdr - rhog)/abs(dpdr))
     endif
  enddo

  print *, 'maximum HSE error = ', max_hse_error

  ! output the entropy

  outfile = model_file(1:ipos-1) // '.entropy'
  outfile = trim(outfile) // '.' // trim(adjustl(num))

  open (unit=60, file=outfile, status="unknown")

  do i = 1, nx
     write (60,1000) xzn_hse(i), model_mesa_hse(i,ientr)
  enddo

  close (unit=60)

  ! compute the mass enclosed inside the anelastic_cutoff
  M_enclosed_anel = FOUR3RD*M_PI*delx**3*model_hybrid_hse(1,idens)
  do i = 2, nx
     if (model_hybrid_hse(i,idens) >= anelastic_cutoff) then
        M_enclosed_anel = M_enclosed_anel + &
             FOUR3RD*M_PI*(xznr(i) - xznl(i)) * &
             (xznr(i)**2 +xznl(i)*xznr(i) + xznl(i)**2)*model_hybrid_hse(i,idens)
     else
        exit
     endif
  enddo

  print *, ' '
  print *, 'mass within anelastic_cutoff (', real(anelastic_cutoff), ') =', &
       real(M_enclosed_anel/M_solar), 'solar masses'

  ! compute the central sound speed
  print *, 'sound speed at center of star = ', model_hybrid_hse(1,isndspd)


  ! compute the gravitational potential energy
  M_center = FOUR3RD*M_PI*xzn_hse(1)**3*model_hybrid_hse(1,idens)

  ! dU = - G M dM / r;  dM = 4 pi r**2 rho dr  -->  dU = - 4 pi G r rho dr
  grav_ener = -FOUR*M_PI*Gconst*M_center*xzn_hse(1)*model_hybrid_hse(1,idens)*(xznr(1) - xznl(1))

  do i = 2, nx
     if (model_hybrid_hse(i,idens) >= anelastic_cutoff) then
        M_center = M_center + &
             FOUR3RD*M_PI*(xzn_hse(i) - xznl(i)) * &
             (xzn_hse(i)**2 +xznl(i)*xzn_hse(i) + xznl(i)**2)*model_hybrid_hse(i,idens) + &
             FOUR3RD*M_PI*(xznr(i-1) - xzn_hse(i-1)) * &
             (xznr(i-1)**2 +xzn_hse(i-1)*xznr(i-1) + xzn_hse(i-1)**2)*model_hybrid_hse(i-1,idens)

        ! dU = - G M dM / r;  dM = 4 pi r**2 rho dr  -->  dU = - 4 pi G r rho dr
        grav_ener = grav_ener - &
             FOUR*M_PI*Gconst*M_center*xzn_hse(i)*model_hybrid_hse(i,idens)*(xznr(i) - xznl(i))
     else
        exit
     endif
  enddo

  print *, "gravitational potential energy = ", grav_ener
  print *, "internal energy = ", eint_hybrid
  print *, ' '

  !---------------------------------------------------------------------------
  ! conservative model
  !---------------------------------------------------------------------------

  ipos = index(model_file, '.dat')
  outfile = model_file(1:ipos-1) // '.conservative'

  write(num,'(i8)') npts_model

  outfile = trim(outfile) // '.' // trim(adjustl(num))

  print *, 'writing conservative model to ', trim(outfile)

  open (unit=50, file=outfile, status="unknown")

  write (50,1001) "# npts = ", nx !npts_model
  write (50,1001) "# num of variables = ", 3 + nspec + 1
  write (50,1002) "# density"
  write (50,1002) "# temperature"
  write (50,1002) "# pressure"

  do n = 1, nspec
     write (50,1003) "# ", spec_names(n)
  enddo

  write (50,1002) "# mass"

  do i = 1, nx

     write (50,1000) xzn_hse(i), model_conservative(i,idens), model_conservative(i,itemp), model_conservative(i,ipres), &
          (model_conservative(i,ispec-1+n), n=1,nspec), model_conservative(i,nvar+1)

  enddo

  close (unit=50)


  !---------------------------------------------------------------------------
  ! conservative model
  !---------------------------------------------------------------------------

  ipos = index(model_file, '.dat')
  outfile = model_file(1:ipos-1) // '.adiabatic'

  write(num,'(i8)') npts_model

  outfile = trim(outfile) // '.' // trim(adjustl(num))

  print *, 'writing conserved adiabatic excess model to ', trim(outfile)

  open (unit=50, file=outfile, status="unknown")

  write (50,1001) "# npts = ", nx !npts_model
  write (50,1001) "# num of variables = ", 3 + nspec
  write (50,1002) "# density"
  write (50,1002) "# temperature"
  write (50,1002) "# pressure"

  do n = 1, nspec
     write (50,1003) "# ", spec_names(n)
  enddo

  write (50,1002) "# mass"

  do i = 1, nx

     write (50,1000) xzn_hse(i), model_ad_excess(i,idens), model_ad_excess(i,itemp), model_ad_excess(i,ipres), &
          (model_ad_excess(i,ispec-1+n), n=1,nspec)

  enddo

  close (unit=50)

  ! ! compute the enclosed mass
  ! M_enclosed(1) = FOUR3RD*M_PI*delx**3*model_conservative(1,idens)
  !
  ! do i = 2, nx
  !    M_enclosed(i) = M_enclosed(i-1) + &
  !         FOUR3RD*M_PI*(xznr(i) - xznl(i)) * &
  !         (xznr(i)**2 +xznl(i)*xznr(i) + xznl(i)**2)*model_conservative(i,idens)
  ! enddo
  !
  ! print *, 'summ mass = ', real(M_enclosed(nx)), ' g = ', real(M_enclosed(nx)/M_solar), ' solar masses'


  ! ! compute the maximum HSE error
  ! max_hse_error = -1.d30
  !
  ! do i = 2, nx-1
  !    g_zone = -Gconst*M_enclosed(i-1)/xznr(i-1)**2
  !    dpdr = (model_conservative(i,ipres) - model_conservative(i-1,ipres))/delx
  !    rhog = HALF*(model_conservative(i,idens) + model_conservative(i-1,idens))*g_zone
  !
  !    if (dpdr /= ZERO .and. model_conservative(i+1,idens) > low_density_cutoff) then
  !       max_hse_error = max(max_hse_error, abs(dpdr - rhog)/abs(dpdr))
  !    endif
  ! enddo
  !
  ! print *, 'maximum HSE error = ', max_hse_error
  ! print *, ' '

contains


  function interpolate(r, npts, model_r, model_var)

    use bl_types

    implicit none

    ! given the array of model coordinates (model_r), and variable (model_var),
    ! find the value of model_var at point r using linear interpolation.
    ! Eventually, we can do something fancier here.

    real(kind=dp_t) :: interpolate
    real(kind=dp_t), intent(in) :: r
    integer :: npts
    real(kind=dp_t), dimension(npts) :: model_r, model_var

    real(kind=dp_t) :: slope
    real(kind=dp_t) :: minvar, maxvar

    integer :: i, id

    ! find the location in the coordinate array where we want to interpolate
    do i = 1, npts
       if (model_r(i) >= r) exit
    enddo

    id = i

    if (id == 1) then

       slope = (model_var(id+1) - model_var(id))/(model_r(id+1) - model_r(id))
       interpolate = slope*(r - model_r(id)) + model_var(id)

       ! safety check to make sure interpolate lies within the bounding points
       !minvar = min(model_var(id+1),model_var(id))
       !maxvar = max(model_var(id+1),model_var(id))
       !interpolate = max(interpolate,minvar)
       !interpolate = min(interpolate,maxvar)

    else

       slope = (model_var(id) - model_var(id-1))/(model_r(id) - model_r(id-1))
       interpolate = slope*(r - model_r(id)) + model_var(id)

       ! safety check to make sure interpolate lies within the bounding points
       minvar = min(model_var(id),model_var(id-1))
       maxvar = max(model_var(id),model_var(id-1))
       interpolate = max(interpolate,minvar)
       interpolate = min(interpolate,maxvar)

    endif

    return

  end function interpolate

  ! function conservative_interpolate(r, npts, model_r, model_var)
  subroutine conservative_interpolate(interpolated, r, npts_model, model_r, model_var, dx, status, iloc)

    !     given the array of model coordinates (model_r), and variable (model_var),
    !     find the value of model_var at point r (var_r) using linear interpolation.
    !     Eventually, we can do something fancier here.
    use bl_types
    use amrex_error_module

    implicit none

    real(kind=dp_t)        , intent(in   ) :: r, dx
    integer         , intent(in   ) :: npts_model
    real(kind=dp_t)        , intent(in   ) :: model_r(npts_model), model_var(npts_model)
    integer, intent(in), optional   :: iloc
    real(kind=dp_t)        , intent(out  ) :: interpolated
    integer         , intent(out  ) :: status

    ! Local variables
    integer                         :: max_iter = 5
    integer                         :: i, n, n_boxes
    real(kind=dp_t)                        :: rel_error = 1.d0
    real(kind=dp_t)                        :: delta = 1.d-4
    real(kind=dp_t)                        :: summ, rm
    ! real(kind=dp_t)               :: centered_interpolate


    interpolated = centered_interpolate(r, npts_model, model_r, model_var, iloc)

    status = 0

    do n = 1, max_iter
       if (rel_error <= delta) exit

       summ = 0.0d0
       n_boxes = 2**n

       do i = 1, n_boxes
          rm = r - 0.5 * dx + dx * (float(i-1) + 0.5d0) / float(n_boxes)
          summ = summ + 1.0d0 / float(n_boxes) * centered_interpolate(rm, npts_model, model_r, model_var)
       enddo

       rel_error = abs(summ - interpolated) / abs(interpolated)

       interpolated = summ

    enddo

    if (rel_error >  delta) status = 1

  end subroutine conservative_interpolate


  function centered_interpolate(r, npts_model, model_r, model_var, iloc) result(interpolated)

    !     given the array of model coordinates (model_r), and variable (model_var),
    !     find the value of model_var at point r (var_r) using linear interpolation.
    !     Eventually, we can do something fancier here.
    use bl_types

    implicit none

    real(kind=dp_t)                        :: interpolated
    real(kind=dp_t)        , intent(in   ) :: r
    integer         , intent(in   ) :: npts_model
    real(kind=dp_t)        , intent(in   ) :: model_r(npts_model), model_var(npts_model)
    integer, intent(in), optional   :: iloc

    ! Local variables
    integer                         :: id
    real(kind=dp_t)                        :: slope,minvar,maxvar

    !     find the location in the coordinate array where we want to interpolate
    if (present(iloc)) then
       id = iloc
    else
       call locate_sub(r, npts_model, model_r, id)
    end if

    if (id .eq. 1) then

       slope = (model_var(id+1) - model_var(id))/(model_r(id+1) - model_r(id))
       interpolated = slope*(r - model_r(id)) + model_var(id)

       ! safety check to make sure interpolate lies within the bounding points
       minvar = min(model_var(id+1),model_var(id))
       maxvar = max(model_var(id+1),model_var(id))
       interpolated = max(interpolated,minvar)
       interpolated = min(interpolated,maxvar)

    else if (id .eq. npts_model) then

       slope = (model_var(id) - model_var(id-1))/(model_r(id) - model_r(id-1))
       interpolated = slope*(r - model_r(id)) + model_var(id)

       ! safety check to make sure interpolate lies within the bounding points
       minvar = min(model_var(id),model_var(id-1))
       maxvar = max(model_var(id),model_var(id-1))
       interpolated = max(interpolated,minvar)
       interpolated = min(interpolated,maxvar)

    else

       slope = 0.5d0 *( (model_var(id+1) - model_var(id))/(model_r(id+1) - model_r(id)) + &
            (model_var(id) - model_var(id-1))/(model_r(id) - model_r(id-1)) )
       interpolated = slope*(r - model_r(id)) + model_var(id)

       ! ! safety check to make sure interpolate lies within the bounding points
       minvar = min(model_var(id+1),model_var(id), model_var(id-1))
       maxvar = max(model_var(id+1),model_var(id), model_var(id-1))
       interpolated = max(interpolated,minvar)
       interpolated = min(interpolated,maxvar)


    endif

  end function centered_interpolate

  subroutine locate_sub(x, n, xs, loc)
    use bl_types

    implicit none

    integer,  intent(in   ) :: n
    real(rt), intent(in   ) :: x, xs(n)
    integer,  intent(  out) :: loc

    integer :: ilo, ihi, imid

    !$gpu

    if (x .le. xs(1)) then
       loc = 1
    else if (x .gt. xs(n-1)) then
       loc = n
    else

       ilo = 1
       ihi = n-1

       do while (ilo+1 .ne. ihi)
          imid = (ilo+ihi)/2
          if (x .le. xs(imid)) then
             ihi = imid
          else
             ilo = imid
          end if
       end do

       loc = ihi

    end if

  end subroutine locate_sub

end program init_1d
