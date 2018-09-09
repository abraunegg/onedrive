#!/bin/bash -e

echo "* Create some test files and sync"
mkdir "$TEST_DIR/a"
echo "1" > "$TEST_DIR/1"
echo "2" > "$TEST_DIR/2"
echo "1" > "$TEST_DIR/a/1"
echo "2" > "$TEST_DIR/a/2"
$ONEDRIVE
[ ! -f "$TEST_DIR/1"   ] && return 1
[ ! -f "$TEST_DIR/a/1" ] && return 1
[ ! -f "$TEST_DIR/2" ]   && return 1
[ ! -f "$TEST_DIR/a/2" ] && return 1

return 0
