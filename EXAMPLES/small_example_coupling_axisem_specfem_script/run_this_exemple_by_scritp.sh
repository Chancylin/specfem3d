#!/bin/bash

# FILL directory where is installed specfem3d (git devel version)
rootdir=/mnt/Data1/vmont/GIT/specfem3d/

#
#     ALL INPUTS FILES NEEDED TO RUN THIS SCRIPT ARE IN ./Param_files
#
#
#
#
#

########################    TRACTION DATABASES GENERATION   ########################################################

axisem_sources=$rootdir/EXTERNAL_CODES_coupled_with_SPECFEM3D/AxiSEM_for_SPECFEM3D/AxiSEM_modif_for_coupling_with_specfem

# ------------- copy inputs files for specfem  ------------
cp -r Param_files/DATA DATA
cp -r Param_files/MESH MESH

nproc_specfem=`grep ^NPROC DATA/Par_file_several_proc | grep -v -E '^[[:space:]]*#' | cut -d = -f 2`

# ------ CREATE ALL DIRECTORIES
mkdir -p DATABASES_MPI OUTPUT_FILES run_axisem

# ------ copy axisem sources
cp -r $axisem_sources/* run_axisem/.

# copy input files defines by user
cp  Param_files/inputs_files_for_axisem/inparam_mesh run_axisem/MESHER/.
cp  Param_files/inputs_files_for_axisem/inparam_* run_axisem/SOLVER/.
cp  Param_files/inputs_files_for_axisem/*.par run_axisem/SOLVER/.


# --------------- CREATE INPUTS FOR SPECFEM -----------------

# run internal mesher (must be in serila mode in order to use scotch decomposer)-----------------
cp DATA/Par_file_one_proc DATA/Par_file  # copy Par_file for serial mode
mpirun -np 1 $rootdir/bin/xmeshfem3D

# run scotch decomposer (serial code)
cp DATA/Par_file_several_proc DATA/Par_file # now copy Par_file for mpi parallel mode
$rootdir/bin/xdecompose_mesh $nproc_specfem  MESH/ DATABASES_MPI/

# run generate database
mpirun -np $nproc_specfem $rootdir/bin/xgenerate_databases
cp Numglob2loc_elmn.txt MESH/.
grep peri OUTPUT_FILES/output_generate_databases.txt
grep sugg OUTPUT_FILES/output_generate_databases.txt



# ------------------ RUNNING AXISEM ----------------------------
AXISEM_MESH_NAME=$(awk '$1=="MESHNAME" {print $2}' run_axisem/SOLVER/inparam_basic)

# mesher
cd run_axisem/MESHER
./submit_called_from_matlab.csh
./movemesh_called_from_matlab.csh $AXISEM_MESH_NAME

# solver
RUN_AXI_SOLVER=1
cd ../SOLVER
cp ../../MESH/list_ggl* .
./add_line_number_in_points_lists.sh
./submit_called_from_matlab.csh  $RUN_AXI_SOLVER

# reconstruc 3D wavefield on chunk edges from 2D axisem solution
cd $RUN_AXI_SOLVER
mpirun -np $nproc_specfem $rootdir/EXTERNAL_CODES_coupled_with_SPECFEM3D/AxiSEM_for_SPECFEM3D/UTILS_COUPLING_SpecFEM/xexpand_2D_3D

# interpolation of axisem solution for specfem time step
mpirun -np $nproc_specfem $rootdir/EXTERNAL_CODES_coupled_with_SPECFEM3D/AxiSEM_for_SPECFEM3D/UTILS_COUPLING_SpecFEM/xreformat

# back to the launching directory
cd ../../../


########################   END TRACTION DATABASES GENERATION   ########################################################


# ------ run specfem simulation
mpirun -np  $nproc_specfem $rootdir/bin/xspecfem3D

#------- make vtk snapshots


NTSTEP_BETWEEN_FRAMES=`grep ^NTSTEP_BETWEEN_FRAMES DATA/Par_file | grep -v -E '^[[:space:]]*#' | cut -d = -f 2`
NSTEP=`grep ^NSTEP DATA/Par_file | grep -v -E '^[[:space:]]*#' | cut -d = -f 2`

for IT in `seq $NTSTEP_BETWEEN_FRAMES $NTSTEP_BETWEEN_FRAMES $NSTEP`;
do
./create_one_snapshot.sh $IT
done
