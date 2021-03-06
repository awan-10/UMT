# 1 "rt/SweepScheduler.F90"
!***********************************************************************
!                        Version 1:  09/96, PFN                        *
!                                                                      *
!   SWEEPSCHEDULER - This routine determines the order in which the    *
!                    discrete ordinates will be solved.                *
!                                                                      *
!   Input:                                                             *
!                                                                      *
!   Output:                                                            *
!                                                                      *
!***********************************************************************
   subroutine SweepScheduler

   use kind_mod
   use constant_mod
   use Size_mod
   use Geometry_mod
   use Communicator_mod
   use QuadratureList_mod
   use Quadrature_mod
   use BoundaryList_mod
   use Boundary_mod

   implicit none

!  Include 1

   include 'mpif.h'

!  Local Variables

   integer :: status(MPI_STATUS_SIZE,2),request(2*Size%ncomm)

   integer :: i, ia, ib, m, ndone, neighbor,        &
              iset, ishared, bin, maxdepend, nsend, &
              ierr, nleft, my_node

   integer :: NumQuadSets, NumBin, NangBin, nShared, nReflecting
   integer :: angle, mRef
   integer :: n

   integer, dimension (1) :: imax

   real(adqt) :: dot

!  Dynamic

   integer,  allocatable :: depend(:)
   integer,  allocatable :: BinTally(:)
   integer,  allocatable :: Order(:)
   integer,  allocatable :: temp(:)
   integer,  allocatable :: buffer(:,:) 
   integer,  allocatable :: BinOffSet(:)

!  Mesh Constants

   my_node     = Size%my_node
   NumQuadSets = getNumQuadSets(Quad)
   nShared     = getNumberOfShared(RadBoundary)
   nReflecting = getNumberOfReflecting(RadBoundary)

   AngleSetLoop: do iset=1,NumQuadSets

     QuadSet => getQuadrature(Quad, iset)
     NumBin  =  QuadSet% NumBin

!  Allocate temporaries

     allocate( depend(NumBin) )
     allocate( BinTally(NumBin) )
     allocate( Order(NumBin) )
     allocate( temp(NumBin) )
     allocate( buffer(NumBin,nShared) )
     allocate( BinOffSet(NumBin) )

!  Tally message size by angle bin

     if (Size% decomp_s == 'on') then

       BinTally(:) = 0

       AngleBin: do bin=1,NumBin
         CommunicatorLoop: do ishared=1,nShared
           Comm => getMessage(QuadSet, bin, ishared)

           BinTally(bin) = BinTally(bin) + Comm% lenrecv 

         enddo CommunicatorLoop
       enddo AngleBin

     else

       BinTally(:) = 1

     endif

!  Tally dependencies for reflecting boundaries

!     nNeed(:) = 0
!     depAngle(:,:) = 0
     depend(:) = 0

     ReflectingBoundary: do n=1,nReflecting
       Bdy => getReflecting(RadBoundary, n)
       do angle=1,QuadSet% NumAngles
         mRef = getReflectedAngle(Bdy, angle)
         bin  = QuadSet% AngleToBin(angle)
!         bin  = QuadSet% AngleToBin(mRef)
         if (mRef > 0) then
           depend(bin) = depend(bin) + BinTally(bin)
!             nNeed(angle)     = nNeed(angle) + BinTally(mRef)
!             depAngle(mRef,n) = angle
         endif
       enddo
     enddo ReflectingBoundary

     imax      = maxloc( depend(1:NumBin) )
     maxdepend = depend(imax(1))
     ndone     = 0 

     do while (maxdepend > 0)
       ndone             = ndone + 1
       Order(ndone)      = imax(1)
       BinTally(imax(1)) = -999 
       depend(imax(1))   = -999 

       imax      = maxloc( depend(1:NumBin) )
       maxdepend = depend(imax(1))
     enddo

     temp(:) = Order(:)

     do i=1,ndone
       Order(NumBin-i+1) = temp(i)
     enddo



     if (Size% decomp_s == 'off') then
 
       do i=1,NumBin-ndone
         imax            = maxloc( depend(1:NumBin) )
         Order(i)        = imax(1)
         depend(imax(1)) = -999
       enddo

     elseif (Size% decomp_s == 'on') then

!  Sort remaining bins from largest message to smallest

!  Post Receives

       do ishared=1,nShared
         Bdy      => getShared(RadBoundary, ishared)
         neighbor =  getNeighborID(Bdy) 
         nsend    =  NumBin 

         call MPI_Irecv(buffer(1,ishared), nsend, MPI_INTEGER, &
                        neighbor, 500, MPI_COMM_WORLD,         &
                        request(2*ishared), ierr)
       enddo

!  Sort

       imax = maxloc( BinTally(1:NumBin) )

       nleft = NumBin - ndone
       do i=nleft,1,-1
         Order(i)          = imax(1)
         BinTally(imax(1)) = -999 
         imax              = maxloc( BinTally(1:NumBin) )
       enddo

!  Send my order to all neighbors

       do ishared=1,nShared
         Bdy      => getShared(RadBoundary, ishared)
         neighbor =  getNeighborID(Bdy)
         nsend    =  NumBin 

         call MPI_Isend(Order, nsend, MPI_INTEGER,      &
                        neighbor, 500, MPI_COMM_WORLD,  &
                        request(2*ishared-1), ierr)

         call MPI_Wait(request(2*ishared-1), status, ierr)
       enddo

       call MPI_Barrier(MPI_COMM_WORLD, ierr)


       do ishared=1,nShared
         call MPI_Wait(request(2*ishared), status, ierr)
         do i=1,NumBin
           QuadSet% RecvOrder0(i,ishared) = buffer(i,ishared)
           QuadSet% RecvOrder(i,ishared)  = buffer(i,ishared)
         enddo
       enddo

     endif

     BinOffSet(1) = 0
     do bin=2,NumBin
       BinOffSet(bin) = BinOffSet(bin-1) + QuadSet% NangBinList(bin-1)
     enddo

     do i=1,NumBin
       bin                    = Order(i)
       NangBin                = QuadSet% NangBinList(bin)
!!$       write(6,222) my_node, i, bin, NangBin
!!$ 222   format("my_node = ",i2," i = ",i2," bin = ",i2," NangBin = ",i2)
       QuadSet% SendOrder0(i) = bin
       QuadSet% SendOrder(i)  = bin
       do ia=1,NangBin
         QuadSet% AngleOrder(ia,bin) = BinOffSet(bin) + ia
       enddo
     enddo

!  Release Temporaries
     deallocate( depend )
     deallocate( BinTally )
     deallocate( Order )
     deallocate( temp )
     deallocate( buffer )
     deallocate( BinOffSet )

   enddo AngleSetLoop



   return
   end subroutine SweepScheduler 

