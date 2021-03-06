module adjoint_source

  !! IMPORT VARIABLES FROM SPECFEM -------------------------------------------------------------------------------------------------
  use specfem_par, only: CUSTOM_REAL, NDIM, MAX_STRING_LEN, OUTPUT_FILES, IIN, network_name, station_name, nrec_local, &
       seismograms_d, seismograms_p, number_receiver_global

  use specfem_par_elastic, only: ispec_is_elastic, ELASTIC_SIMULATION
  use specfem_par_acoustic, only: ispec_is_acoustic, ACOUSTIC_SIMULATION

  !!--------------------------------------------------------------------------------------------------------------------------------
  !! IMPORT inverse_problem VARIABLES
  use inverse_problem_par
  use signal_processing

  implicit none

  !! PRIVATE ATTRIBUTE -------------------------------------------------------------------------------------------------------------
  real(kind=CUSTOM_REAL), private, dimension(:,:), allocatable      :: elastic_adjoint_source, elastic_misfit
  real(kind=CUSTOM_REAL), private, dimension(:), allocatable        :: raw_residuals, fil_residuals, filfil_residuals
  real(kind=CUSTOM_REAL), private, dimension(:), allocatable        :: residuals_for_cost
  real(kind=CUSTOM_REAL), private, dimension(:), allocatable        :: signal, w_tap
  real(kind=CUSTOM_REAL), private                                   :: fl, fh
  real(kind=CUSTOM_REAL), private                                   :: dt_data
  real(kind=CUSTOM_REAL), private                                   :: cost_value
  integer,                private                                   :: norder_filter=4, irek_filter=1
  integer,                private                                   :: nstep_data


contains
!%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
!-----------------------------------------------------------------------------------------------------------------------------------
!  Write adjoint sources in SEM directory
!-----------------------------------------------------------------------------------------------------------------------------------
  subroutine write_adjoint_sources_for_specfem(acqui_simu,  inversion_param, ievent, myrank)

    implicit none

    integer,                                     intent(in)     :: myrank, ievent
    type(inver),                                 intent(inout)  :: inversion_param
    type(acqui),  dimension(:), allocatable,     intent(inout)  :: acqui_simu

    integer                                                     :: icomp
    integer                                                     :: irec, irec_local, ispec

    real(kind=CUSTOM_REAL)                                      :: cost_function, cost_function_reduced
    real(kind=CUSTOM_REAL)                                      :: cost_function_rec

    integer                                                     :: lw, i0, i1, i2, i3
    integer                                                     :: current_iter

    nstep_data = acqui_simu(ievent)%Nt_data
    dt_data = acqui_simu(ievent)%dt_data

    current_iter=inversion_param%current_iteration

    !! initialize cost function for each MPI porcess
    cost_function  = 0._CUSTOM_REAL

    call allocate_adjoint_source_working_arrays()

    !! define taper on adjoint sources (if not window selected by user)
    lw=0.02*nstep_data  !!!! WARNGING HARDCODED !!!!!!!!!!!!
    i0=10
    i1=i0 + lw
    i3=nstep_data-10
    i2=i3 - lw
    call taper_window_W(w_tap,i0,i1,i2,i3,nstep_data,1._CUSTOM_REAL)
    !! to do define user window


    do irec_local = 1, nrec_local

       irec = number_receiver_global(irec_local)
       ispec = acqui_simu(ievent)%ispec_selected_rec(irec)
       cost_function_rec=0.

       !! ALLOW TO CHOOSE COMPONENT :
       !! UX UY UZ (check if in solid region)
       !! Pr (check if in fluid region)
       !! VX VY VZ

       if (ELASTIC_SIMULATION) then
          if (ispec_is_elastic(ispec)) then

             !! ---------------------------------------------------------------------------------------------------------------
             !! compute adjoint source according to cost L2 function
             call compute_elastic_adjoint_source_displacement(irec_local, ievent, current_iter, acqui_simu, cost_function)

          endif
       endif

       !! IN FLUIDS WITH need to save pressure and store the second time derivative of residuals
       !! raw_residuals(:)=seismograms_p(icomp,irec_local,:) - acqui_simu(ievent)%data_traces(irec_local,:,icomp)
       !! in fluid only one component : the pressure
       icomp=1
       if (ACOUSTIC_SIMULATION) then
          if (ispec_is_acoustic(ispec)) then

             !! ---------------------------------------------------------------------------------------------------------------
             !! compute adjoint source according to cost L2 function
             call compute_acoustic_adjoint_source_pressure_dot_dot(icomp, irec_local, ievent, acqui_simu, cost_function)

          endif

       endif

    enddo


    !! compute cost function   : allreduce cost_function
    cost_function_reduced=0._CUSTOM_REAL
    call sum_all_all_cr(cost_function, cost_function_reduced)

    !! add the cost function over all sources
    inversion_param%total_current_cost =inversion_param%total_current_cost + cost_function_reduced

    !! save cost function for the current source
    inversion_param%current_cost(ievent) = cost_function_reduced

    if (myrank == 0) then
       write(INVERSE_LOG_FILE,*) '      Cost function for this event : ', cost_function_reduced
    endif

    call deallocate_adjoint_source_working_arrays()

  end subroutine write_adjoint_sources_for_specfem

!----------------------------------------------------------------------------------------------------------------------------------
  subroutine deallocate_adjoint_source_working_arrays()
    deallocate(raw_residuals, fil_residuals,  filfil_residuals, w_tap, signal, residuals_for_cost, elastic_adjoint_source, &
         elastic_misfit)
  end subroutine deallocate_adjoint_source_working_arrays

!----------------------------------------------------------------------------------------------------------------------------------
  subroutine  allocate_adjoint_source_working_arrays()

    allocate(raw_residuals(nstep_data), fil_residuals(nstep_data), filfil_residuals(nstep_data), &
         w_tap(nstep_data), signal(nstep_data), residuals_for_cost(nstep_data), &
         elastic_adjoint_source(NDIM,nstep_data), elastic_misfit(NDIM,nstep_data))

  end subroutine allocate_adjoint_source_working_arrays

!%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
!-----------------------------------------------------------------------------------------------------------------------------------
! define adjoint sources
!-----------------------------------------------------------------------------------------------------------------------------------
!
! to implement a new cost function and adjoint source :
!
!    1 /   define character to name your cost function and adjoint source type :  acqui_simu(ievent)%adjoint_source_type
!
!    2/    add a case for your new adjoint source
!
!    3/    compute the adjoint source whcih is stored in acqui(ievent)%adjoint_sources(NCOM, NREC_LOCAL, NT)
!          note that this arrays will be directly use be specfem as adjoint source thus you need to
!          do any proccessing here : filter, rotation, ....
!
!    4/    compute the cost function and store it in cost_function variable (you have to perform sommation over sources)
!
!
!
  subroutine compute_elastic_adjoint_source_displacement(irec_local, ievent, current_iter, acqui_simu, cost_function)


    integer,                                     intent(in)    :: ievent, irec_local, current_iter
    type(acqui),  dimension(:), allocatable,     intent(inout) :: acqui_simu
    real(kind=CUSTOM_REAL),                      intent(inout) :: cost_function
    integer                                                    :: icomp !, icomp_tmp
    !!----------------------------------------------------------------------------------------------------
    !! store residuals and filter  ---------------------------

    !! TO DO : convolve seismograms_d(icomp,irec_local,:) by source time function stf (if need)
    !! if (acqui_simu(ievent)%convlove_residuals_by_wavelet) then
    !!     signal(:) = seismograms_d(icomp,irec_local,:)
    !!     call convolution_by_wavelet(wavelet, signal, seismograms_d(icomp,irec_local,:), nstep, nw)
    !! endif


    !! TO DO : for now only L2 fwi is used, we should consider other adjoint sources
    !!
    !!   -- travel time kernel
    !!   -- Enveloppe
    !!   -- rotation to change components
    !!

    select case (trim(adjustl(acqui_simu(ievent)%adjoint_source_type)))

    case ('L2_FWI_TELESEISMIC')

       do icomp = 1, NDIM

          raw_residuals(:)=seismograms_d(icomp,irec_local,:) - acqui_simu(ievent)%data_traces(irec_local,:,icomp)

          fil_residuals(:)=0._CUSTOM_REAL
          filfil_residuals(:)=0._CUSTOM_REAL
          fl=acqui_simu(ievent)%freqcy_to_invert(icomp,1,irec_local)
          fh=acqui_simu(ievent)%freqcy_to_invert(icomp,2,irec_local)
          call bwfilt (raw_residuals, fil_residuals, dt_data, nstep_data, irek_filter, norder_filter, fl, fh)
          call bwfilt (fil_residuals, filfil_residuals, dt_data, nstep_data, irek_filter, norder_filter, fl, fh)


          !! TO DO : cross correlate filfil_residuals by source time function (if need)
          !! if (acqui_simu(ievent)%convlove_residuals_by_wavelet) then
          !!    signal(:) =  filfil_residuals(:);
          !!    call crosscor_by_wavelet(wavelet, signal, filfil_residuals, nstep, nw)
          !! endif


          !! TO DO : choose component to invert

          !! remove component if not used
          if (trim(acqui_simu(ievent)%component(icomp)) == '0' .or. &
               trim(acqui_simu(ievent)%component(icomp)) == '  ' ) then
             filfil_residuals(:)=0._CUSTOM_REAL
             fil_residuals(:)=0._CUSTOM_REAL
          endif

          !! compute cost function value
          cost_value=sum(fil_residuals(:)**2) * 0.5 * dt_data
          cost_function = cost_function + cost_value

          !! TO DO : cross correlate filfil_residuals by source time function (if need)
          !! if (acqui_simu(ievent)%convlove_residuals_by_wavelet) then
          !!    signal(:) =  filfil_residuals(:)
          !!    call crosscor_by_wavelet(wavelet, signal, filfil_residuals, nstep, nw)
          !! endif


          !!----------------------------------------------------------------------------------------------------


          !! store the adjoint source
          elastic_adjoint_source(icomp,:) = filfil_residuals(:)
          acqui_simu(ievent)%adjoint_sources(icomp,irec_local,:) = filfil_residuals(:)*w_tap(:)
       enddo

       !!----------------------------------------------------------------------------------------------------

       case ('L2_OIL_INDUSTRY')

          do icomp = 1, NDIM

             !! filter the data
             fil_residuals(:)=0._CUSTOM_REAL
             fl=acqui_simu(ievent)%freqcy_to_invert(icomp,1,irec_local)
             fh=acqui_simu(ievent)%freqcy_to_invert(icomp,2,irec_local)
             raw_residuals(:)= acqui_simu(ievent)%data_traces(irec_local,:,icomp)
             call bwfilt(raw_residuals, fil_residuals, dt_data, nstep_data, irek_filter, norder_filter, fl, fh)

             !! save filtered data
             acqui_simu(ievent)%synt_traces(icomp, irec_local,:)= fil_residuals(:)

             !! define energy renormalisation
             if (current_iter == 0) then
!!$                do icomp_tmp = 1, NDIM
!!$                   acqui_simu(ievent)%weight_trace(icomp,irec_local)=100._CUSTOM_REAL / &
!!$                        ((sum( acqui_simu(ievent)%synt_traces(irec_local,:,icomp_tmp) )**2) *0.5*dt_data)
!!$                enddo
                acqui_simu(ievent)%weight_trace(icomp,irec_local)=1._CUSTOM_REAL
             endif

             !! adjoint source
             raw_residuals(:)= (seismograms_d(icomp,irec_local,:) - fil_residuals(:))*&
                  acqui_simu(ievent)%weight_trace(icomp,irec_local)

             !! compute cost
             cost_value=sum(raw_residuals(:)**2) * 0.5 * dt_data
             cost_function = cost_function + cost_value

             ! store adjoint source
             acqui_simu(ievent)%adjoint_sources(icomp,irec_local,:)=raw_residuals(:)*w_tap(:)*&
                  acqui_simu(ievent)%weight_trace(icomp,irec_local)

          enddo

       case default

       end select



  end subroutine compute_elastic_adjoint_source_displacement

!%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
!-----------------------------------------------------------------------------------------------------------------------------------
! define adjoint sources
!-----------------------------------------------------------------------------------------------------------------------------------
  subroutine compute_acoustic_adjoint_source_pressure_dot_dot(icomp, irec_local, ievent, acqui_simu, cost_function)

    integer,                                     intent(in)    :: ievent, icomp, irec_local
    type(acqui),  dimension(:), allocatable,     intent(inout) :: acqui_simu
    real(kind=CUSTOM_REAL),                      intent(inout) :: cost_function
    !!--------------------------------------------------------------------------------------------------
    !! TO DO : convolve seismograms_d(icomp,irec_local,:) by source time function stf (if need)
    !! if (acqui_simu(ievent)%convlove_residuals_by_wavelet) then
    !!     signal(:) = seismograms_d(icomp,irec_local,:)
    !!     call convolution_by_wavelet(wavelet, signal, seismograms_d(icomp,irec_local,:), nstep, nw)
    !! endif
    !! for acoustics need - sign (eg : Luo and Tromp Geophysics 2013)

    select case (trim(adjustl(acqui_simu(ievent)%adjoint_source_type)))

    case ('L2_FWI_TELESEISMIC')
       raw_residuals(:)=-(seismograms_p(icomp,irec_local,:) - acqui_simu(ievent)%data_traces(irec_local,:,icomp))
       residuals_for_cost(:) = raw_residuals(:) !! save residuals because the adjoint source is not residuals

       !! compute second time derivative of raw_residuals
       call FD2nd(raw_residuals, dt_data, NSTEP_DATA)

       fil_residuals(:)=0._CUSTOM_REAL
       filfil_residuals(:)=0._CUSTOM_REAL
       fl=acqui_simu(ievent)%freqcy_to_invert(icomp,1,irec_local)
       fh=acqui_simu(ievent)%freqcy_to_invert(icomp,2,irec_local)
       call bwfilt (raw_residuals, fil_residuals, dt_data, nstep_data, irek_filter, norder_filter, fl, fh)
       call bwfilt (fil_residuals, filfil_residuals, dt_data, nstep_data, irek_filter, norder_filter, fl, fh)

       !! compute residuals
       call bwfilt (residuals_for_cost, fil_residuals, dt_data, nstep_data, irek_filter, norder_filter, fl, fh)
       cost_value=sum(fil_residuals(:)**2) * 0.5 * dt_data
       cost_function = cost_function + cost_value

       !! store adjoint source
       acqui_simu(ievent)%adjoint_sources(1,irec_local,:)=filfil_residuals(:)*w_tap(:)

    case ('L2_OIL_INDUSTRY')

       !! filter the data
       fil_residuals(:)=0._CUSTOM_REAL
       fl=acqui_simu(ievent)%freqcy_to_invert(icomp,1,irec_local)
       fh=acqui_simu(ievent)%freqcy_to_invert(icomp,2,irec_local)
       raw_residuals(:)= acqui_simu(ievent)%data_traces(irec_local,:,icomp)
       call bwfilt(raw_residuals, fil_residuals, dt_data, nstep_data, irek_filter, norder_filter, fl, fh)

       !! save filtered data
       acqui_simu(ievent)%synt_traces(icomp, irec_local,:)= fil_residuals(:)

       !! save residuals for adjoint source. Note we use the difference between
       !! obseved pressure and computed pressure, not the approach in Luo and Tromp Gepohysics 2013
       !! which define the adjoint source as " minus second time derivatives of previous residuals "
       !! We consider that the forward modeling is writen in pressure thus
       !! the adjoint is rho*displacement potential.
       residuals_for_cost(:) =  - (seismograms_p(icomp,irec_local,:) - fil_residuals(:))

       !! compute cost
       cost_value=sum(residuals_for_cost(:)**2) * 0.5 * dt_data
       cost_function = cost_function + cost_value

       !! store adjoint source
       acqui_simu(ievent)%adjoint_sources(1,irec_local,:)=residuals_for_cost(:)*w_tap(:)


    case default

    end select
    !-------------------------------------------------------------------------------------------------

    !! TO DO : cross correlate filfil_residuals by source time function (if need)
    !! if (acqui_simu(ievent)%convlove_residuals_by_wavelet) then
    !!    signal(:) =  filfil_residuals(:);
    !!    call crosscor_by_wavelet(wavelet, signal, filfil_residuals, nstep, nw)
    !! endif

  end subroutine compute_acoustic_adjoint_source_pressure_dot_dot

!%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
!                         methods to interface with calling from external module
!%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
!------------------------------------------
subroutine get_filfil_residuals(sout)

  real(kind=CUSTOM_REAL)     :: sout(*)
  integer                    :: i
  do i=1, NSTEP_DATA
     sout(i)=filfil_residuals(i)
  enddo

end subroutine get_filfil_residuals
!------------------------------------------
subroutine get_filfil_residuals_in_reverse(sout)

  real(kind=CUSTOM_REAL)     :: sout(*)
  integer                    :: i
  do i=1, NSTEP_DATA
     sout(i)=filfil_residuals(NSTEP_DATA-i+1)
  enddo

end subroutine get_filfil_residuals_in_reverse
!------------------------------------------
subroutine get_elastic_adj_src(sout,ir)

  real(kind=CUSTOM_REAL) , dimension(:,:,:),allocatable     :: sout
  integer                    :: i, ic, ir
  do i=1, NSTEP_DATA
     do ic=1,3
        sout(ic,ir,i)=elastic_adjoint_source(ic,NSTEP_DATA-i+1)
     enddo
  enddo
end subroutine get_elastic_adj_src
!------------------------------------------
subroutine get_acoustic_adj_src(sout,ir)

  real(kind=CUSTOM_REAL), dimension(:,:,:),allocatable     :: sout
  integer                    :: i, ic, ir
  do i=1, NSTEP_DATA
     do ic=1,3
        sout(ic,ir,i)=filfil_residuals(NSTEP_DATA-i+1)
     enddo
  enddo
end subroutine get_acoustic_adj_src

!--------------------------------------------
subroutine put_dt_nstep_for_adjoint_sources(delta_t, nb_time_step)
  integer,                intent(in) :: nb_time_step
  real(kind=CUSTOM_REAL), intent(in) :: delta_t
  nstep_data=nb_time_step
  dt_data=delta_t
end subroutine put_dt_nstep_for_adjoint_sources

!%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
!-----------------------------------------------------------------------------------------------------------------------------------
!
!-----------------------------------------------------------------------------------------------------------------------------------
end module adjoint_source


