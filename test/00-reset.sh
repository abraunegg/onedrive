#!/bin/bash -e

echo "* First sync"
$ONEDRIVE

echo "* Clean the directory and sync"
rm -rf "$TEST_DIR"
mkdir "$TEST_DIR"
$ONEDRIVE
[ ! -z `$(ls -A "$TEST_DIR")` ] && return 1

return 0
