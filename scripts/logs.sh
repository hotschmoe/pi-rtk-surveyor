#!/usr/bin/env bash
set -euo pipefail
. "$(dirname "$0")/lib.sh"
u="${1:-}"; [ -n "$u" ] || die "usage: logs.sh rtk1|rtk2 [journalctl args]"
shift || true
exec ssh -t "$(unit_host "$u")" journalctl -u rtkd -f -o short-monotonic "$@"
