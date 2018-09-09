#!/bin/bash -e

echo "First sync"
$ONEDRIVE
echo "Clean directory and sync"
rm -rf "$TEST_DIR"
mkdir "$TEST_DIR"
$ONEDRIVE
