#!/bin/bash
# This script is to assist in starting the onedrive client when using init.d
APP_OPTIONS="--monitor --verbose --enable-logging"
onedrive "$APP_OPTIONS" > /dev/null 2>&1 &
exit 0
