#!/usr/bin/env bash
# Build, copy to the unit(s), install and restart the service.
#   scripts/deploy.sh rtk1|rtk2|all [--config] [--no-restart]
#   --config   also install deploy/units/<unit>.conf as /etc/rtk/rtk.conf
set -euo pipefail
. "$(dirname "$0")/lib.sh"
target="${1:-}"; [ -n "$target" ] || die "usage: deploy.sh rtk1|rtk2|all [--config] [--no-restart]"
shift || true
do_config=0; restart=1
for a in "$@"; do
    case "$a" in --config) do_config=1;; --no-restart) restart=0;; *) die "unknown option $a";; esac
done
units="$target"; [ "$target" = all ] && units="$(all_units)"

"$REPO/scripts/build.sh" >/dev/null
for u in $units; do
    host="$(unit_host "$u")"
    echo "== $u via $host"
    push "$REPO/zig-out/bin/rtkd" "$host" /tmp/rtkd.new
    if [ "$do_config" = 1 ]; then
        push "$REPO/deploy/units/$u.conf" "$host" /tmp/rtk.conf.new
        ssh "$host" 'sudo install -D -m644 /tmp/rtk.conf.new /etc/rtk/rtk.conf'
    fi
    ssh "$host" 'sudo install -m755 /tmp/rtkd.new /usr/local/bin/rtkd && rm -f /tmp/rtkd.new'
    if [ "$restart" = 1 ]; then
        ssh "$host" 'sudo systemctl restart rtkd && sleep 1 && systemctl is-active rtkd && /usr/local/bin/rtkd version'
    fi
done
