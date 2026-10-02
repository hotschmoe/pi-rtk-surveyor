#!/usr/bin/env bash
# Prepare a running Pi to host rtkd. Idempotent. Never touches Wi-Fi credentials.
#   scripts/provision.sh rtk1|rtk2
# Creates the 'rtk' service user (groups dialout/spi/gpio), /etc/rtk and
# /var/lib/rtk, installs the systemd unit and the unit's config if none exists,
# disables the old Python service, and enables rtkd plus the keypad power-off path unit.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
u="${1:-}"; [ -n "$u" ] || die "usage: provision.sh rtk1|rtk2"
host="$(unit_host "$u")"
echo "== provisioning $u via $host"
push "$REPO/deploy/rtkd.service" "$host" /tmp/rtkd.service
push "$REPO/deploy/units/$u.conf" "$host" /tmp/rtk.conf.new
push "$REPO/deploy/rtk-poweroff.path" "$host" /tmp/rtk-poweroff.path
push "$REPO/deploy/rtk-poweroff.service" "$host" /tmp/rtk-poweroff.service
ssh "$host" 'bash -s' <<'REMOTE'
set -e
# Free the UART: the previous project's service and any serial getty on it.
sudo systemctl disable --now pi-rtk-surveyor 2>/dev/null || true
sudo systemctl disable --now serial-getty@ttyAMA0 serial-getty@serial0 2>/dev/null || true

id rtk >/dev/null 2>&1 || sudo useradd --system --home-dir /var/lib/rtk --shell /usr/sbin/nologin rtk
sudo usermod -aG dialout,spi,gpio rtk
sudo install -d -m755 /etc/rtk
[ -f /etc/rtk/rtk.conf ] || sudo install -m644 /tmp/rtk.conf.new /etc/rtk/rtk.conf
sudo install -d -o rtk -g rtk -m755 /var/lib/rtk
sudo install -m644 /tmp/rtkd.service /etc/systemd/system/rtkd.service
sudo rm -f /etc/sudoers.d/rtk
sudo install -m644 /tmp/rtk-poweroff.path /tmp/rtk-poweroff.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable rtkd
sudo systemctl enable --now rtk-poweroff.path
rm -f /tmp/rtkd.service /tmp/rtk.conf.new /tmp/rtk-poweroff.path /tmp/rtk-poweroff.service
echo "provisioned: $(hostname)"
REMOTE
