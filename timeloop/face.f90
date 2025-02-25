module face

    use define_globals
    use define_indexes
    use define_keys
    use define_settings, only: setting
    use adjust
    use geometry
    use jump
    use utility_profiler
    use utility, only: util_sign_with_ones, util_CLprint, util_syncwrite
    use utility_crash, only: util_crashpoint
    !use utility_unit_testing, only: util_utest_CLprint


    implicit none

    !%----------------------------------------------------------------------
    !% Description:
    !% Provides computation of face values for timeloop of hydraulics
    !%
    !% Methods:
    !% The faces values are determined by interpolation.
    !%
    !%----------------------------------------------------------------------
    private

    public :: face_interpolation
    public :: face_interpolate_bc
    !public :: face_FluxCorrection_interior
    ! public :: face_flowrate_max_interior
    ! public :: face_flowrate_max_shared

    contains
!%==========================================================================
!% PUBLIC
!%==========================================================================
!%
    subroutine face_interpolation (facecol, whichTM)
        !%------------------------------------------------------------------
        !% Description:
        !% Interpolates faces from elements
        !% NOTE -- calls to this subroutine CANNOT be within a conditional
        !% that would prevent it from being called by all images. That is,
        !% this subroutine MUST be called by all images (even with a null)
        !% to make sure that the images can be synced before sharing.
        !%------------------------------------------------------------------
        !% Declarations
            integer, intent(in)  :: faceCol, whichTM
            integer, pointer :: Npack
            logical :: isBConly, isTM
            integer :: iblank
            
            character(64) :: subroutine_name = 'face_interpolation'
        !%-------------------------------------------------------------------
        !% Preliminaries    
            if (setting%Debug%File%face) &
                write(*,"(A,i5,A)") '*** enter ' // trim(subroutine_name) // " [Processor ", this_image(), "]"
            
            if (setting%Profile%useYN) call util_profiler_start (pfc_face_interpolation)
        !%--------------------------------------------------------------------
        isBConly = .false.

        !% --- the whichTM is dummy for diagnostic elements,
        !%     For diagnostic element we don't want to call the Q_HeadGradient term.
        if (whichTM == dummy) then
            isTM = .false.
        else
            isTM = .true.
        end if

        ! print *, 'in face AAAA ',faceR(43,fr_Depth_u), faceR(43,fr_Flowrate)
        
        !% --- face reconstruction of all the interior faces
        call face_interpolation_interior (faceCol)

        ! print *, 'in face BBBB ',faceR(43,fr_Depth_u), faceR(43,fr_Flowrate)

            ! call util_utest_CLprint ('    face after face_interpolation_interior')

        !% --- force zero fluxes on closed element downstream faces
        !%     note this does not require a "faceCol" argument as we
        !%     will execute this for both fp_all and fp_Diag calls
        call adjust_face_for_zero_setting ()

        ! print *, 'in face CCCC ',faceR(42,fr_Depth_u)

            ! call util_utest_CLprint ('    face after adjust face for zero setting')

        call face_zerodepth_interior(fp_elem_downstream_is_zero)
        call face_zerodepth_interior(fp_elem_upstream_is_zero)
        call face_zerodepth_interior(fp_elem_bothsides_are_zero)

        ! print *, 'in face DDDD ',faceR(42,fr_Depth_u)

            ! call util_utest_CLprint ('    face after face zerodepth interior')

        !% --- face reconstruction of all the shared faces
        call face_interpolation_shared (faceCol)

            ! call util_utest_CLprint ('    face after face interpolation_shared')

        call face_interpolate_bc (isBConly)

            ! call util_utest_CLprint ('    face after face_interpolate_BC')

        ! print *, 'in face EEEE ',faceR(42,fr_Depth_u)

        ! !% --- Force face areas and depths to zero for Head <= Zbottom TEST -- DOES NOT WORK 20221230 brh
        ! call face_head_limited (faceCol)

        !%-------------------------------------------------------------------
        !% Closing
            if (setting%Profile%useYN) call util_profiler_stop (pfc_face_interpolation)

            if (setting%Debug%File%face)  &
                write(*,"(A,i5,A)") '*** leave ' // trim(subroutine_name) // " [Processor ", this_image(), "]"
    end subroutine face_interpolation
!%    
!%==========================================================================    
!%==========================================================================
!%
    subroutine face_interpolate_bc(isBConly)
        !%------------------------------------------------------------------
        !% Description:
        !% Interpolates all data to upstream and downstream faces
        !% when isBConly == true, this only handles BC enforcement
        !%-------------------------------------------------------------------
        !% Declarations:
            logical, intent(in) :: isBConly
            character (64) :: subroutine_name = 'face_interpolate_bc'
        !%-------------------------------------------------------------------
            if (setting%Debug%File%face)  &
                write(*,"(A,i5,A)") '*** enter ' // trim(subroutine_name) // " [Processor ", this_image(), "]"
        !%-------------------------------------------------------------------

        if ((N_nBCup > 0) .or. (N_nJ1 > 0)) call face_interpolation_upBC(isBConly)

            ! call util_CLprint ('    face after face_interpolation_upBC')

        !% brh20211211 MOVED -- this is an element update
        !rm if (N_nBClat > 0) call face_interpolation_latBC_byPack()

        if (N_nBCdn > 0) call face_interpolation_dnBC(isBConly)

            ! call util_CLprint ('    face after face_interpolation_dnBC')

        !%-------------------------------------------------------------------
        !% Closing
            if (setting%Debug%File%face) &
                write(*,"(A,i5,A)") '*** leave ' // trim(subroutine_name) // " [Processor ", this_image(), "]"

    end subroutine face_interpolate_bc
!%    
!%==========================================================================    
!% PRIVATE
!%==========================================================================
!%
    subroutine face_interpolation_upBC(isBConly)
        !%------------------------------------------------------------------
        !% Description:
        !% Interpolates data to all upstream BC faces
        !% When called with isBConly == true, only does the BC update
        !%------------------------------------------------------------------
        !% Declarations:
            logical, intent(in) :: isBConly
            integer :: fGeoSetU(2), fGeoSetD(2), eGeoSet(2)
            integer :: ii
            integer, pointer :: edn(:), idx_P(:), fdn(:)
            integer, pointer :: idx_fBC(:), idx_fJ1(:), idx_fBoth(:)
            character(64) :: subroutine_name = 'face_interpolation_upBC'
        !%-------------------------------------------------------------------
        !% Preliminaries
            if (setting%Debug%File%boundary_conditions)  &
                write(*,"(A,i5,A)") '*** enter ' // trim(subroutine_name) // " [Processor ", this_image(), "]"
        !%-------------------------------------------------------------------
        !% Aliases
        !% For the head/geometry at the upstream faces, we directly take the dnwnstream element
        !% So there is no eup for upstream BCs
            edn       => faceI(:,fi_Melem_dL)
            fdn       => elemI(:,ei_Mface_dL)   
            idx_fBC   => faceP(1:npack_faceP(fp_BCup),fp_BCup)
            idx_fJ1   => faceP(1:npack_faceP(fp_J1),  fp_J1)
            idx_fBoth => faceP(1:npack_faceP(fp_J1_BCup),  fp_J1_BCup)
            idx_P     => BC%P%BCup(:)
        !%-------------------------------------------------------------------
        !% enforce stored inflow BC    
        faceR(idx_fBC, fr_Flowrate) = BC%flowR(idx_P,br_value)

        ! print *, 'in face_interpolation_upBC'
        ! print *, faceR(idx_fBC,fr_Area_d), faceR(idx_fBC, fr_Flowrate)

        !% enforce zero flow on J1 faces
        faceR(idx_fJ1, fr_Flowrate) = zeroR
        faceR(idx_fJ1, fr_Velocity_u) = zeroR
        faceR(idx_fJ1, fr_Velocity_d) = zeroR

        !% update geometry data (don't do on a BC-only call)
        if (.not. isBConly) then
            !% Define sets of points for the interpolation, we are going from
            !% the elements to the faces.       
            !fGeoSetU = [fr_Area_u, fr_Topwidth_u, fr_HydDepth_u]
            !fGeoSetD = [fr_Area_d, fr_Topwidth_d, fr_HydDepth_d]
            !eGeoSet  = [er_Area,   er_Topwidth,   er_EllDepth]

            fGeoSetU = [fr_Area_u, fr_Depth_u]
            fGeoSetD = [fr_Area_d, fr_Depth_d]
            eGeoSet  = [er_Area,   er_Depth]

            !% Copying geometric data from elements to the BC/J1 faces
            do ii = 1,size(fGeoSetU)
                faceR(idx_fBoth,fGeoSetD(ii)) = elemR(edn(idx_fBoth),eGeoSet(ii)) 
                !% upstream side of face matches downstream (no jump)
                faceR(idx_fBoth,fGeoSetU(ii)) = faceR(idx_fBoth,fGeoSetD(ii))
            end do

            !% --- HACK: copy the preissmann number as well
            !%     Note that for static slot this will always be unity
            faceR(idx_fBoth,fr_Preissmann_Number) = elemR(edn(idx_fBoth),er_Preissmann_Number) 
            
            !% gradient extrapolation for head at infow
            faceR(idx_fBC, fr_Head_d) = elemR(edn(idx_fBC),er_Head)       &
                                      + elemR(edn(idx_fBC),er_Head)        &
                                      - faceR(fdn(edn(idx_fBC)),fr_Head_d) 

            !% zero head gradient at J1 cells
            faceR(idx_fJ1,fr_Head_d) = elemR(edn(idx_fJ1),er_Head) 

            !% head on downstream side of face is copied to upstream side (no jump)
            faceR(idx_fBoth,fr_Head_u) = faceR(idx_fBoth,fr_Head_d)
           
            !% ensure face area_u is not smaller than zerovalue
            where (faceR(idx_fBC,fr_Area_d) <= setting%ZeroValue%Area)
                faceR(idx_fBC,fr_Area_d)     = setting%ZeroValue%Area
            end where
            where (faceR(idx_fBC,fr_Area_u) <= setting%ZeroValue%Area)
                faceR(idx_fBC,fr_Area_u)     = setting%ZeroValue%Area
            endwhere

        end if

        !% set velocity based on flowrate
        faceR(idx_fBC,fr_Velocity_d) = faceR(idx_fBC,fr_Flowrate)/faceR(idx_fBC,fr_Area_d)
        faceR(idx_fBC,fr_Velocity_u) = faceR(idx_fBC,fr_Velocity_d)  

        !%  If an inflow has a high velocity, reset the value of the high velocity limiter
        !%  
        if (setting%Limiter%Velocity%UseLimitMaxYN) then            
            where(abs(faceR(idx_fBC,fr_Velocity_d))  > setting%Limiter%Velocity%Maximum)
                faceR(idx_fBC,fr_Velocity_d) = sign(0.99d0 * setting%Limiter%Velocity%Maximum, &
                    faceR(idx_fBC,fr_Velocity_d))
            endwhere
            where(abs(faceR(idx_fBC,fr_Velocity_u))  > setting%Limiter%Velocity%Maximum)
                faceR(idx_fBC,fr_Velocity_u) = sign(0.99d0 * setting%Limiter%Velocity%Maximum, &
                    faceR(idx_fBC,fr_Velocity_u))
            endwhere
        end if

        !stop 209873

        !%-------------------------------------------------------------------
        !% Closing
            if (setting%Debug%File%boundary_conditions) &
                write(*,"(A,i5,A)") '*** leave ' // trim(subroutine_name) // " [Processor ", this_image(), "]"
    end subroutine face_interpolation_upBC
!%
!%==========================================================================
!%==========================================================================
!%
!% brh 20211211 moved and renamed -- this doesn't belong in Face routines
! subroutine face_interpolation_latBC_byPack()
        
    !     !%-----------------------------------------------------------------------------
    !     !% Description:
    !     !% Interpolates all boundary faces using a pack arrays -- base on bi_category
    !     !%-----------------------------------------------------------------------------
    !     !integer :: fGeoSetU(3), fGeoSetD(3), eGeoSet(3)
    !     !integer :: fFlowSet(1), 
    !     integer :: ii
    !     integer, pointer :: elem_P(:), idx_P(:)
    !     integer :: eFlowSet(1)
    !     !integer :: fHeadSetU(1), fHeadSetD(1), eHeadSet(1)
    !     character(64) :: subroutine_name = 'face_interpolation_latBC_byPack'

    !     !%-----------------------------------------------------------------------------
    !     if (setting%Debug%File%boundary_conditions)  &
    !         write(*,"(A,i5,A)") '*** enter ' // trim(subroutine_name) // " [Processor ", this_image(), "]"


    !     elem_P => elemP(1:npack_elemP(ep_BClat),ep_BClat)
    !     idx_P  => BC%P%BClat

    !     !fGeoSetU = [fr_Area_u, fr_Topwidth_u, fr_HydDepth_u]
    !     !fGeoSetD = [fr_Area_d, fr_Topwidth_d, fr_HydDepth_d]
    !     !eGeoSet  = [er_Area,   er_Topwidth,   er_HydDepth]

    !     !fHeadSetU = [fr_Head_u]
    !     !fHeadSetD = [fr_Head_d]
    !     !eHeadSet = [er_Head]

    !     !fFlowSet = [fr_Flowrate]
    !     eFlowSet = [er_FlowrateLateral]

    !     do ii=1,size(eFlowSet)
    !         elemR(elem_P,eFlowSet(ii)) = BC%flowR(idx_P,br_value)
    !     end do
    !     !% For lateral flow, just update the flow at the element >> elemR(flow) + BC_lateral_flow

    !     if (setting%Debug%File%boundary_conditions) &
    !         write(*,"(A,i5,A)") '*** leave ' // trim(subroutine_name) // " [Processor ", this_image(), "]"
    ! end subroutine face_interpolation_latBC_byPack
!%
!%==========================================================================
!%==========================================================================
!%
    subroutine face_interpolation_dnBC(isBConly)
        !%------------------------------------------------------------------
        !% Description:
        !% Interpolates data to all downstream boundary faces
        !% When called with isBConly == true, only does the BC update
        !%-------------------------------------------------------------------
        !% Declarations
            logical, intent(in) :: isBConly
            !integer :: fGeoSetU(3), fGeoSetD(3), eGeoSet(3)
            integer :: ii
            integer, pointer :: idx_fBC(:), eup(:), idx_P(:)
            integer, pointer :: elemUpstream
            real(8), pointer :: depthBC(:), headBC(:), eHead(:),  eFlow(:)
            real(8), pointer :: eVelocity(:), eZbottom(:), eLength(:)
            real(8), pointer :: eVolume(:), grav, eDepth(:), eTopwidth(:)
            logical, pointer :: isZeroDepth(:), hasFlapGateBC(:)
            !real(8), pointer :: eArea(:), eHydDepth(:), eTopWidth(:)
            real(8) :: Vtemp, headdif, thisDepth, thisVolume, thisQ
            character(64) :: subroutine_name = 'face_interpolation_dnBC'
        !%--------------------------------------------------------------------
        !% Preliminaries
            if (setting%Debug%File%boundary_conditions)  &
                write(*,"(A,i5,A)") '*** enter ' // trim(subroutine_name) // " [Processor ", this_image(), "]"
        !%--------------------------------------------------------------------
        !% Aliases
            eup           => faceI(:,fi_Melem_uL)
            idx_fBC       => faceP(1:npack_faceP(fp_BCdn),fp_BCdn)
            idx_P         => BC%P%BCdn
            depthBC       => BC%headR(:,br_Temp01)
            headBC        => BC%headR(:,br_value)
            hasFlapGateBC => BC%headYN(:,bYN_hasFlapGate) 
            eDepth        => elemR(:,er_Depth)
            eHead         => elemR(:,er_Head)
            eFlow         => elemR(:,er_Flowrate)
            eTopwidth     => elemR(:,er_TopWidth)
            eVelocity     => elemR(:,er_Velocity)
            eZbottom      => elemR(:,er_Zbottom)
            eVolume       => elemR(:,er_Volume)
            eLength       => elemR(:,er_Length)
            isZeroDepth   => elemYN(:,eYN_isZeroDepth)
            grav        => setting%Constant%gravity
            ! eArea     => elemR(:,er_Area)
            ! eHydDepth => elemR(:,er_HydDepth)
            ! eTopWidth => elemR(:,er_TopWidth)
        !%--------------------------------------------------------------------   
        !% For fixed, tidal, and timeseries BC
        !% The BC is imagined as enforced on a ghost cell outside the boundary
        !% so the face value is given by linear interpolation using ghost and interior cells 


        !% --- upstream face head is the BC
        !faceR(idx_fBC, fr_Head_u) = 0.5 * (eHead(eup(idx_fBC)) + headBC) 
        faceR(idx_fBC, fr_Head_u)  = headBC(idx_P)
        faceR(idx_fBC, fr_Depth_u) = max(headBC(idx_P) - faceR(idx_fBC,fr_Zbottom), setting%ZeroValue%Depth*0.99d0)

        ! print*, ' '
        ! print *, 'in ',trim(subroutine_name)
        ! print *, 'BC Head idx ', BC%headI(:, bi_idx)
        ! print *, 'BC head cat ', BC%headI(:, bi_subcategory)
        ! print *, 'BC head key ', trim(reverseKey(BC%headI(1, bi_subcategory))), ' ',trim(reverseKey(BC%headI(1, bi_subcategory)))
        ! print *, 'face ID ', idx_fBC
        ! print *, 'faceR head value ', faceR(idx_fBC, fr_Head_u)
        ! print *, 'BC head ',headBC(idx_P)
        ! print *, 'BC depth',headBC(idx_P) - faceR(idx_fBC,fr_Zbottom)

        !% --- the downstream side of face is the same as the upstream face (unless gate, see below)
        faceR(idx_fBC, fr_Head_d)  = faceR(idx_fBC, fr_Head_u)
        faceR(idx_fBC, fr_Depth_d) = faceR(idx_fBC, fr_Depth_u)

        ! print *, 'e head, head bc ', eHead(eup(idx_fBC)), headBC(idx_P)
        
        !% --- for a flap gate on a BC with higher head downstream
        where ( hasFlapGateBC(idx_P) .and. (eHead(eup(idx_fBC))  < headBC(idx_P) ) )
            !% --- reset the head on the upstream and downstream side of face for closed gate
            faceR(idx_fBC, fr_Head_u)  = eHead(eup(idx_fBC))
            faceR(idx_fBC, fr_Depth_u) = max(eHead(eup(idx_fBC)) - faceR(idx_fBC,fr_Zbottom), setting%ZeroValue%Depth*0.99d0)
            faceR(idx_fBC, fr_Head_d)  = headBC(idx_P)
            faceR(idx_fBC, fr_Depth_d) = max(headBC(idx_P)       - faceR(idx_fBC,fr_Zbottom), setting%ZeroValue%Depth*0.99d0)
        endwhere

        ! print *, 'faceR value head ',faceR(idx_fBC, fr_Head_u), faceR(idx_fBC, fr_Head_d)

        ! call util_utest_CLprint ('    face interpolate down BC')
        
        !% --- get geometry for face from upstream element shape
        if (.not. isBConly) then
            !% --- get the depth on the face (upstream) from BC (temporary store)
            !%     this ensures that if gate is closed the depth is the upstream depth
            depthBC(idx_P) = faceR(idx_fBC, fr_Depth_u) !faceR(idx_fBC, fr_Head_u) - faceR(idx_fBC,fr_Zbottom)

            !% --- compute elldepth, topwidth, area geometry from depth based on relationship for upstream element
            !%     but using the depthBC at the upstream side of the face (which may be closed gate)   
            do ii=1,size(idx_fBC)
                elemUpstream => eup(idx_fBC(ii))
                !faceR(idx_fBC(ii),fr_HydDepth_u) = geo_hyddepth_from_depth_singular(elemUpstream,depthBC(idx_P(ii)))
                !faceR(idx_fBC(ii),fr_Topwidth_u) = geo_topwidth_from_depth_singular(elemUpstream,depthBC(idx_P(ii)))
                faceR(idx_fBC(ii),fr_Area_u)     = geo_area_from_depth_singular   &
                    (elemUpstream, depthBC(idx_P(ii)), setting%ZeroValue%Area)
                !faceR(idx_fBC(ii),fr_HydDepth_u) = geo_hyddepth_from_area_and_topwidth_singular(elemUpstream, faceR(idx_fBC(ii),fr_Area_u),faceR(idx_fBC(ii),fr_Topwidth_u) )
                ! faceR(idx_fBC(ii),fr_EllDepth_u) = geo_elldepth_singular &
                !     (faceR(idx_fBC, fr_Head_u), faceR(idx_fBC(ii),fr_Area_u), faceR(idx_fBC(ii),fr_Topwidth_u), &
                !      elemR(elemUpstream,er_AreaBelowBreadthMax), elemR(elemUpstream,er_BreadthMax), elemR(elemUpstream,er_ZbreadthMax))
                
                ! !% TEST 20220712--- apply simple linear interpolation to prevent large downstream area from causing numerical problems
                ! !% 20220712brh
                ! faceR(idx_fBC(ii),fr_Area_u)     =  (faceR(idx_fBC(ii),fr_Area_u)     + eArea(elemUpstream)    ) * onehalfR
                ! faceR(idx_fBC(ii),fr_HydDepth_u) =  (faceR(idx_fBC(ii),fr_HydDepth_u) + eHydDepth(elemUpstream)) * onehalfR
                ! faceR(idx_fBC(ii),fr_Topwidth_u) =  (faceR(idx_fBC(ii),fr_Topwidth_u) + eTopWidth(elemUpstream)) * onehalfR
            end do
            !% --- store downstream side of face
            !faceR(idx_fBC,fr_Topwidth_d) = faceR(idx_fBC,fr_Topwidth_u) 
            faceR(idx_fBC,fr_Area_d)     = faceR(idx_fBC,fr_Area_u) 
            !faceR(idx_fBC,fr_HydDepth_d) = faceR(idx_fBC,fr_HydDepth_u)

            ! print *, ' '
            ! print *, 'in face_interpolation_dnBC'
            ! print *, 'depthBC ',depthBC(idx_P(1))
            ! print *, 'area    ',faceR(idx_fBC(1),fr_Area_u)
            ! print *, ' '
            ! !stop 2987355

            !% --- set the flowrate at the boundary
            do ii = 1,size(idx_fBC)
                !% --- upstream element ID
                elemUpstream => eup(idx_fBC(ii))

                !% --- default face flowrate is the upstream element flowrate
                faceR(idx_fBC(ii),fr_Flowrate) = eFlow(elemUpstream)

                !% --- check for closed flap gate
                if (hasFlapGateBC(idx_P(ii))) then
                    ! print *, 'has flapgate'
                    if (faceR(idx_fBC(ii), fr_Head_u) < headBC(idx_P(ii))) then
                        !% --- set BC flow to zero for closed flap gate
                        !%     no outflow until head at face upstream exceeds the gate BC head
                        faceR(idx_fBC(ii), fr_Flowrate) = zeroR
                        ! print *, 'setting face flowrate to zero'
                    else
                        !% --- set BC flow to the flow at the upstream element center
                        !%     note that if the upstream value is negative the BC is set to zero
                        !%     to prevent backflow.
                        faceR(idx_fBC(ii), fr_Flowrate) = max(eFlow(elemUpstream),zeroR)
                        ! print *, 'face flowrate ',faceR(idx_fBC(ii), fr_Flowrate)
                    end if
                end if

                !% --- limit the flowrate based on volume to bring upstream element
                !%     to the same elevation as the head BC
                !%     if headdif > 0 then thisQ >0 represents a limit on the outflow
                !%     if headdif < 0 then thisQ <0 represents a limit on the inflow
                headdif = eHead(elemUpstream) - faceR(idx_fBC(ii), fr_Head_u)
                !% --- positive thisQ is an outflow
                thisQ   = onefourthR * headdif * eLength(elemUpstream)  &
                            * eTopwidth(elemUpstream) / setting%Time%Hydraulics%Dt

                !% --- flow limiters
                if (faceR(idx_fBC(ii), fr_Flowrate) .ge. zeroR) then 
                    !% --- nominal outflow
                    if (thisQ > zeroR) then
                        !% --- limit outflow to the smaller value
                        faceR(idx_fBC(ii), fr_Flowrate) = min(faceR(idx_fBC(ii), fr_Flowrate), thisQ) 
                    else 
                        !% --- outflow across a boundary of higher head should not occur
                        faceR(idx_fBC(ii), fr_Flowrate) = zeroR        
                    end if 
                else 
                    !% --- nominal inflow (cannot occur with flap gate)
                    if (thisQ > zeroR)  then 
                        !% --- inflow should not occur if thisQ > 0
                        faceR(idx_fBC(ii), fr_Flowrate) = zeroR  
                    else
                        !% headdif < 0 and thisQ < 0 implies backflow
                        if (isZeroDepth(elemUpstream))then
                            !% --- for zero depth, limit headdif by 50% of the face depth as the driving head
                            headdif = -min(-headdif, onehalfR * faceR(idx_fBC(ii),fr_Depth_d))
                            thisQ   = onefourthR * headdif * eLength(elemUpstream)  &
                                        * eTopwidth(elemUpstream) / setting%Time%Hydraulics%Dt
                        end if
                        if (eFlow(elemUpstream) < zeroR) then
                            !% --- nominal inflow over BC
                            !%     use the smaller magnitude (more positive value)
                            faceR(idx_fBC(ii), fr_Flowrate) = max(thisQ,eFlow(elemUpstream))
                        else
                            !% -- - use the filling value
                            faceR(idx_fBC(ii), fr_Flowrate) = thisQ
                        end if
                    end if
                end if
            end do

                !% --- handle possible backflows---------------------
                
                ! !% ---compute adverse head difference (from downstreamface to upstream element center)
                ! !%    that drives could drive an inflow on a downstream head BC        
                ! headdif = faceR(idx_fBC(ii), fr_Head_u) - eHead(elemUpstream)
                ! if (isZeroDepth(elemUpstream))then
                !     !% --- for zero depth, limit headdif by 50% of the face depth as the driving head
                !     !headdif = min(headdif, onehalfR * faceR(idx_fBC(ii),fr_HydDepth_d))
                !     headdif = min(headdif, onehalfR * faceR(idx_fBC(ii),fr_Depth_d))
                ! end if

                !  print *, 'ii, headdif ',ii, headdif
                !  print *, faceR(idx_fBC(ii), fr_Head_u), eHead(elemUpstream), eZbottom(elemUpstream)

                !% --- check for adverse head gradient going upstream from boundary
                !%     when element flow is downstream or zero
                !      note that when element velocity is already negative we do not add the headdif term
            !     if (headdif > zeroR) then 
            !         !% --- adverse head gradient at outlet
            !         if (eFlow(elemUpstream) .ge. zeroR) then
            !             !% --- potential for inflow from downstream boundary despite downstream
            !             !%     flow on element.
            !             !%     Piezometric head difference minus upstream velocity
            !             !%     head provides the velocity head of inflow
            !             !%     If positive, then this is the upstream velocity at face
            !             !%     If negative, then the downstream flow in element is
            !             !%     able to overcome the adverse piezometric head gradient,
            !             !%     so the difference provides a reduced outflow at face
            !             !% --- The following is the estimated Bernoulli velocity squared. Note that
            !             !%     this assumes Velocity sign is consistent with flowrate sign.
            !             !Vtemp = twoR * grav * headdif - (eVelocity(elemUpstream)**twoI)
            !             !%     Use the velocity head if the upstream flow is distributed over the downstream area
            !             Vtemp = twoR * grav * headdif - ((eFlow(elemUpstream) / faceR(idx_fBC(ii),fr_Area_u))**twoI)
            !             !% --- The +Vtemp is flow in the upstream (negative) direction
            !             Vtemp = -sign(sqrt(abs(Vtemp)),Vtemp)
            !             !% --- take the smaller of the Q implied by Vtemp and the downstream Q of the element
            !             !%     Note Vtemp < 0 is upstream flow and will automatically be selected here since the upstream
            !             !%     elem flowrate is guaranteed to be positive. The following statement simply
            !             !%     ensures that the head balance approach for a downstream flow Vtemp > 0 does not exceed existing
            !             !%     downstream flow on the element imlied by the (flowrate >= 0) conditional above.
            !             !%     NOTE this flowrate may be either upstream or downstream!
            !             faceR(idx_fBC(ii),fr_Flowrate) = min(Vtemp * faceR(idx_fBC(ii),fr_Area_u),eFlow(elemUpstream))

            !             !  print *, 'naive face flowrate ', faceR(idx_fBC(ii),fr_Flowrate)
            !         end if

            !         !% --- Limit inflow magnitude to that the brings level up to the BC elevation
            !         if (faceR(idx_fBC(ii),fr_Flowrate) < zeroR) then
            !             !% --- volume rate adjustment: negative flowrate cannot provide more volume than 
            !             !%     fills the pipe to the depth equivalent to the downstream BC head in a single time step.
            !             !%     This reduces oscillatory behavior by preventing over filling on back flow
            !             thisDepth  = faceR(idx_fBC(ii), fr_Head_u) - eZbottom(elemUpstream)

            !             ! print *, 'thisDepth ',thisDepth, elemR(elemUpstream,er_Depth)
            !             ! print *, 'this head ',faceR(idx_fBC(ii), fr_Head_u), elemR(elemUpstream,er_Head)
            !             ! print *, ' '
            !             ! print *, 'elemUpstream ',elemUpstream
            !             ! print *, 'head,z ', elemR(elemUpstream,er_Head), elemR(elemUpstream,er_Zbottom)
            !             ! print *, 'depth  ', elemR(elemUpstream,er_Head) - elemR(elemUpstream,er_Zbottom), elemR(elemUpstream,er_Depth)

            !             if (thisDepth > zeroR) then
            !                 ! !% --- get the volume of the upstream element if filled to the BC head level
            !                 ! thisVolume = geo_area_from_depth_singular(elemUpstream, thisDepth, setting%ZeroValue%Area) * eLength(elemUpstream)
            !                 ! !% --- flowrate to fill to this volume in one time step
            !                 ! thisQ      = (thisVolume - eVolume(elemUpstream)) / setting%Time%Hydraulics%Dt

            !                 ! print *, 'thisQ ',thisQ
            !                 ! print *, thisVolume, eVolume(elemUpstream), eVolume(73)

            !                 !% --- using volume caused problem with tables not being precisely invertable
            !                 !%     from depth -> area  and from volume -> depth -> area
            !                 !% --- approximate the volume flowrate into the upstream element
            !                 !%     by the volume associated with the depth difference
            !                 thisQ = onehalfR * (thisDepth - eDepth(elemUpstream)) * eLength(elemUpstream)  &
            !                         * eTopwidth(elemUpstream) / setting%Time%Hydraulics%Dt

            !                 if (thisQ > zeroR) then
            !                     !% --- inflow is allowed, but use the smaller magnitude flow (larger negative value)
            !                     faceR(idx_fBC(ii),fr_Flowrate) = max(faceR(idx_fBC(ii),fr_Flowrate),-thisQ)
            !                 else
            !                     !% --- if thisVolume <= 0, then upstream is already to the maximum level
            !                     faceR(idx_fBC(ii),fr_Flowrate) = zeroR
            !                 end if
                            
            !                 ! print *, 'face flowrate with depth ',faceR(idx_fBC(ii),fr_Flowrate)
            !             else
            !                 !% --- negative upstream depth implies Zbottom of upstream element is higher
            !                 !%     than the downstream BC.  We shouldn't get here because it should only 
            !                 !%     occur if headdif < 0, 
            !                 print *, 'CODE ERROR -- unexpected else condition reached'
            !                 call util_crashpoint(5593341)
            !             end if
            !         else
            !             !% --- if flowrate is > 0, no volume rate adjustment needed and we accept 
            !             !%     previously computed value
            !         end if
            !     else
            !         !% --- limit inflow to that which brings upstream element up to the head of the BC
            !         thisDepth  = faceR(idx_fBC(ii), fr_Head_u) - eZbottom(elemUpstream)
            !         if (thisDepth > zeroR) then
            !         else 
            !             !% --- negative upstream depth implies Zbottom of upstream element is higher
            !                 !%     than the downstream BC.  We shouldn't get here because it should only 
            !                 !%     occur if headdif < 0, 
            !             print *, 'CODE ERROR -- unexpected else condition reached'
            !                 call util_crashpoint(5593341)
            !         end if

            !         !% --- if there is no adverse head gradient or if element velocity is already negative
            !         !%     in/outflow rate is upstream element flowrate                        
            !         faceR(idx_fBC(ii), fr_Flowrate) = eFlow(elemUpstream)
            !     end if

            !     ! print *, 'final face flowrate ', faceR(idx_fBC(ii),fr_Flowrate)

            ! end do

            ! call util_utest_CLprint ('    face YYYY')

            !% --- set the Preissmann number to the upstream element value
            faceR(idx_fBC, fr_Preissmann_Number) = elemR(eup(idx_fBC), er_Preissmann_Number) 

            ! !% --- set to zero flow for closed gate  !% MOVED UP INTO DO LOOP 20220716brh
            ! where ( BC%headYN(idx_P, bYN_hasFlapGate) .and. (faceR(idx_fBC, fr_Head_u) < BC%headR(idx_P,br_value)) )
            !     faceR(idx_fBC, fr_Flowrate) = zeroR
            ! end where

            ! print *, 'face area u ', faceR(idx_fBC,fr_Area_u)
            ! print *, 'face area d ', faceR(idx_fBC,fr_Area_d)

            !% --- ensure face area_u is not smaller than zerovalue
            where (faceR(idx_fBC,fr_Area_d) < setting%ZeroValue%Area)
                faceR(idx_fBC,fr_Area_d) = setting%ZeroValue%Area
            endwhere
            where (faceR(idx_fBC,fr_Area_u) < setting%ZeroValue%Area)
                faceR(idx_fBC,fr_Area_u) = setting%ZeroValue%Area
            endwhere

            faceR(idx_fBC,fr_Velocity_u) = faceR(idx_fBC,fr_Flowrate)/faceR(idx_fBC,fr_Area_u)
            faceR(idx_fBC,fr_Velocity_d) = faceR(idx_fBC,fr_Flowrate)/faceR(idx_fBC,fr_Area_d)  

            ! print *, 'face velocity u ', faceR(idx_fBC,fr_Velocity_u)
            ! print *, 'face velocity d ', faceR(idx_fBC,fr_Velocity_d)

            !%  limit high velocities
            if (setting%Limiter%Velocity%UseLimitMaxYN) then
                where(abs(faceR(idx_fBC,fr_Velocity_u))  > setting%Limiter%Velocity%Maximum)
                    faceR(idx_fBC,fr_Velocity_u) = sign(0.99d0 * setting%Limiter%Velocity%Maximum, &
                        faceR(idx_fBC,fr_Velocity_u))
                endwhere 
                where(abs(faceR(idx_fBC,fr_Velocity_d))  > setting%Limiter%Velocity%Maximum)
                    faceR(idx_fBC,fr_Velocity_d) = sign(0.99d0 * setting%Limiter%Velocity%Maximum, &
                        faceR(idx_fBC,fr_Velocity_d))
                end where                    
            end if

            ! call util_utest_CLprint ('    face ZZZZ')
        else
            !% continue
        end if

        !%--------------------------------------------------------------------
        !% Closing
            if (setting%Debug%File%boundary_conditions) &
                write(*,"(A,i5,A)") '*** leave ' // trim(subroutine_name) // " [Processor ", this_image(), "]"
    end subroutine face_interpolation_dnBC
!%
!%==========================================================================
!%==========================================================================
!%
! subroutine face_interpolation_dnBC(isBConly)
    !     !%------------------------------------------------------------------
    !     !% Description:
    !     !% Interpolates all boundary faces using a pack arrays -- base on bi_category
    !     !%-----------------------------------------------------------------------------
    !     integer :: fGeoSetU(3), fGeoSetD(3), eGeoSet(3)
    !     integer :: fFlowSet(1), eFlowSet(1)
    !     integer :: fHeadSetU(1), fHeadSetD(1), eHeadSet(1)
    !     character(64) :: subroutine_name = 'face_interpolation_dnBC_byPack'
    !     integer :: ii
    !     integer, pointer :: face_P(:), eup(:), idx_P(:), bcType
    !     real :: DownStreamBcHead

    !     !%-----------------------------------------------------------------------------
    !     if (setting%Debug%File%boundary_conditions)  &
    !         write(*,"(A,i5,A)") '*** enter ' // trim(subroutine_name) // " [Processor ", this_image(), "]"


    !     eup => faceI(:,fi_Melem_uL)

    !     face_P => faceP(1:npack_faceP(fp_BCdn),fp_BCdn)
    !     idx_P  => BC%P%BCdn

    !     fGeoSetU = [fr_Area_u, fr_Topwidth_u, fr_HydDepth_u]
    !     fGeoSetD = [fr_Area_d, fr_Topwidth_d, fr_HydDepth_d]
    !     eGeoSet  = [er_Area,   er_Topwidth,   er_HydDepth]

    !     fHeadSetU = [fr_Head_u]
    !     fHeadSetD = [fr_Head_d]
    !     eHeadSet = [er_Head]

    !     fFlowSet = [fr_Flowrate]
    !     eFlowSet = [er_Flowrate]


    !     do ii=1,size(fHeadSetD)
    !         !%  linear interpolation using ghost and interior cells
    !         faceR(face_P, fHeadSetU(ii)) = 0.5 * (elemR(eup(face_P), er_Head) + BC%headR(idx_P,br_value)) !% downstream head update
    !         faceR(face_P, fHeadSetD(ii)) = faceR(face_P, fHeadSetU(ii))
    !     end do

    !     do ii=1,size(fFlowSet)
    !         faceR(face_P, fFlowSet(ii)) = elemR(eup(face_P), eFlowSet(ii)) !% Copying the flow from the upstream element
    !     end do

    !     do ii=1,size(fGeoSetD)
    !         faceR(face_P, fGeoSetD(ii)) = elemR(eup(face_P), eGeoSet(ii)) !% Copying other geo factors from the upstream element
    !         faceR(face_P, fGeoSetU(ii)) = faceR(face_P, fGeoSetD(ii))
    !     end do

    !     !% HACK: This is needed to be revisited later
    !     if (setting%ZeroValue%UseZeroValues) then
    !         !% ensure face area_u is not smaller than zerovalue
    !         where (faceR(face_P,fr_Area_d) < setting%ZeroValue%Area)
    !             faceR(face_P,fr_Area_d) = setting%ZeroValue%Area
    !             faceR(face_P,fr_Area_u) = setting%ZeroValue%Area
    !         endwhere

    !         !% HACK: This is needed to be revisited later
    !         if (setting%ZeroValue%UseZeroValues) then
    !             !% ensure face area_u is not smaller than zerovalue
    !             where (faceR(face_P,fr_Area_d) < setting%ZeroValue%Area)
    !                 faceR(face_P,fr_Area_d) = setting%ZeroValue%Area
    !                 faceR(face_P,fr_Area_u) = setting%ZeroValue%Area
    !             endwhere

    !             where (faceR(face_P,fr_Area_d) >= setting%ZeroValue%Area)
    !                 faceR(face_P,fr_Velocity_d) = faceR(face_P,fr_Flowrate)/faceR(face_P,fr_Area_d)
    !                 faceR(face_P,fr_Velocity_u) = faceR(face_P,fr_Velocity_d)  
    !             endwhere
    !         else
    !             !% ensure face area_u is not smaller than zerovalue
    !             where (faceR(face_P,fr_Area_d) < zeroR)
    !                 faceR(face_P,fr_Area_d) = zeroR
    !             endwhere

    !             where (faceR(face_P,fr_Area_d) >= zeroR)
    !                 faceR(face_P,fr_Velocity_d) = faceR(face_P,fr_Flowrate)/faceR(face_P,fr_Area_d)
    !                 faceR(face_P,fr_Velocity_u) = faceR(face_P,fr_Velocity_d)
    !             endwhere
    !         end if

    !         !%  limit high velocities
    !         if (setting%Limiter%Velocity%UseLimitMaxYN) then
    !             where(abs(faceR(face_P,fr_Velocity_d))  > setting%Limiter%Velocity%Maximum)
    !                 faceR(face_P,fr_Velocity_d) = sign(0.99d0 * setting%Limiter%Velocity%Maximum, &
    !                     faceR(face_P,fr_Velocity_d))

    !                 faceR(face_P,fr_Velocity_u) = faceR(face_P,fr_Velocity_d)
    !             endwhere
    !         end if
    !     else
    !         !% continue
    !     end if
      
    !     !% endif
    !     !%--------------------------------------------------------------------
    !     !% Closing
    !         if (setting%Debug%File%boundary_conditions) &
    !             write(*,"(A,i5,A)") '*** leave ' // trim(subroutine_name) // " [Processor ", this_image(), "]"
    ! end subroutine face_interpolation_dnBC

!%
!%==========================================================================
!%==========================================================================
!%
    subroutine face_interpolation_interior (facePackCol)
        !%------------------------------------------------------------------
        !% Description:
        !% Interpolates all faces using a pack
        !%------------------------------------------------------------------
            integer, intent(in) :: facePackCol  !% Column in faceP array for needed pack
            integer, pointer    ::  Npack        !% expected number of packed rows in faceP.
            integer :: fGeoSetU(2), fGeoSetD(2), eGeoSet(2)
            integer :: fHeadSetU(1), fHeadSetD(1), eHeadSet(1)
            integer :: fFlowSet(1), eFlowSet(1)
            integer :: fPreissmenSet(1), ePreissmenSet(1)
            character(64) :: subroutine_name = 'face_interpolation_interior'
        !%------------------------------------------------------------------
        !% Aliases       
            Npack => npack_faceP(facePackCol)
            if (Npack < 1) return
        !%------------------------------------------------------------------  
        !% Preliminaries    
            if (setting%Debug%File%face) &
                write(*,"(A,i5,A)") '*** enter ' // trim(subroutine_name) // " [Processor ", this_image(), "]"  
        !%------------------------------------------------------------------     
        !% Face values are needed for
        !% Area_u, Area_d, Head_u, Head_d, Flowrate,

        !% HACK: not sure if we need
        !% Topwidth_u, Topwidth_d, HydDepth_u, HydDepth_d
        !% Velocity_u, Velocity_d

        !% General approach
        !% interpolate to ..._u
        !% identify hydraulic jumps
        !% set .._u and ..d based on jumps
 

        !% set the matching sets
        !% THESE SHOULD BE DONE IN A GLOBAL -- MAYBE SETTINGS
        !% Note these can be expanded for other terms to be interpolated.
        !fGeoSetU = [fr_Area_u, fr_Topwidth_u, fr_HydDepth_u]
        !fGeoSetD = [fr_Area_d, fr_Topwidth_d, fr_HydDepth_d]
        !eGeoSet  = [er_Area,   er_Topwidth,   er_EllDepth]

        fGeoSetU = [fr_Area_u, fr_Depth_u]
        fGeoSetD = [fr_Area_d, fr_Depth_d]
        eGeoSet  = [er_Area,   er_Depth]

        fHeadSetU = [fr_Head_u]
        fHeadSetD = [fr_Head_d]
        eHeadSet = [er_Head]

        fFlowSet = [fr_Flowrate]
        eFlowSet = [er_Flowrate]

        fPreissmenSet = [fr_Preissmann_Number]
        ePreissmenSet = [er_Preissmann_Number]

            ! call util_utest_CLprint ('     face_interpolation_interior at start')

        !% two-sided interpolation to using the upstream face set
        call face_interp_interior_set &
            (fGeoSetU, eGeoSet, er_InterpWeight_dG, er_InterpWeight_uG, facePackCol, Npack) 

            !  ! call util_utest_CLprint ('     face_interpolation_interior at AAAA')

        call face_interp_interior_set &
            (fHeadSetU, eHeadSet, er_InterpWeight_dH, er_InterpWeight_uH, facePackCol, Npack)

        call face_interp_interior_set &
            (fFlowSet, eFlowSet, er_InterpWeight_dQ, er_InterpWeight_uQ, facePackCol, Npack)

        call face_interp_interior_set &
            (fPreissmenSet, ePreissmenSet, er_InterpWeight_dQ, er_InterpWeight_uQ, facePackCol, Npack)  


            !  ! call util_utest_CLprint ('     face_interpolation_interior at BBBB')

        !% copy upstream to downstream storage at a face
        !% (only for Head and Geometry types)
        !% note that these might be reset by hydraulic jump
        call face_copy_upstream_to_downstream_interior &
            (fGeoSetD, fGeoSetU, facePackCol, Npack)

            ! call util_utest_CLprint ('     face_interpolation_interior at CCCC')

        call face_copy_upstream_to_downstream_interior &
            (fHeadSetD, fHeadSetU, facePackCol, Npack)

            ! call util_utest_CLprint ('     face_interpolation_interior at DDDD')
        
        !% NOTE the following have their own Npack computations

        !% calculate the velocity in faces and put limiter
        call face_velocities (facePackCol, .true.)

        !% reset all the hydraulic jump interior faces
        call jump_compute

        !% --- compute volume-based limits on flowrate
        call face_flowrate_limits_interior (facePackCol)

        !%------------------------------------------------------------------
        !% Closing
        if (setting%Debug%File%face) &
            write(*,"(A,i5,A)") '*** leave ' // trim(subroutine_name) // " [Processor ", this_image(), "]"
    end subroutine face_interpolation_interior
!%
!%==========================================================================
!%==========================================================================
!%
    subroutine face_interpolation_shared (facePackCol)
        !%------------------------------------------------------------------
        !% Description:
        !% Interpolates all the shared faces
        !% NOTE -- we do NOT put Npack conditionals on the subroutines that
        !% are called herein so that we can effectively use sync all across
        !% images
        !%-------------------------------------------------------------------
        !% Declarations
            integer, intent(in) :: facePackCol  !% Column in faceP array for needed pack
            integer, pointer    :: Npack        !% expected number of packed rows in faceP.
            integer :: fGeoSetU(2), fGeoSetD(2), eGhostGeoSet(2)
            integer :: fHeadSetU(1), fHeadSetD(1), eGhostHeadSet(1)
            integer :: fFlowSet(1), eGhostFlowSet(1)
            integer :: fPreissmenSet(1), eGhostPreissmenSet(1)
            integer(kind=8) :: crate, cmax, cval
            character(64) :: subroutine_name = 'face_interpolation_shared'
        !%-------------------------------------------------------------------
        !% Aliases
            Npack => npack_facePS(facePackCol)
        !%-------------------------------------------------------------------
        !% Preliminaries   
            if (setting%Debug%File%face) &
                write(*,"(A,i5,A)") '*** enter ' // trim(subroutine_name) // " [Processor ", this_image(), "]"

            !% start the shared timer    
            sync all    
            if (this_image()==1) then
                call system_clock(count=cval,count_rate=crate,count_max=cmax)
                setting%Time%WallClock%SharedStart = cval
                setting%Time%WallClock%SharedStart_C = cval
            end if
        !%-------------------------------------------------------------------
        !% Face values are needed for
        !% Area_u, Area_d, Head_u, Head_d, Flowrate,

        !% HACK not sure if we need
        !% Topwidth_u, Topwidth_d, HydDepth_u, HydDepth_d
        !% Velocity_u, Velocity_d

        !% General approach
        !% interpolate to ..._u
        !% identify hydraulic jumps
        !% set .._u and ..d based on jumps

        !% set the matching sets
        !% HACK THESE SHOULD BE DONE IN A GLOBAL -- MAYBE SETTINGS
        !% Note these can be expanded for other terms to be interpolated.
        ! fGeoSetU     = [fr_Area_u, fr_Topwidth_u, fr_HydDepth_u]
        ! fGeoSetD     = [fr_Area_d, fr_Topwidth_d, fr_HydDepth_d]
        ! eGhostGeoSet = [ebgr_Area,   ebgr_Topwidth,   ebgr_HydDepth]

        fGeoSetU     = [fr_Area_u, fr_Depth_u]
        fGeoSetD     = [fr_Area_d, fr_Depth_d]
        eGhostGeoSet = [ebgr_Area, ebgr_Depth]

        fHeadSetU     = [fr_Head_u]
        fHeadSetD     = [fr_Head_d]
        eGhostHeadSet = [ebgr_Head]

        fFlowSet      = [fr_Flowrate]
        eGhostFlowSet = [ebgr_Flowrate]

        fPreissmenSet      = [fr_Preissmann_Number]
        eGhostPreissmenSet = [ebgr_Preissmann_Number]

        !% transfer all the local elemR data needed for face interpolation into elemB data structure
        call local_data_transfer_to_boundary_array (facePackCol, Npack)

        !% use elemB to transfer remote data to local elemG array for interpolation
        call inter_image_data_transfer (facePackCol, Npack)

        call face_interp_shared_set &
            (fGeoSetU, eGhostGeoSet, ebgr_InterpWeight_dG, ebgr_InterpWeight_uG, facePackCol, Npack)

        call face_interp_shared_set &
            (fHeadSetU, eGhostHeadSet, ebgr_InterpWeight_dH, ebgr_InterpWeight_uH, facePackCol, Npack)

        call face_interp_shared_set &
            (fFlowSet, eGhostFlowSet, ebgr_InterpWeight_dQ, ebgr_InterpWeight_uQ, facePackCol, Npack)

        call face_interp_shared_set &
            (fPreissmenSet, eGhostPreissmenSet, ebgr_InterpWeight_dQ, ebgr_InterpWeight_uQ, facePackCol, Npack)

        !% copy upstream to downstream storage at a face
        !% (only for Head and Geometry types)
        !% note that these might be reset by hydraulic jump
        call face_copy_upstream_to_downstream_shared &
            (fGeoSetD, fGeoSetU, facePackCol, Npack)

        call face_copy_upstream_to_downstream_shared &
            (fHeadSetD, fHeadSetU, facePackCol, Npack)

        call face_velocities (facePackCol, .false.)

        !% --- compute volume-based limits on flowrate
        call face_flowrate_limits_shared (facePackCol)

        !% 20220425brh
        ! if (this_image() == 3) then
        !     print *, this_image(), ' P elem   ',elemR(426,er_Preissmann_Number)
        !     print *, this_image(), ' Pface Up ',faceR(elemI(426,ei_Mface_uL),fr_Preissmann_Number)
        !     print *, this_image(), ' Pface Dn ',faceR(elemI(426,ei_Mface_dL),fr_Preissmann_Number)
        ! end if

        !% 20220425brh
        ! if (this_image() == 1) print *, 'this image = ',this_image()
        ! if (this_image() == 2) print *, 'this image = ',this_image()
        ! if (this_image() == 4) print *, 'this image = ',this_image()
        ! if (this_image() == 4) then
        !      print *, this_image(), ' P elem   ',elemR(458,er_Preissmann_Number)
        !      print *, this_image(), ' Pface Up ',faceR(elemI(458,ei_Mface_uL),fr_Preissmann_Number)
        !      !print *, this_image(), ' Pface Dn ' !%,faceR(elemI(458,ei_Mface_dL),fr_Preissmann_Number)
        ! end if
            
        !% HACK needs jump computation for across shared faces
        ! print *, "HACK missing hydraulic jump that occurs on shared faces 36987"

        !%-------------------------------------------------------------------
        !% closing   
            !% stop the shared timer
            sync all
            if (this_image()==1) then
                call system_clock(count=cval,count_rate=crate,count_max=cmax)
                setting%Time%WallClock%SharedStop = cval
                setting%Time%WallClock%SharedCumulative &
                        = setting%Time%WallClock%SharedCumulative &
                        + setting%Time%WallClock%SharedStop &
                        - setting%Time%WallClock%SharedStart

                setting%Time%WallClock%SharedStop_C = cval
                setting%Time%WallClock%SharedCumulative_C &
                        = setting%Time%WallClock%SharedCumulative_C &
                        + setting%Time%WallClock%SharedStop_C &
                        - setting%Time%WallClock%SharedStart_C            
            end if 

            if (setting%Debug%File%face) &
                write(*,"(A,i5,A)") '*** leave ' // trim(subroutine_name) // " [Processor ", this_image(), "]"
    end subroutine face_interpolation_shared
!%
!%==========================================================================
!%==========================================================================
!%
    subroutine face_interp_interior_set &
        (fset, eset, eWdn, eWup, facePackCol, Npack)
        !%------------------------------------------------------------------
        !% Description:
        !% Interpolates to a face for a set of variables 
        !% NOTE cannot sync all in this subroutine
        !%-------------------------------------------------------------------
        !% Declarations:
            integer, intent(in) :: fset(:), eset(:), eWdn, eWup, facePackCol, Npack
            integer, pointer :: thisP(:), eup(:), edn(:)
            integer :: ii, jj
            character(64) :: subroutine_name = 'face_interp_interior_set'
        !%-------------------------------------------------------------------
        !% Preliminaries
            if (setting%Debug%File%face) &
                write(*,"(A,i5,A)") '*** enter ' // trim(subroutine_name) // " [Processor ", this_image(), "]"
        !%-------------------------------------------------------------------
        !% Aliases        
            thisP => faceP(1:Npack,facePackCol)
            eup   => faceI(:,fi_Melem_uL)
            edn   => faceI(:,fi_Melem_dL)
        !%--------------------------------------------------------------------
        !% cycle interpolation through each type in the set.

        ! print *, 'G ',elemR(49,er_InterpWeight_uG),elemR(49,er_InterpWeight_dG)

        do ii=1,size(fset)
            ! if (ii == 2) then 
            !     do jj=1,Npack
            !         if (thisP(jj) == 42) then
            !             print *, ' '
            !             print *, 'in face interpolation set'
            !             print *, thisP(jj), eWup, eWdn
            !             print *, 'eup, edn ',eup(thisP(jj)),edn(thisP(jj))
            !             print *, 'elemUp, elemD',elemR(eup(thisP(jj)),eset(ii)),elemR(edn(thisP(jj)),eset(ii))
            !             print *, 'weightup,dn  ',elemR(edn(thisP(jj)),eWup),    elemR(eup(thisP(jj)),eWdn)
            !             print *, 'G ',elemR(49,er_InterpWeight_uG),elemR(49,er_InterpWeight_dG)
            !             print *, ' '
            !         end if
            !     end do
            ! end if
      

            faceR(thisP,fset(ii)) = &
                (+elemR(eup(thisP),eset(ii)) * elemR(edn(thisP),eWup) &
                 +elemR(edn(thisP),eset(ii)) * elemR(eup(thisP),eWdn) &
                ) / &
                ( elemR(edn(thisP),eWup) + elemR(eup(thisP),eWdn))
        end do

        !% NOTES
        !% elemR(eup(thisP),eset(ii)) is the element value upstream of the face
        !% elemR(edn(thisP),eset(ii) is the element value downstream of the face.
        !% elemR(eup(thisp),eWdn) is the downstream weighting of the upstream element----------------------------------------------------------

        !%------------------------------------------------------------------
        !% Closing
            if (setting%Debug%File%face) &
                write(*,"(A,i5,A)") '*** enter ' // trim(subroutine_name) // " [Processor ", this_image(), "]"
    end subroutine face_interp_interior_set
!%
!%==========================================================================
!%==========================================================================
!%
    ! subroutine face_interp_shared_set_old &
    !     (fset, eset, eWdn, eWup, facePackCol, Npack)
    !     !%-------------------------------------------------------------------
    !     !% Description:
    !     !% Interpolates faces shared between processor
    !     !%-------------------------------------------------------------------
    !     !% Declarations
    !         integer, intent(in) :: fset(:), eset(:), eWdn, eWup, facePackCol, Npack
    !         integer, pointer :: thisP, eup, edn, connected_image, ghostUp, ghostDn
    !         logical, pointer :: isGhostUp, isGhostDn
    !         integer :: ii, jj   
    !         integer(kind=8) :: crate, cmax, cval
    !         character(64) :: subroutine_name = 'face_interp_shared_set_old'
    !     !%--------------------------------------------------------------------
    !     !%  Preliminaries
    !         if (setting%Debug%File%face) &
    !             write(*,"(A,i5,A)") '*** enter ' // trim(subroutine_name) // " [Processor ", this_image(), "]"

    !         sync all
    !         if (this_image()==1) then
    !             call system_clock(count=cval,count_rate=crate,count_max=cmax)
    !             setting%Time%WallClock%SharedStart_A = cval
    !         end if    
    !     !%--------------------------------------------------------------------
    !     !% cycle through all the shared faces
    !     do ii = 1,Npack
    !         !%-----------------------------------------------------------------
    !         !% Aliases
    !         thisP           => facePS(ii,facePackCol)
    !         connected_image => faceI(thisP,fi_Connected_image)
    !         eup             => faceI(thisP,fi_Melem_uL)
    !         edn             => faceI(thisP,fi_Melem_dL)
    !         ghostUp         => faceI(thisP,fi_GhostElem_uL)
    !         ghostDn         => faceI(thisP,fi_GhostElem_dL)
    !         isGhostUp       => faceYN(thisP,fYN_isUpGhost)
    !         isGhostDn       => faceYN(thisP,fYN_isDnGhost)
    !         !%-----------------------------------------------------------------
    !         !% cycle through each element in the set.
    !         !% This is designed for fset and eset being vectors, but it
    !         !%   is not clear that this is needed.
    !         do jj=1,size(fset)

    !             !% condition for upstream element of the shared face is ghost and in a different image
    !             if (isGhostUp) then

    !                 faceR(thisP,fset(jj)) = &
    !                     (+elemR(ghostUp,eset(jj))[connected_image] * elemR(edn,eWup) &
    !                      +elemR(edn,eset(jj)) * elemR(ghostUp,eWdn)[connected_image] &
    !                     ) / &
    !                     ( elemR(edn,eWup) + elemR(ghostUp,eWdn)[connected_image] )

    !             !% condition for downstream element of the shared face is ghost and in a different image
    !             elseif (isGhostDn) then

    !                 faceR(thisP,fset(jj)) = &
    !                     (+elemR(eup,eset(jj)) * elemR(ghostDn,eWup)[connected_image] &
    !                      +elemR(ghostDn,eset(jj))[connected_image] * elemR(eup,eWdn) &
    !                     ) / &
    !                     ( elemR(ghostDn,eWup)[connected_image] + elemR(eup,eWdn) )

    !             else
    !                 write(*,*) 'CODE ERROR: unexpected else'
    !                 !stop 
    !                 call util_crashpoint( 487874)
    !                 !return
    !             end if        
    !         end do
    !     end do

    !     !% NOTES
    !     !% elemR(eup,eset(jj)) is the element value upstream of the face
    !     !% elemR(edn,eset(jj) is the element value downstream of the face.
    !     !% elemR(eup,eWdn) is the downstream weighting of the upstream element
    !     !% elemR(edn,eWup)) is the upstream weighting of the downstream element

    !     !% elemR(ghostUp,eset(jj))[connected_image] is the elem value from the upstream image of the face
    !     !% elemR(ghostDn,eset(jj))[connected_image] is the elem value from the downstream image of the face
    !     !% elemR(ghostUp,eWdn)[connected_image] is the downstream weighting of the upstream image element
    !     !% elemR(ghostDn,eWup))[connected_image] is the upstream weighting of the downstream image element

    !     !%--------------------------------------------------------------------
    !     !% Closing
    !     sync all
    !     if (this_image()==1) then
    !         !% stop the shared timer
    !         call system_clock(count=cval,count_rate=crate,count_max=cmax)
    !         setting%Time%WallClock%SharedStop_A = cval
    !         setting%Time%WallClock%SharedCumulative_A &
    !                 = setting%Time%WallClock%SharedCumulative_A &
    !                 + setting%Time%WallClock%SharedStop_A &
    !                 - setting%Time%WallClock%SharedStart_A                    
    !     end if 
    !         if (setting%Debug%File%face) &
    !             write(*,"(A,i5,A)") '*** enter ' // trim(subroutine_name) // " [Processor ", this_image(), "]"
    ! end subroutine face_interp_shared_set_old
!%
!%==========================================================================
!%==========================================================================
!%  
    ! subroutine face_head_average_on_element &
    !     (whichTM)
    !     !%------------------------------------------------------------------
    !     !% Description:
    !     !% computes the average head of the faces on an element
    !     !%-------------------------------------------------------------------
    !     !% Declarations:
    !         integer, intent(in) :: whichTM 
    !         integer, pointer :: Npack, thisP(:), thisCol
    !         integer, pointer :: mapUp(:), mapDn(:)
    !         real(8), pointer :: fHeadU(:), fHeadD(:), eHeadAvg(:)
    !         character(64) :: subroutine_name = 'face_head_average_on_element'
    !     !%-------------------------------------------------------------------
    !     !% Preliminaries
    !         !if (.not. setting%Solver%QinterpWithLocalHeadGradient) return  
    !         if (setting%Debug%File%face) &
    !             write(*,"(A,i5,A)") '*** enter ' // trim(subroutine_name) // " [Processor ", this_image(), "]"

    !         select case (whichTM)
    !             case (ALLtm)
    !                 thisCol => col_elemP(ep_CC_ALLtm)
    !             case (ETM)
    !                 thisCol => col_elemP(ep_CC_ETM)
    !             case (AC)
    !                 thisCol => col_elemP(ep_CC_AC)
    !             case (dummy)
    !                 ! print *, 'error - the FluxCorrection has not been coded for diagnostic elements'
    !                 ! stop 58704
    !                 return
    !             case default
    !                 print *, 'error, this default case should not be reached'
    !                 stop 2394
    !         end select         
    !     !%-------------------------------------------------------------------
    !     !% Aliases             
    !         Npack    => npack_elemP(thisCol)
    !         if (Npack .le. 0) return
    !         thisP    => elemP(1:Npack,thisCol)
    !         mapUp    => elemI(:,ei_Mface_uL)
    !         mapDn    => elemI(:,ei_Mface_dL)   
    !         fHeadU   => faceR(:,fr_Head_u)  
    !         fHeadD   => faceR(:,fr_Head_d)
    !         eHeadAvg => elemR(:,er_HeadAvg)    
    !     !%-------------------------------------------------------------------   
    !     !% The map up must use the downstream head on the face.
    !     !% The map dn must use the upstream head on the face.
    !     eHeadAvg(thisP) = onehalfR * (fHeadU(mapDn(thisP)) + fHeadD(mapUp(thisP)))

    !     ! print *, 'in ',trim(subroutine_name)
    !     ! print *, thisP
    !     ! print *, eHeadAvg(thisP)
    !     ! print *, ' '
    !     ! print *, eHeadAvg(:)
    !     ! print *, ' '
    !     ! print *, fHeadU(:)
    !     ! print *, ' '
    !     ! print *, fHeadD(:)
    !     ! print *, ' '
    !     !%-------------------------------------------------------------------
    !     !% Closing
    !         if (setting%Debug%File%face) &
    !             write(*,"(A,i5,A)") '*** leave ' // trim(subroutine_name) // " [Processor ", this_image(), "]"
    ! end subroutine face_head_average_on_element
!%
!%==========================================================================
!%==========================================================================
!%
    ! subroutine face_FluxCorrection_interior &
        !     (faceCol, whichTM)
        !     !%------------------------------------------------------------------
        !     !% Description:
        !     !% Adds the head gradient term to the face flowrate for interior faces
        !     !% should be done after Q and H are interpolated to face
        !     !% and element HeadAvg is computed.
        !     !%-------------------------------------------------------------------
        !     !% Declarations
        !         integer, intent(in) :: faceCol, whichTM
        !         integer, pointer :: Npack, thisF(:), eup(:), edn(:), elist(:)
        !         real(8), pointer :: fQ(:), eArea(:), eHead(:), eHeadAvg(:)
        !         real(8), pointer :: eLength(:) !, qLateral(:), qChannel(:)
        !         real(8), pointer ::  dt, grav !, qfac, qratio 
        !         logical          :: isBConly
        !         character(64) :: subroutine_name = 'face_FluxCorrection_interior'
        !     !%-------------------------------------------------------------------
        !     !% Preliminaries
        !         !if (.not. setting%Solver%QinterpWithLocalHeadGradient) return  
        !         if (setting%Debug%File%face) &
        !             write(*,"(A,i5,A)") '*** enter ' // trim(subroutine_name) // " [Processor ", this_image(), "]"
        !     !%-------------------------------------------------------------------
        !     !% Aliases   
        !         eup      => faceI(:,fi_Melem_uL)
        !         edn      => faceI(:,fi_Melem_dL)
        !         fQ       => faceR(:,fr_Flowrate)
        !         eArea    => elemR(:,er_Area)
        !         eHead    => elemR(:,er_Head)
        !         !eHeadAvg => elemR(:,er_HeadAvg)
        !         eLength  => elemR(:,er_Length)
        !         eList    => elemI(:,ei_Temp01)
        !         dt       => setting%Time%Hydraulics%Dt
        !         grav     => setting%constant%gravity

        !         Npack => npack_faceP(faceCol)
        !         if (Npack .le. 0) return
        !         thisF    => faceP(1:Npack,faceCol)
        !     !%-------------------------------------------------------------------
        !     !% --- compute the average head for the elements 
        !     !call face_head_average_on_element (whichTM)

        !     !% -- we need a custom selector array because we don't have a packed array
        !     !%    that handles the combined face/element condition needed
        !     eList = zeroI
        !     select case (whichTM)
        !     case (ALLtm)
        !         eList(ep_CC_ALLtm) = oneI
        !     case (ETM)
        !         eList(ep_CC_ETM) = oneI
        !     case (AC)
        !         eList(ep_CC_AC) = oneI
        !     case (dummy)
        !         ! print *, 'error - the FluxCorrection has not been coded for diagnostic elements'
        !         return
        !     case default
        !         print *, 'error, this default case should not be reached'
        !         stop 239483
        !     end select

        !     !% --- adds term dt * grav A [ (dh/dx) - (dh_avg/dx) ] where not zerovolume
        !     where (      (.not. elemYN(eup(thisF),eYN_isZeroDepth   )        ) & 
        !            .and. (.not. elemYN(eup(thisF),eYN_isSmallDepth  )        ) &
        !            .and. (       elemR(eup(thisF),er_FlowrateLateral) > zeroR) &
        !            .and. (       eList(eup(thisF))                    == oneI) )
        !         fQ(thisF) = fQ(thisF) + dt * grav *                                         &
        !             (                                                                       &
        !                 +( eArea(eup(thisF)) * ( eHead(eup(thisF)) - eHeadAvg(eup(thisF)) ) &
        !                     / ( onehalfR * eLength(eup(thisF) ) ) )                         &
        !             )                        
        !     end where

        !     where (       (.not. elemYN(edn(thisF),eYN_isZeroDepth   )        ) & 
        !             .and. (.not. elemYN(edn(thisF),eYN_isSmallDepth  )        ) &
        !             .and. (       elemR(edn(thisF),er_FlowrateLateral) > zeroR) &
        !             .and. (       eList(edn(thisF))                    == oneI) )
        !         fQ(thisF) = fQ(thisF) + dt * grav *                                         &
        !             (                                                                       &
        !                 -( eArea(edn(thisF)) * ( eHead(edn(thisF)) - eHeadAvg(edn(thisF)) ) &
        !                     / ( onehalfR * eLength(edn(thisF) ) ) )                         &
        !             ) 
        !     end where

        !     !% --- need another call to face_interpolate so that the Q_HeadGradient
        !         !%     does not change the upper boundary inflow condition
        !     isBConly = .true.
        !     call face_interpolate_bc (isBConly)

        !     !% for lateral inflows upstream of a face with downstream flow 
        !     !% note: null set for negative inflow   
        !     ! where ( qLateral(eup(thisF)) > qratio * abs(qChannel(eup(thisF))) )
        !     !     fQ(thisF) = fQ(thisF) + qfac * dt * grav                                       &
        !     !         * ( util_sign_with_ones(fQ(thisF)) + oneR ) * onehalfR                     &
        !     !         *(                                                                         &
        !     !             +( eArea(eup(thisF)) * ( eHead(eup(thisF)) - eHeadAvg(eup(thisF)) ) )  &
        !     !             / ( onehalfR * eLength(eup(thisF)) )                                   &
        !     !         )
        !     ! end where

        !     ! !% for lateral inflows downstream of a face with an upstream flow
        !     ! !% note: null set for negative inflow
        !     ! where ( qLateral(edn(thisF)) > qratio * abs(qChannel(edn(thisF))) )
        !     !     fQ(thisF) = fQ(thisF) + qfac * dt * grav                                       &
        !     !         * ( util_sign_with_ones(fQ(thisF)) - oneR ) * onehalfR                     &
        !     !         *(                                                                         &   
        !     !           +( eArea(edn(thisF)) * ( eHead(edn(thisF)) - eHeadAvg(edn(thisF)) ) )    &
        !     !             / ( onehalfR * eLength(edn(thisF)) )                                   &
        !     !         )
        !     ! end where

        !     !% --- for downstream flow
        !     ! where (.not. elemYN(eup(thisP),eYN_isZeroDepth))
        !     !     fQ(thisP) = fQ(thisP) + qfac * dt * grav                                    &
        !     !        *( util_sign_with_ones(fQ(thisP)) + oneR ) * onehalfR                    &
        !     !        *(                                                                       &
        !     !             +( eArea(eup(thisP)) * ( eHead(eup(thisP)) - eHeadAvg(eup(thisP)) ) &
        !     !                 / ( onehalfR * eLength(eup(thisP) ) ) )                         &
        !     !         ) 
        !     ! end where

        !     ! !% --- for upstream flow
        !     ! where (.not. elemYN(edn(thisP),eYN_isZeroDepth))
        !     !     fQ(thisP) = fQ(thisP) + qfac * dt * grav                                    &
        !     !        *( util_sign_with_ones(fQ(thisP)) - oneR ) * onehalfR                    &
        !     !        *(                                                                       &
        !     !             -( eArea(edn(thisP)) * ( eHead(edn(thisP)) - eHeadAvg(edn(thisP)) ) &
        !     !                 / ( onehalfR * eLength(edn(thisP) ) ) )                         &
        !     !         ) 
        !     ! end where
        
        !     !%-------------------------------------------------------------------
        !     !% Closing
        !         if (setting%Debug%File%face) &
        !             write(*,"(A,i5,A)") '*** enter ' // trim(subroutine_name) // " [Processor ", this_image(), "]"
        ! end subroutine face_FluxCorrection_interior
!%
!%==========================================================================
!%==========================================================================
!%
    subroutine local_data_transfer_to_boundary_array &
        (facePackCol, Npack)
        !%-------------------------------------------------------------------
        !% Description:
        !% transfers local data from elemR to elemB%R
        !%-------------------------------------------------------------------
        !% Declarations
            integer             :: ii, eColumns(Ncol_elemBGR) 
            integer, intent(in) :: facePackCol, Npack
            integer, pointer    :: thisP, eUp, eDn, JMidx
            logical, pointer    :: isGhostUp, isGhostDn
            character(64)       :: subroutine_name = 'local_data_transfer_to_boundary_array'
        !%--------------------------------------------------------------------
        !%  Preliminaries
            if (setting%Debug%File%face) &
                write(*,"(A,i5,A)") '*** enter ' // trim(subroutine_name) // " [Processor ", this_image(), "]"  

            !% HACK: this eset has to be exactly mimic the indexes for ebgr_... 
            eColumns = [er_Area, er_Topwidth, er_Depth, er_Head, er_Flowrate, er_Preissmann_Number, er_Volume, &
                        er_InterpWeight_dG, er_InterpWeight_uG, er_InterpWeight_dH,   er_InterpWeight_uH, &
                        er_InterpWeight_dQ, er_InterpWeight_uQ, er_InterpWeight_dP, er_InterpWeight_uP] 

        !%--------------------------------------------------------------------
        !% cycle through all the shared faces
        sync all
        do ii = 1,Npack
            
            !%-----------------------------------------------------------------
            !% Aliases
            thisP      => facePS(ii,facePackCol)
            isGhostUp  => faceYN(thisP,fYN_isUpGhost)
            isGhostDn  => faceYN(thisP,fYN_isDnGhost)
            eUp        => faceI(thisP,fi_Melem_uL)
            eDn        => faceI(thisP,fi_Melem_dL)
            !%-----------------------------------------------------------------

            !print *, 'xxAA ',this_image(), ii, thisP, isGhostUp, isGhostDn, eUp, eDn
            !% condition for upstream element is ghost
            if (isGhostUp) then
                elemB%R(ii,:) = elemR(eDn,eColumns)
            !% condition for downstream element is ghost
            elseif (isGhostDn) then
                elemB%R(ii,:) = elemR(eUp,eColumns)
            else
                write(*,*) 'CODE ERROR: unexpected else'
                !stop 
                call util_crashpoint( 487874)
                !return
            end if     
            !% --- handle special case for volume used by Pump Type 1 when
            !%     the upstream element is a JB
            if ((isGhostUp) .and. (elemI(eUp,ei_elementType) == JB)) then
                !JMidx => elemI(eup,ei_main_idx_for_branch)
                JMidx => elemSI(eup,esi_JunctionBranch_Main_Index)
                elemB%R(ii,ebgr_Volume) = elemR(JMidx,er_Volume)
            end if
        end do

        if (setting%Debug%File%face) &
            write(*,"(A,i5,A)") '*** enter ' // trim(subroutine_name) // " [Processor ", this_image(), "]"
    end subroutine local_data_transfer_to_boundary_array
!%
!%==========================================================================
!%==========================================================================
!%
    subroutine inter_image_data_transfer &
        (facePackCol, Npack)
        !%-------------------------------------------------------------------
        !% Description:
        !% transfers data from connected images
        !%-------------------------------------------------------------------
        !% Declarations
            integer             :: ii  
            integer, intent(in) :: facePackCol, Npack
            integer, pointer    :: thisP, ci, BUpIdx, BDnIdx, eUp, eDn
            logical, pointer    :: isGhostUp, isGhostDn
            integer(kind=8)     :: crate, cmax, cval
            character(64)       :: subroutine_name = 'inter_image_data_transfer'
        !%--------------------------------------------------------------------
        !%  Preliminaries
            if (setting%Debug%File%face) &
                write(*,"(A,i5,A)") '*** enter ' // trim(subroutine_name) // " [Processor ", this_image(), "]"

            sync all
            if (this_image()==1) then
                call system_clock(count=cval,count_rate=crate,count_max=cmax)
                setting%Time%WallClock%SharedStart_A = cval
            end if 
          
        !%--------------------------------------------------------------------
        !% cycle through all the shared faces
        do ii = 1,Npack
            !%-----------------------------------------------------------------
            !% Aliases
            thisP      => facePS(ii,facePackCol)
            ci         => faceI(thisP,fi_Connected_image)
            BUpIdx     => faceI(thisP,fi_BoundaryElem_uL)
            BDnIdx     => faceI(thisP,fi_BoundaryElem_dL)
            isGhostUp  => faceYN(thisP,fYN_isUpGhost)
            isGhostDn  => faceYN(thisP,fYN_isDnGhost)
            !%-----------------------------------------------------------------
            !% condition for upstream element of the shared face is ghost and in a different image
            if (isGhostUp) then
                elemGR(ii,:) = elemB[ci]%R(BUpIdx,:) 
                ! print*, elemGR(ii,:), 'elemGR(ii,:)'
                ! print*
                ! print*, elemB[ci]%R(BUpIdx,:) , 'elemB[ci]%R(BUpIdx,:) '
                ! print*
                ! print*, reverseKey(elemI(faceI(thisP,fi_GhostElem_uL), ei_elementType)[ci])
                ! print*, elemI(faceI(thisP,fi_GhostElem_uL), :)[ci], 'elem row'
            !% condition for downstream element of the shared face is ghost and in a different image
            elseif (isGhostDn) then
                elemGR(ii,:) = elemB[ci]%R(BDnIdx,:)
                ! print*, elemGR(ii,:), 'elemGR(ii,:)'
                ! print*
                ! print*, elemB[ci]%R(BUpIdx,:) , 'elemB[ci]%R(BUpIdx,:) '
                ! print*
                ! print*, reverseKey(elemI(faceI(thisP,fi_GhostElem_dL), ei_elementType)[ci])
                ! print*, elemR(faceI(thisP,fi_GhostElem_dL), :)[ci], 'elem row'
            else
                write(*,*) 'CODE ERROR: unexpected else'
                !stop 
                call util_crashpoint( 487874)
                !return
            end if        
        end do
        
        !%--------------------------------------------------------------------
        !% Closing
        sync all
        
        if (this_image()==1) then
            !% stop the shared timer
            call system_clock(count=cval,count_rate=crate,count_max=cmax)
            setting%Time%WallClock%SharedStop_A = cval
            setting%Time%WallClock%SharedCumulative_A &
                    = setting%Time%WallClock%SharedCumulative_A &
                    + setting%Time%WallClock%SharedStop_A &
                    - setting%Time%WallClock%SharedStart_A                    
        end if 
            if (setting%Debug%File%face) &
                write(*,"(A,i5,A)") '*** enter ' // trim(subroutine_name) // " [Processor ", this_image(), "]"
    end subroutine inter_image_data_transfer
!%
!%==========================================================================
!%==========================================================================
!%
    subroutine face_interp_shared_set &
        (fset, eset, eWdn, eWup, facePackCol, Npack)
        !%-------------------------------------------------------------------
        !% Description:
        !% Interpolates faces shared between processor
        !% NOTE cannot sync all in this subroutine
        !%-------------------------------------------------------------------
        !% Declarations
            integer             :: ii, jj
            integer, intent(in) :: fset(:), eset(:), eWdn, eWup
            integer, intent(in) :: facePackCol, Npack
            integer, pointer    :: thisP, eup, edn, BUpIdx, BDnIdx
            logical, pointer    :: isGhostUp, isGhostDn
            integer(kind=8)     :: crate, cmax, cval
            character(64)       :: subroutine_name = 'face_interp_shared_set'
        !%--------------------------------------------------------------------
        !%  Preliminaries
            if (setting%Debug%File%face) &
                write(*,"(A,i5,A)") '*** enter ' // trim(subroutine_name) // " [Processor ", this_image(), "]"

            if (this_image()==1) then
                call system_clock(count=cval,count_rate=crate,count_max=cmax)
                setting%Time%WallClock%SharedStart_A = cval
            end if    
        !%--------------------------------------------------------------------
        !% cycle through all the shared faces
        do ii = 1,Npack
            !%-----------------------------------------------------------------
            !% Aliases
            thisP           => facePS(ii,facePackCol)
            eup             => faceI(thisP,fi_Melem_uL)
            edn             => faceI(thisP,fi_Melem_dL)
            BUpIdx          => faceI(thisP,fi_BoundaryElem_uL)
            BDnIdx          => faceI(thisP,fi_BoundaryElem_dL)
            isGhostUp       => faceYN(thisP,fYN_isUpGhost)
            isGhostDn       => faceYN(thisP,fYN_isDnGhost)
            !%-----------------------------------------------------------------
            !% cycle through each element in the set.
            !% This is designed for fset and eset being vectors, but it
            !%   is not clear that this is needed.
            do jj=1,size(fset)

                !% condition for upstream element of the shared face is ghost and in a different image
                if (isGhostUp) then
                    faceR(thisP,fset(jj)) = &
                        (+elemGR(ii,eset(jj))  * elemB%R(ii,eWup)  &
                         +elemB%R(ii,eset(jj)) * elemGR(ii,eWdn) &
                        ) / &
                        ( elemB%R(ii,eWup) + elemGR(ii,eWdn) )

                !% condition for downstream element of the shared face is ghost and in a different image
                elseif (isGhostDn) then

                    faceR(thisP,fset(jj)) = &
                        (+elemB%R(ii,eset(jj)) * elemGR(ii,eWup) &
                         +elemGR(ii,eset(jj))  * elemB%R(ii,eWdn)  &
                        ) / &
                        ( elemGR(ii,eWup) + elemB%R(ii,eWdn) )
                else
                    write(*,*) 'CODE ERROR: unexpected else'
                    !stop 
                    call util_crashpoint( 487874)
                    !return
                end if      
            end do
        end do

        !% NOTES
        !% elemB%R(ii,eset(jj)) is the element value of the boundary element
        !% elemGR(ii,eset(jj)) is the element value of the ghost element
        !% elemB%R(ii,eWdn) is the downstream weighting of the boundary element
        !% elemGR(ii,eWup)) is the upstream weighting of the ghost element
        !%--------------------------------------------------------------------
        !% Closing
        sync all
        if (this_image()==1) then
            !% stop the shared timer
            call system_clock(count=cval,count_rate=crate,count_max=cmax)
            setting%Time%WallClock%SharedStop_A = cval
            setting%Time%WallClock%SharedCumulative_A &
                    = setting%Time%WallClock%SharedCumulative_A &
                    + setting%Time%WallClock%SharedStop_A &
                    - setting%Time%WallClock%SharedStart_A                    
        end if 
            if (setting%Debug%File%face) &
                write(*,"(A,i5,A)") '*** enter ' // trim(subroutine_name) // " [Processor ", this_image(), "]"
    end subroutine face_interp_shared_set
!%
!%==========================================================================
!%==========================================================================
!%
    subroutine face_copy_upstream_to_downstream_interior &
        (downstreamSet, upstreamSet, facePackCol, Npack)
        !%-----------------------------------------------------------------------------
        !% Description:
        !% Copies the interpolated value on the upstream side to the downstream side
        !% These values are later adjusted for hydraulic jumps
        !%-----------------------------------------------------------------------------
        integer, intent(in) :: facePackCol, Npack, downstreamSet(:), upstreamSet(:)
        integer, pointer :: thisP(:)
        !%-----------------------------------------------------------------------------
        character(64) :: subroutine_name = 'face_copy_upstream_to_downstream_interior'
        !%-----------------------------------------------------------------------------
        if (setting%Debug%File%face) &
            write(*,"(A,i5,A)") '*** enter ' // trim(subroutine_name) // " [Processor ", this_image(), "]"
        !%-----------------------------------------------------------------------------

        if (Npack > 0) then
            thisP => faceP(1:Npack,facePackCol)
            faceR(thisP,downstreamSet) = faceR(thisP,upstreamSet)
        end if

        if (setting%Debug%File%face) &
            write(*,"(A,i5,A)") '*** leave ' // trim(subroutine_name) // " [Processor ", this_image(), "]"
    end subroutine face_copy_upstream_to_downstream_interior
!%
!%==========================================================================
!%==========================================================================
!%
    subroutine face_copy_upstream_to_downstream_shared &
        (downstreamSet, upstreamSet, facePackCol, Npack)
        !%------------------------------------------------------------------
        !% Description:
        !% Copies the interpolated value on the upstream side to the downstream side
        !% These values are later adjusted for hydraulic jumps
        !%------------------------------------------------------------------
        !% Declarations
            integer, intent(in) :: facePackCol, Npack, downstreamSet(:), upstreamSet(:)
            integer, pointer :: thisP(:)
            integer(kind=8) :: crate, cmax, cval
            character(64) :: subroutine_name = 'face_copy_upstream_to_downstream'
        !%-------------------------------------------------------------------
        !% Preliminaries
            sync all
            if (this_image()==1) then
                call system_clock(count=cval,count_rate=crate,count_max=cmax)
                setting%Time%WallClock%SharedStart_B = cval
            end if 
            if (setting%Debug%File%face) &
                write(*,"(A,i5,A)") '*** enter ' // trim(subroutine_name) // " [Processor ", this_image(), "]"
        !%-----------------------------------------------------------------------------

        if (Npack > 0) then
            thisP => facePS(1:Npack,facePackCol)
            faceR(thisP,downstreamSet) = faceR(thisP,upstreamSet)
        end if

        !%-------------------------------------------------------------------
        !% Closing
            sync all
            if (this_image()==1) then
                !% stop the shared timer
                call system_clock(count=cval,count_rate=crate,count_max=cmax)
                setting%Time%WallClock%SharedStop_B = cval
                setting%Time%WallClock%SharedCumulative_B &
                        = setting%Time%WallClock%SharedCumulative_B &
                        + setting%Time%WallClock%SharedStop_B &
                        - setting%Time%WallClock%SharedStart_B                    
            end if 
            if (setting%Debug%File%face) &
                write(*,"(A,i5,A)") '*** leave ' // trim(subroutine_name) // " [Processor ", this_image(), "]"
    end subroutine face_copy_upstream_to_downstream_shared
!%
!%==========================================================================
!%==========================================================================  
!%
    subroutine face_velocities (facePackCol, isInterior)
        !%------------------------------------------------------------------
        !% Description:
        !% This subroutine calculates the face valocity and adjusts for limiter
        !%-------------------------------------------------------------------  
            integer, intent(in) :: facePackCol
            logical, intent(in) :: isInterior
            integer, pointer :: Npack, thisP(:)
            real(8), pointer :: f_area_u(:), f_area_d(:), f_velocity_u(:), f_velocity_d(:)
            real(8), pointer :: f_flowrate(:), zeroValue, vMax
            character(64) :: subroutine_name = 'adjust_face_dynamic_limit'
        !%-------------------------------------------------------------------
            if (setting%Debug%File%adjust) &
                write(*,"(A,i5,A)") '*** enter ' // trim(subroutine_name) // " [Processor ", this_image(), "]"
        !%-------------------------------------------------------------------
        !% Aliases
            f_area_u     => faceR(:,fr_Area_u)
            f_area_d     => faceR(:,fr_Area_d)
            f_velocity_u => faceR(:,fr_Velocity_u)
            f_velocity_d => faceR(:,fr_Velocity_d)
            f_flowrate   => faceR(:,fr_Flowrate)
            zeroValue    => setting%ZeroValue%Area
            vMax         => setting%Limiter%Velocity%Maximum
        !%----------------------------------------------------------------------
        if (isInterior) then
            !% face velocity calculation at the interior faces
            Npack => npack_faceP(facePackCol)
            thisP => faceP(1:Npack,facePackCol)
        else
            !% face velocity calculation at the shared faces
            Npack => npack_facePS(facePackCol)
            thisP => facePS(1:Npack,facePackCol)
        end if

        if (Npack > 0) then
   
            !% ensure face area_u is not smaller than zerovalue
            where (f_area_u(thisP) < zeroValue)
                f_area_u(thisP) = zeroValue
            endwhere
            !% ensure face area_d is not smaller than zerovalue
            where (f_area_d(thisP) < zeroValue)
                f_area_d(thisP) = zeroValue
            endwhere

            f_velocity_u(thisP) = f_flowrate(thisP)/f_area_u(thisP)

            f_velocity_d(thisP) = f_flowrate(thisP)/f_area_d(thisP)

            !%  limit high velocities
            if (setting%Limiter%Velocity%UseLimitMaxYN) then
                where(abs(f_velocity_u(thisP))  > vMax)
                    f_velocity_u(thisP) = sign(0.99d0 * vMax, f_velocity_u(thisP))
                endwhere

                where(abs(f_velocity_d(thisP))  > vMax)
                    f_velocity_d(thisP) = sign(0.99d0 * vMax, f_velocity_d(thisP))
                endwhere
            end if

        end if    
        
        if (setting%Debug%File%adjust) &
            write(*,"(A,i5,A)") '*** leave ' // trim(subroutine_name) // " [Processor ", this_image(), "]"
    end subroutine face_velocities
!%
!%  
!%========================================================================== 
!%==========================================================================
!%
    subroutine face_flowrate_limits_interior (facePackCol)   
        !%------------------------------------------------------------------
        !% Description:
        !% stores maximum and minimum flowrates on the face based on
        !% emptying the volume of the upstream element (maximum) or the 
        !% downstream element (reversed flow maximum negative or minimum flow)
        !%------------------------------------------------------------------
        !% Declarations:
            integer, intent(in) :: facePackCol
            integer, pointer :: Npack
            integer, pointer :: thisP(:), eup(:), edn(:)
            integer, pointer :: idx_fBCdn(:), idx_fBCup(:)
            real(8), pointer :: dt, eVolume(:)
        !%------------------------------------------------------------------
        !% Aliases
            Npack => npack_faceP(facePackCol)
            if (Npack < 1) return
            thisP   => faceP(1:Npack,facePackCol)
            eup     => faceI(:,fi_Melem_uL)
            edn     => faceI(:,fi_Melem_dL)
            eVolume => elemR(:,er_Volume)
            dt      => setting%Time%Hydraulics%Dt

            !% --- downstream BC on faces
            idx_fBCdn       => faceP(1:npack_faceP(fp_BCdn),fp_BCdn)
            !% --- upstream BC on faces
            idx_fBCup       => faceP(1:npack_faceP(fp_BCup),fp_BCup)
        !%------------------------------------------------------------------ 

        faceR(thisP,fr_FlowrateMax) =  eVolume(eup(thisP)) / dt
        faceR(thisP,fr_FlowrateMin) = -eVolume(edn(thisP)) / dt

        !% --- set downstream BC to allow any level of inflow
        faceR(idx_fBCdn,fr_FlowrateMin) = -nullvalueR

        !% --- set upstream BC face to allow any level of inflow
        faceR(idx_fBCup,fr_FlowrateMax) = nullvalueR

        ! print *, 'thisP ',thisP
        ! print *, 'eup(thisP)', eup(thisP)
        ! print *, 'edn(thisP)', edn(thisP)
        ! print *, faceR(thisP,fr_FlowrateMax)
        ! print *, faceR(thisP,fr_FlowrateMin)
        ! stop 43534
        
   

    end subroutine face_flowrate_limits_interior
!%
!%==========================================================================
!%==========================================================================
!%
    subroutine face_flowrate_limits_shared (facePackCol)
        !%-------------------------------------------------------------------
        !% Description:
        !% stores maximum and minimum flowrates on the face based on
        !% emptying the volume of the upstream element (maximum) or the 
        !% downstream element (reversed flow maximum negative or minimum flow)
        !% Must be conducted AFTER  inter_image_data_transfer
        !%-------------------------------------------------------------------
        !% Declarations
            integer             :: ii
            integer, intent(in) :: facePackCol  !% Column in faceP array for needed pack
            integer, pointer    :: Npack        !% expected number of packed rows in faceP.
            integer, pointer    :: thisP, eup, edn, BUpIdx, BDnIdx
            real(8), pointer    :: dt
            logical, pointer    :: isGhostUp, isGhostDn
        !%-------------------------------------------------------------------
        !% Preliminaries   
            Npack => npack_facePS(facePackCol)
            if (Npack < 1) return
            dt => setting%Time%Hydraulics%Dt
    
        !%-------------------------------------------------------------------   
        do ii=1,Npack
            !%---------------------------------------------------------------
            !% Local Aliases
            thisP           => facePS(ii,facePackCol)
            eup             => faceI(thisP,fi_Melem_uL)
            edn             => faceI(thisP,fi_Melem_dL)
            BUpIdx          => faceI(thisP,fi_BoundaryElem_uL)
            BDnIdx          => faceI(thisP,fi_BoundaryElem_dL)
            isGhostUp       => faceYN(thisP,fYN_isUpGhost)
            isGhostDn       => faceYN(thisP,fYN_isDnGhost)
            !%---------------------------------------------------------------
            if (isGhostUp) then 
                faceR(thisP,fr_FlowrateMax) = elemGR(ii,ebgr_Volume) / dt
            elseif (isGhostDn) then 
                faceR(thisP,fr_FlowrateMin) = -elemGR(ii,ebgr_Volume) / dt 
            end if

        end do


    end subroutine face_flowrate_limits_shared
!%
!%==========================================================================
!%==========================================================================
!%    
    subroutine face_head_limited (facePackCol)
        !%-------------------------------------------------------------------
        !% Description:
        !% Finds where Head < Zbottom on face and sets Depth and Area to zero
        !%-------------------------------------------------------------------
        !% Declarations:
            integer, intent(in) :: facePackCol
            integer, pointer :: Npack
            integer, pointer :: thisP(:)
        !%-------------------------------------------------------------------
        !% Aliases
            Npack => npack_faceP(facePackCol)
            if (Npack < 1) return
            thisP   => faceP(1:Npack,facePackCol)
        !%-------------------------------------------------------------------

        ! where ((onehalfR * (faceR(thisP,fr_Head_u) + faceR(thisP,fr_Head_d))) &
        !         .le. faceR(thisP,fr_Zbottom))
        !     faceR(thisP,fr_Depth_d)    = setting%ZeroValue%Depth
        !     faceR(thisP,fr_Depth_u)    = setting%ZeroValue%Depth
        !     faceR(thisP,fr_Area_d)     = setting%ZeroValue%Area
        !     faceR(thisP,fr_Area_u)     = setting%ZeroValue%Area
        !     faceR(thisP,fr_Velocity_d) = zeroR
        !     faceR(thisP,fr_Velocity_u) = zeroR
        !     faceR(thisP,fr_Flowrate)   = zeroR
        ! end where


    end subroutine face_head_limited
!%  
!%========================================================================== 
!%==========================================================================
!%
    subroutine face_zerodepth_interior (facePackCol)
        !%------------------------------------------------------------------
        !% Description:
        !% where one side has a zero depth element, the face head is
        !% adjusted to the smaller of (1) the head computed by interpolation
        !% or (2) the head on the non-zero depth element.
        !% Input: column in the faceP(:,:) array containing the packed 
        !% indexes of faces with zero elements on upstream, downstream, o
        !% both sides.
        !%------------------------------------------------------------------
        !% Declarations
            integer, intent(in) :: facePackCol
            real(8), pointer :: fHeadDn(:), fHeadUp(:), fDepthDn(:), fDepthUp(:)
            real(8), pointer :: fAreaDn(:), fAreaUp(:), fFlowrate(:)
            real(8), pointer :: fVelocityDn(:), fVelocityUp(:), fZbottom(:)
            real(8), pointer :: eHead(:), eFlowrate(:), eArea(:), eVelocity(:)
            integer, pointer :: eDn(:), eUp(:)
            integer, pointer :: mm, Npack, thisP(:)
            integer :: ii
        !%------------------------------------------------------------------
        !% Aliases:
            fHeadDn     => faceR(:,fr_Head_d)
            fHeadUp     => faceR(:,fr_Head_u)
            fDepthDn    => faceR(:,fr_Depth_d)
            fDepthUp    => faceR(:,fr_Depth_u)
            fAreaDn     => faceR(:,fr_Area_d)
            fAreaUp     => faceR(:,fr_Area_u)
            fVelocityDn => faceR(:,fr_Velocity_d)
            fVelocityUp => faceR(:,fr_Velocity_u)
            fFlowrate   => faceR(:,fr_Flowrate)
            fZbottom    => faceR(:,fr_Zbottom)
            eHead    => elemR(:,er_Head)
            eArea    => elemR(:,er_Area)
            eFlowrate=> elemR(:,er_Flowrate)
            eVelocity=> elemR(:,er_Velocity)
            eDn      => faceI(:,fi_Melem_dL)
            eUp      => faceI(:,fi_Melem_uL)
        !%------------------------------------------------------------------

        !% --- CASE: Face has zero element upstream
        Npack => npack_faceP(facePackCol)

        ! print *, 'in face zerodepth interior'
        ! print *, fFlowrate(43)
        
        if (Npack > 0) then 
            thisP => faceP(1:Npack,facePackCol) 

            !% --- set the head on the face for elements that have adjacent zero
            select case (facePackCol)

                case (fp_elem_downstream_is_zero)
                    !% ---set head to the smaller of the face head and the non-zero element upstream
                    fHeadUp(thisP) = min(fHeadUp(thisP), eHead(eUp(thisP)))
                    fHeadDn(thisP) = fHeadUp(thisP)

                    !% --- get a face depth consistent with this head
                    !%     note this depth might be negative
                    fDepthUp(thisP) = max(fHeadUp(thisP) - fZbottom(thisP), zeroR)
                    fDepthDn(thisP) = fDepthUp(thisP)

                    !% --- get face area consistent with this depth
                    do ii=1,Npack
                        mm => thisP(ii) 
                        fAreaUp(mm) = geo_area_from_depth_singular(eUp(mm), fDepthUp(mm), zeroR)
                    end do
                    fAreaDn(thisP) = fAreaUp(thisP)

                    !% --- set the flowrate through the face
                    !%     flowrate can only be from upstream to downstream (positive flow allowed) 
                    where ((fDepthUp(thisP) > setting%ZeroValue%Depth) .and. &
                           (fAreaUp(thisP) .ge. eArea(eUp(thisP))))
                        !%--- if the depth > 0 and the face area is greater than the element area
                        !%     then the face flow can support the entire flow rate (if an outflow)
                    
                        fFlowrate(thisP)   = max(zeroR,eFlowrate(eUp(thisP)))

                    elsewhere ((fDepthUp(thisP) > setting%ZeroValue%Depth) .and. &
                               (fAreaUp(thisP)  < eArea(eUp(thisP))))
                        !% --- the outflow is reduced in proportion with the area
                        !%     i.e., the velocity of the element is used for the outflow  
                        !%     note velocity must be negative or outflow is zero 
                        fFlowrate(thisP) = max(zeroR, eVelocity(eUp(thisP)) * fAreaUp(thisP))
                        
                    elsewhere !% for face depth < zero there is no possibility of a face flow
                        fFlowrate(thisP) = zeroR
                    endwhere

                    !% --- zero the face velocities to prevent small areas from being a problem
                    !%     this also means the advection of momentum into the element on the
                    !%     next time step is discounted until the element is no longer zero depth.
                    fVelocityUp(thisP) = zeroR
                    fVelocityDn(thisP) = zeroR

                case (fp_elem_upstream_is_zero)
                    !% ---set head to the smaller of the face head and the non-zero element downstream
                    fHeadDn(thisP) = min(fHeadDn(thisP), eHead(eDn(thisP)))
                    fHeadUp(thisP) = fHeadDn(thisP)

                    !% --- get a face depth consistent with this head
                    !%     note this depth might be negative
                    fDepthDn(thisP) = max(fHeadDn(thisP) - fZbottom(thisP), zeroR)
                    fDepthUp(thisP) = fDepthDn(thisP)

                    !% --- get face area consistent with this depth
                    do ii=1,Npack
                        mm => thisP(ii) 
                        fAreaDn(mm) = geo_area_from_depth_singular(eDn(mm), fDepthDn(mm), zeroR)
                    end do
                    fAreaUp(thisP) = fAreaDn(thisP)

                    !% --- set the flowrate through the face
                    !%     flowrate can only be from downstream to upstream (negative flow allowed)     
                    where ((fDepthDn(thisP) > setting%ZeroValue%Depth) .and. &
                           (fAreaDn(thisP) .ge. eArea(eDn(thisP))))
                        
                        fFlowrate(thisP)   = min(zeroR,eFlowrate(eDn(thisP)))

                    elsewhere ((fDepthDn(thisP) > setting%ZeroValue%Depth) .and. &
                             (fAreaDn(thisP) < eArea(eDn(thisP))))
                        !% --- the outflow is reduced in proportion with the area
                        !%     i.e., the velocity of the element is used for the outflow  
                        !%     note velocity must be negative or outflow is zero 
                        fFlowrate(thisP) = min(zeroR, eVelocity(eDn(thisP)) * fAreaDn(thisP))

                    elsewhere !% for face depth < zero there is no possibility of a face flow
                        fFlowrate(thisP) = zeroR
                    endwhere

                    !% --- zero the face velocities to prevent small areas from being a problem
                    !%     this also means the advection of momentum into the element on the
                    !%     next time step is discounted until the element is no longer zero depth.
                    fVelocityUp(thisP) = zeroR
                    fVelocityDn(thisP) = zeroR

                    ! print *, fFlowrate(43), fDepthDN(thisP)
                    ! print *, eFlowrate(eDn(43))

                case (fp_elem_bothsides_are_zero)
                    !% --- keep the previously interpolated head and depth, 
                    !%     but ensure area and fluxes are zero
                    fAreaDn(thisP)     = zeroR
                    fAreaUp(thisP)     = zeroR
                    fFlowrate(thisP)   = zeroR
                    fVelocityUp(thisP) = zeroR
                    fVelocityDn(thisP) = zeroR

                case default
            end select
        end if

    end subroutine face_zerodepth_interior
!%
!%==========================================================================
!%==========================================================================
!%
    ! subroutine face_flowrate_max_interior (facePackCol)
    !     !%------------------------------------------------------------------
    !     !% Description:
    !     !% stores the upstream element flowrate on the face.
    !     !% this is used in the JB algorithms
    !     !% "facePackCol" must be a face pack (faceP) array
    !     !% Stores the flowrate of the actual upstream element (i.e., where
    !     !% the flow is coming from if both flows are the same direction. 
    !     !% Stores the difference between the flows if the flows are in 
    !     !% opposite directions.
    !     !%------------------------------------------------------------------
    !     !% Declarations:
    !         integer, intent(in) :: facePackCol
    !         integer, pointer :: npack, thisF(:), eup(:), edn(:)
    !         real(8), pointer :: fQmax(:), eQ(:)
    !     !%------------------------------------------------------------------
    !     !% Aliases:
    !         npack => npack_faceP(facePackCol)
    !         if (npack < 1) return
    !         thisF => faceP(1:npack,facePackCol)
    !         fQmax => faceR(:,fr_Flowrate_Max)
    !         eQ    => elemR(:,er_Flowrate)
    !         eup   => faceI(:,fi_Melem_uL)
    !         edn   => faceI(:,fi_Melem_dL)
    !     !%------------------------------------------------------------------
    !     !% use (1 + sign(U)) and (1 - sign(U)) trick to discriminate between
    !     !% flows downstream from the upstream element and flows upstream
    !     !% from the downstream element.
    !     fQmax(thisF) = onehalfR * (                                                         &
    !                 (oneR + util_sign_with_ones( eQ( eup(thisF) ) ) ) *  eQ( eup(thisF) )   &
    !               + (oneR - util_sign_with_ones( eQ (edn(thisF) ) ) ) *  eQ( edn(thisF) ) )


    !     ! print *, ' '
    !     ! print *, '-------------------------------------------------'
    !     ! print *, 'in face flowrate'
    !     ! print *, thisF
    !     ! print *, ' '
    !     ! print *, eup(thisF)
    !     ! print *, ' '
    !     ! print *, edn(thisF)
    !     ! print *, ' '
    !     ! print *, eQ( eup(thisF) )
    !     ! print *, ' '
    !     ! print *,  eQ( edn(thisF) )
    !     ! print *, ' '
    !     ! print *, fQmax(thisF)
    !     ! print *, ' '
    !     ! print *, fQmax(:)
    !     ! print *, '-------------------------------------------------'
    !     ! print *, ' '


    !     !%------------------------------------------------------------------
    ! end subroutine face_flowrate_max_interior
!%    
!%==========================================================================    
!%==========================================================================
!%
    ! subroutine face_flowrate_max_shared (facePackCol)
    !     !%------------------------------------------------------------------
    !     !% Description:
    !     !% stores the upstream element flowrate on the face.
    !     !% this is used in the JB algorithms
    !     !% "facePackCol" must be a face pack (facePS) array
    !     !% Stores the flowrate of the actual upstream element (i.e., where
    !     !% the flow is coming from if both flows are the same direction. 
    !     !% Stores the difference between the flows if the flows are in 
    !     !% opposite directions.
    !     !%------------------------------------------------------------------
    !     !% Declarations:
    !         integer, intent(in) :: facePackCol
    !         integer, pointer    :: npack, thisF, ghostUp, ghostDn, ci
    !         integer, pointer    :: eup(:), edn(:)
    !         logical, pointer    :: isGhostUp, isGhostDn
    !         real(8), pointer    :: eQ(:), fQmax(:)
    !         integer             :: ii
    !         integer(kind=8) :: crate, cmax, cval
    !     !%------------------------------------------------------------------
    !     !% Preliminaries:
    !         !% start the shared timer
    !         sync all
    !         if (this_image()==1) then
    !             call system_clock(count=cval,count_rate=crate,count_max=cmax)
    !             setting%Time%WallClock%SharedStart = cval
    !             !setting%Time%WallClock%SharedStart_A = cval
    !         end if 
    !     !%------------------------------------------------------------------    
    !     !% Aliases
    !     !% note that aliases cannot be used where coarrays are invoked
    !         npack       => npack_facePS(facePackCol)
    !         if (npack < 1) return
    !         eup         => faceI(:,fi_Melem_uL)
    !         edn         => faceI(:,fi_Melem_dL)
    !         fQmax       => faceR(:,fr_Flowrate_Max)
    !     !%------------------------------------------------------------------
    !     !% cycle through the shared faces (does not readily vectorize)  
    !     do ii = 1,npack
    !         thisF       => facePS(ii,facePackCol)
    !         ci          => faceI(thisF,fi_Connected_image)
    !         ghostUp     => faceI(thisF,fi_GhostElem_uL)
    !         ghostDn     => faceI(thisF,fi_GhostElem_dL)
    !         isGhostUp   => faceYN(thisF,fYN_isUpGhost)
    !         isGhostDn   => faceYN(thisF,fYN_isDnGhost)

    !         !% condition for upstream element of the shared face is ghost and in a different image
    !         if (isGhostUp) then
    !             fQmax(thisF) = onehalfR * (                                                     &
    !                 (oneR + util_sign_with_ones( elemR(ghostUp,   er_Flowrate)[ci] ) ) * elemR(ghostUp,   er_Flowrate)[ci]  &
    !               + (oneR - util_sign_with_ones( elemR(edn(thisF),er_Flowrate)     ) ) * elemR(edn(thisF),er_Flowrate)     )
    !         !% condition for downstream element of the shared face is ghost and in a different image
    !         elseif (isGhostDn) then
    !             fQmax(thisF) = onehalfR * (                                                      &
    !                 (oneR + util_sign_with_ones( elemR(eup(thisF),er_Flowrate)     ) ) * elemR(eup(thisF),er_Flowrate)      &
    !               + (oneR - util_sign_with_ones( elemR(ghostDn,   er_Flowrate)[ci] ) ) * elemR(ghostDn,   er_Flowrate)[ci] )
    !         else
    !             write(*,*) 'CODE ERROR: unexpected else'
    !             !stop 
    !             call util_crashpoint( 88355)
    !             !return
    !         end if 
    !     end do

    !     !%------------------------------------------------------------------
    !     !% Closing
    !     sync all
    !     if (this_image()==1) then
    !         !% stop the shared timer
    !         call system_clock(count=cval,count_rate=crate,count_max=cmax)
    !         setting%Time%WallClock%SharedStop = cval
    !         setting%Time%WallClock%SharedCumulative &
    !                 = setting%Time%WallClock%SharedCumulative &
    !                 + setting%Time%WallClock%SharedStop &
    !                 - setting%Time%WallClock%SharedStart

    !         ! setting%Time%WallClock%SharedStop_A = cval
    !         ! setting%Time%WallClock%SharedCumulative_A &
    !         !         = setting%Time%WallClock%SharedCumulative_A &
    !         !         + setting%Time%WallClock%SharedStop_A &
    !         !         - setting%Time%WallClock%SharedStart_A                    
    !     end if 
    ! end subroutine face_flowrate_max_shared
!%
!%==========================================================================
    !%==========================================================================
!%
    ! subroutine face_interp_set_byMask &
    !     (fset, eset, eWdn, eWup, faceMaskCol)
    !     !%-----------------------------------------------------------------------------
    !     !% Description:
    !     !% Interpolates to a face for a set of variables using a mask
    !     !%-----------------------------------------------------------------------------
    !     integer, intent(in) :: fset(:), eset(:), eWdn, eWup, faceMaskCol
    !     integer, pointer :: eup(:), edn(:)
    !     integer :: ii
        
    !     character(64) :: subroutine_name = 'face_interp_set_byMask'
    !     !%-----------------------------------------------------------------------------
    !     if (setting%Debug%File%face) &
    !         write(*,"(A,i5,A)") '*** enter ' // trim(subroutine_name) // " [Processor ", this_image(), "]"
    !     !%-----------------------------------------------------------------------------
    !     eup => faceI(:,fi_Melem_uL)
    !     edn => faceI(:,fi_Melem_dL)
    !     !%-----------------------------------------------------------------------------
    !     !% cycle through each element in the set.
    !     do ii=1,size(fset)
    !         where (faceM(:,faceMaskCol))
    !             faceR(:,fset(ii)) = &
    !                 (+elemR(eup(:),eset(ii)) * elemR(edn(:),eWup) &
    !                  +elemR(edn(:),eset(ii)) * elemR(eup(:),eWdn) &
    !                 ) / &
    !                 ( elemR(edn(:),eWup) + elemR(eup(:),eWdn))
    !         endwhere
    !     end do

    !     print *, 'in face_interp_set_byMask -- may be obsolete'
    !     stop 87098

    !     if (setting%Debug%File%face) &
    !         write(*,"(A,i5,A)") '*** enter ' // trim(subroutine_name) // " [Processor ", this_image(), "]"
    ! end subroutine face_interp_set_byMask
!%
!%==========================================================================
!% END OF MODULE
!%==========================================================================
end module face
