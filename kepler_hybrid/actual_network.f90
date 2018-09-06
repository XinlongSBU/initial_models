
! DO NOT EDIT THIS FILE!!!  
!  
! This file is automatically generated by write_network.py at 
! compile-time.  
!  
! To modify the species carried by the network, edit the appropriate inputs 
! file.

! An automatically generated "null" network.  This provides the properties
! of a set of non-reacting species.
!
! network_name     -- a descriptive name of the network
!
! nspec            -- the number of species
!
! aion             -- atomic number
! zion             -- proton number
!
! spec_names       -- the name of the isotope
! short_spec_names -- an abbreviated form of the species name
!
!
! This module contains two routines:
!
!  network_init()        -- initialize the isotope properties
!
!  network_species_index -- return the index of the species given its name
!

module actual_network

  use bl_types

  implicit none

  integer, parameter :: nspec = 3
  integer, parameter :: nspec_evolve = 3
  integer, parameter :: naux = 0

  character (len=16), save :: spec_names(nspec) 
  character (len= 5), save :: short_spec_names(nspec)
  character (len= 5), save :: short_aux_names(naux)

  character (len=*), parameter :: network_name = "general-ignition_wdconvect.net"

  real(kind=dp_t), save :: aion(nspec), zion(nspec)

  integer, parameter :: nrates = 0

contains
  
  subroutine actual_network_init()

    implicit none

    spec_names(1) = "carbon-12"
    spec_names(2) = "oxygen-16"
    spec_names(3) = "ash"

    short_spec_names(1) = "C12"
    short_spec_names(2) = "O16"
    short_spec_names(3) = "ash"

    aion(1) = 12.0
    aion(2) = 16.0
    aion(3) = 18.0

    zion(1) = 6.0
    zion(2) = 8.0
    zion(3) = 8.8

  end subroutine actual_network_init

  
  subroutine actual_network_finalize

    implicit none

    ! Nothing to do here.

  end subroutine actual_network_finalize

end module actual_network