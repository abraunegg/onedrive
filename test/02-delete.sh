#!/bin/bash -e

echo "* Delete some files and sync"
rm "$TEST_DIR/2" "$TEST_DIR/a/2"
$ONEDRIVE
[ ! -f "$TEST_DIR/1"   ] && return 1
[ ! -f "$TEST_DIR/a/1" ] && return 1
[ -f "$TEST_DIR/2" ]     && return 1
[ -f "$TEST_DIR/a/2" ]   && return 1

return 0
