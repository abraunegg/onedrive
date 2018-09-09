#!/bin/bash -e
CONFIG_DIR=$(realpath ./test/config)
SYNC_DIR=/tmp/onedrive
ONEDRIVE="eval \"$(realpath ./onedrive)\" --confdir \"$CONFIG_DIR\" --syncdir \"$SYNC_DIR\""

mkdir -p "$CONFIG_DIR"
rm -rf "$SYNC_DIR"

# limit all tests to the subdirectory TEST
TEST_DIR="$SYNC_DIR/TEST"
echo "TEST" > $CONFIG_DIR/sync_list

cd test
for test in *.sh
do
	echo "Running $test..."
	. "$test"
done
