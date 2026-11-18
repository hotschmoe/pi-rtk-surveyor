#!/bin/sh
set -eu
binary=$1
"$binary" --config deploy/units/rtk1.conf check
"$binary" --config deploy/units/rtk2.conf check
if "$binary" --config /nonexistent/rtkd-test-config check; then
    exit 1
fi
