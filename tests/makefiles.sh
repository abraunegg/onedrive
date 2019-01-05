#!/bin/bash
ONEDRIVEALT=~/OneDriveALT
if [ ! -d ${ONEDRIVEALT} ]; then
        mkdir -p ${ONEDRIVEALT}
else
        rm -rf ${ONEDRIVEALT}/*
fi

BADFILES=${ONEDRIVEALT}/bad_files
TESTFILES=${ONEDRIVEALT}/test_files
mkdir -p ${BADFILES}
mkdir -p ${TESTFILES}
dd if=/dev/urandom of=${TESTFILES}/large_file1.txt count=15 bs=1572864
dd if=/dev/urandom of=${TESTFILES}/large_file2.txt count=20 bs=1572864

# Create bad files that should be skipped
touch "${BADFILES}/ leading_white_space"
touch "${BADFILES}/trailing_white_space "
touch "${BADFILES}/trailing_dot."
touch "${BADFILES}/includes < in the filename"
touch "${BADFILES}/includes > in the filename"
touch "${BADFILES}/includes : in the filename"
touch "${BADFILES}/includes \" in the filename"
touch "${BADFILES}/includes | in the filename"
touch "${BADFILES}/includes ? in the filename"
touch "${BADFILES}/includes * in the filename"
touch "${BADFILES}/includes \\ in the filename"
touch "${BADFILES}/includes \\\\ in the filename"
touch "${BADFILES}/CON"
touch "${BADFILES}/CON.text"
touch "${BADFILES}/PRN"
touch "${BADFILES}/AUX"
touch "${BADFILES}/NUL"
touch "${BADFILES}/COM0"
touch "${BADFILES}/COM1"
touch "${BADFILES}/COM2"
touch "${BADFILES}/COM3"
touch "${BADFILES}/COM4"
touch "${BADFILES}/COM5"
touch "${BADFILES}/COM6"
touch "${BADFILES}/COM7"
touch "${BADFILES}/COM8"
touch "${BADFILES}/COM9"
touch "${BADFILES}/LPT0"
touch "${BADFILES}/LPT1"
touch "${BADFILES}/LPT2"
touch "${BADFILES}/LPT3"
touch "${BADFILES}/LPT4"
touch "${BADFILES}/LPT5"
touch "${BADFILES}/LPT6"
touch "${BADFILES}/LPT7"
touch "${BADFILES}/LPT8"
touch "${BADFILES}/LPT9"

# Test files from cases
# File contains invalid whitespace characters
tar xf ./bad-file-name.tar.xz -C ${BADFILES}/

# HelloCOM2.rar should be allowed
dd if=/dev/urandom of=${TESTFILES}/HelloCOM2.rar count=5 bs=1572864

