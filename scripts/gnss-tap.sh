#!/usr/bin/env bash
# Capture the raw receiver byte stream with rtkd stopped. The service is
# restarted afterwards, even on Ctrl-C.
#   scripts/gnss-tap.sh rtk1|rtk2 [seconds=10]  -> captures/<unit>-<utc>.raw
set -euo pipefail
. "$(dirname "$0")/lib.sh"
u="${1:-}"; [ -n "$u" ] || die "usage: gnss-tap.sh rtk1|rtk2 [seconds]"
secs="${2:-10}"
host="$(unit_host "$u")"
mkdir -p "$REPO/captures"
out="$REPO/captures/$u-$(date -u +%Y%m%dT%H%M%SZ).raw"
restore() { ssh "$host" 'sudo systemctl start rtkd 2>/dev/null || true'; }
trap restore EXIT
ssh "$host" 'sudo systemctl stop rtkd 2>/dev/null || true'
echo "capturing $secs s from $u ($host) -> $out" >&2
ssh "$host" "sudo stty -F /dev/serial0 115200 raw -echo && sudo timeout $secs cat /dev/serial0" > "$out" || true
ls -l "$out" >&2
echo "NMEA lines: $(grep -a -c '^\$' "$out" || true)   RTCM sync bytes: $(LC_ALL=C grep -a -o $'\xd3' "$out" | wc -l)" >&2
