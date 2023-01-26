#!/bin/bash
#
# Script performs the following steps:
#     1. Get centerline from manually corrected T2w segmentation ground truth (GT) for CanProCo dataset
#     2. Co-register other contrast to T2w image
#
# Dependencies (versions):
# - SCT (5.8)
#

# Usage:
#     sct_run_batch -c config.json

# The following global variables are retrieved from the caller sct_run_batch
# but could be overwritten by uncommenting the lines below:
# PATH_DATA_PROCESSED="~/data_processed"
# PATH_RESULTS="~/results"
# PATH_LOG="~/log"
# PATH_QC="~/qc"
#
# Author: Jan Valosek
#

# Uncomment for full verbose
set -x

# Immediately exit if error
set -e -o pipefail

# Exit if user presses CTRL+C (Linux) or CMD+C (OSX)
trap "echo Caught Keyboard Interrupt within script. Exiting now.; exit" INT

# Print retrieved variables from sct_run_batch to the log (to allow easier debug)
echo "Retrieved variables from from the caller sct_run_batch:"
echo "PATH_DATA: ${PATH_DATA}"
echo "PATH_DATA_PROCESSED: ${PATH_DATA_PROCESSED}"
echo "PATH_RESULTS: ${PATH_RESULTS}"
echo "PATH_LOG: ${PATH_LOG}"
echo "PATH_QC: ${PATH_QC}"

# Retrieve input params and other params
SUBJECT=$1

# get starting time:
start=`date +%s`

# SCRIPT STARTS HERE
# ==============================================================================
# Display useful info for the log, such as SCT version, RAM and CPU cores available
sct_check_dependencies -short

# Go to folder where data will be copied and processed
cd $PATH_DATA_PROCESSED

# Copy BIDS-required files to processed data folder (e.g. list of participants)
if [[ ! -f "participants.tsv" ]]; then
  rsync -avzh $PATH_DATA/participants.tsv .
fi
# Copy list of participants in results folder 
if [[ ! -f "participants.json" ]]; then
  rsync -avzh $PATH_DATA/participants.json .
fi
if [[ ! -f "dataset_description.json" ]]; then
  rsync -avzh $PATH_DATA/dataset_description.json .
fi

# Copy source images
# Note: we use '/./' in order to include the sub-folder 'ses-0X'
# Note: copy only T2w images to save space
rsync -Ravzh $PATH_DATA/./$SUBJECT .
# Go to subject folder for source images
cd ${SUBJECT}/anat

# Define variables
# We do a substitution '/' --> '_' in case there is a subfolder 'ses-0X/'
file="${SUBJECT//[\/]/_}"

# -------------------------------------------------------------------------
# T2w
# -------------------------------------------------------------------------
# Add suffix corresponding to contrast
file_t2w=${file}_T2w
# Construct path to manually corrected SC segmentation
FILESEG="${file_t2w}_seg"
FILESEGMANUAL="${PATH_DATA}/derivatives/labels/${SUBJECT}/anat/${FILESEG}-manual.nii.gz"

# Check if T2w SC seg exists
if [[ -f ${FILESEGMANUAL} ]];then

    # Copy manually corrected segmentation ground truth (GT) from derivatives folder (to do not alter files in derivatives)
    # Note, this ground truth (GT) segmentation was obtained from reoriented and resampled images (this is why we are applying the same preprocessing steps also below)
    rsync -avzh ${FILESEGMANUAL} ${FILESEG}.nii.gz
    # Fit a regularized centerline on an already-existing cord segmentation.
    # Note, -centerline-algo bspline and -centerline-smooth 30 is the default setting in SCT v5.8. We make these parameters explicit in case the default values change in future SCT version.
    sct_get_centerline -i ${FILESEG}.nii.gz -method fitseg -centerline-algo bspline -centerline-smooth 30 -qc ${PATH_QC} -qc-subject ${SUBJECT}
    # Copy centerline to derivatives folder (to be compatible with ivadomed)
    mkdir -p ${PATH_DATA_PROCESSED}/derivatives/labels/${SUBJECT}/anat
    rsync -avzh ${FILESEG}_centerline.nii.gz ${PATH_DATA_PROCESSED}/derivatives/labels/${SUBJECT}/anat/${FILESEG}_centerline.nii.gz

    # Apply the same preprocessing steps as were done for the SC segmentation (to have the same dimensions of the image and GT centerline)
    # Rename raw file
    mv ${file_t2w}.nii.gz ${file_t2w}_raw.nii.gz
    # Reorient to RPI and resample to 0.8mm isotropic voxel (supposed to be the effective resolution)
    sct_image -i ${file_t2w}_raw.nii.gz -setorient RPI -o ${file_t2w}_raw_RPI.nii.gz
    sct_resample -i ${file_t2w}_raw_RPI.nii.gz -mm 0.8x0.8x0.8 -o ${file_t2w}_raw_RPI_r.nii.gz
    # Rename _raw_RPI_r file (to be BIDS compliant)
    mv ${file_t2w}_raw_RPI_r.nii.gz ${file_t2w}.nii.gz

else
    echo "${SUBJECT}/${FILESEGMANUAL} does not exist" >> $PATH_LOG/_error_check_input_files.log
fi

# -------------------------------------------------------------------------
# Co-register other contrast to T2w
# -------------------------------------------------------------------------
# Initialize filenames
file_stir="${file}_STIR"
file_psir="${file}_PSIR"
file_t2s="${file}_T2star"
file_mt_mts="${file}_acq-MT_MTS"
file_t1_mts="${file}_acq-T1w_MTS"
file_mton_mts="${file}_acq-MTon_MTS"
file_mtoff_mts="${file}_acq-MToff_MTS"
contrasts=($file_stir $file_psir $file_t2s $file_mt_mts $file_t1_mts $file_mton_mts $file_mtoff_mts)

# Prepare T2star images
# Check if T2star image exists
if [[ -f ${file_t2s}.nii.gz ]];then
  # Rename raw file
  mv ${file_t2s}.nii.gz ${file_t2s}_raw.nii.gz
  file_t2s="${file_t2s}_raw"
  # Compute root-mean square across 4th dimension (if it exists), corresponding to all echoes in Philips scans.
  sct_maths -i ${file_t2s}.nii.gz -rms t -o ${file_t2s}_rms.nii.gz
  file_t2s="${file_t2s}_rms"
  # Rename _rms file
  mv ${file_t2s}.nii.gz ${file}_T2star.nii.gz
fi


# Loop across contrasts
for contrast in "${contrasts[@]}"; do
    # Check if contrast exists
    if [[ -f ${contrast}.nii.gz ]];then
        # Bring contrast to T2w space
        sct_register_multimodal -i ${contrast}.nii.gz -d ${file_t2w}.nii.gz -o ${contrast}2${file_t2w}.nii.gz -identity 1 -x nn

        # Create QC report to assess registration quality
        # Note: registration quality is assessed by comparing the ${contrast} image to the T2w centerline
        sct_qc -i ${contrast}2${file_t2w}.nii.gz -s ${FILESEG}_centerline.nii.gz -p sct_get_centerline -qc ${PATH_QC} -qc-subject ${SUBJECT}
        sct_qc -i ${contrast}2${file_t2w}.nii.gz -s ${FILESEG}_centerline.nii.gz -p sct_label_vertebrae -qc ${PATH_QC} -qc-subject ${SUBJECT}
    fi
done

# -------------------------------------------------------------------------
# Display useful info for the log
# -------------------------------------------------------------------------
end=`date +%s`
runtime=$((end-start))
echo
echo "~~~"
echo "SCT version: `sct_version`"
echo "Ran on:      `uname -nsr`"
echo "Duration:    $(($runtime / 3600))hrs $((($runtime / 60) % 60))min $(($runtime % 60))sec"
echo "~~~"
