#!/usr/bin/env bash
# Teach the units a field Wi-Fi network (phone hotspot or travel router), alongside the office one.
#   scripts/add-wifi.sh rtk1|rtk2|all "SSID" [priority=10]
# The password is read from the terminal (not echoed), sent over ssh stdin, and written ONLY to
# a root-owned NetworkManager profile on the Pi. It is never stored in this repository, in shell
# history, or on a command line. Existing profiles (the office Wi-Fi) are left untouched; the Pi
# joins whichever known network is in range, highest priority first.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
target="${1:-}"; ssid="${2:-}"; prio="${3:-10}"
[ -n "$target" ] && [ -n "$ssid" ] || die 'usage: add-wifi.sh rtk1|rtk2|all "SSID" [priority]'
case "$ssid" in *$'\n'*|*'='*|*'['*|*']'*) die "SSID may not contain newlines, '=', '[' or ']'";; esac
units="$target"; [ "$target" = all ] && units="$(all_units)"
read -rsp "Password for '$ssid' (input hidden): " psk; echo
[ "${#psk}" -ge 8 ] && [ "${#psk}" -le 63 ] || die "WPA2 passwords are 8-63 characters"
case "$psk" in *$'\n'*) die "password may not contain a newline";; esac
name="rtk-field-$(printf '%s' "$ssid" | tr -c 'A-Za-z0-9' '-' | cut -c1-24)"
for u in $units; do
    host="$(unit_host "$u")"
    uuid="$(cat /proc/sys/kernel/random/uuid)"
    printf '[connection]\nid=%s\nuuid=%s\ntype=wifi\ninterface-name=wlan0\nautoconnect=true\nautoconnect-priority=%s\n\n[wifi]\nmode=infrastructure\nssid=%s\npowersave=2\n\n[wifi-security]\nkey-mgmt=wpa-psk\npsk=%s\n\n[ipv4]\nmethod=auto\n\n[ipv6]\nmethod=auto\n' \
        "$name" "$uuid" "$prio" "$ssid" "$psk" \
      | ssh "$host" "sudo install -m 600 -o root -g root /dev/stdin '/etc/NetworkManager/system-connections/$name.nmconnection' && sudo nmcli connection reload && echo \"$u: profile '$name' installed (priority $prio)\""
done
unset psk
