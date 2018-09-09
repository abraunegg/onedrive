#!/bin/bash -e

echo "* Rename some files and sync"
mv "$TEST_DIR/1" "$TEST_DIR/3"
mv "$TEST_DIR/a/1" "$TEST_DIR/a/3"
$ONEDRIVE
[ -f "$TEST_DIR/1"   ] && return 1
[ -f "$TEST_DIR/a/1" ] && return 1
[ ! -f "$TEST_DIR/3" ]     && return 1
[ ! -f "$TEST_DIR/a/3" ]   && return 1

return 0
