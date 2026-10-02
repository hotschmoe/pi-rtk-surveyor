# Setting up a unit

Two Raspberry Pi Zero 2 W units, each with a Waveshare LC29H GPS/RTK HAT and a
Waveshare 1.3" OLED HAT. One is the **base** (LC29H BS), one the **rover**
(LC29H DA). Operating system: Raspberry Pi OS Bookworm 64-bit.

## One-time card preparation

The card needs, in `/boot/firmware/config.txt` (`[all]` section):

```
dtparam=spi=on
enable_uart=1
dtoverlay=disable-bt
```

and **no** `console=serial0,115200` in `/boot/firmware/cmdline.txt`. This puts the
PL011 UART on GPIO14/15 for the receiver. Optional but recommended for bench
work: USB gadget mode (`dtoverlay=dwc2,dr_mode=peripheral`,
`modules-load=dwc2,g_cdc`) gives SSH and a serial console over the OTG cable, and
Wi-Fi power-save off (`wifi.powersave=2` in the NetworkManager profile) stops SSH
stalls. Wi-Fi credentials live only in the card's NetworkManager profile.

## Install `rtkd` from the dev box

```sh
scripts/provision.sh rtk1        # once per unit: user, dirs, systemd units, config
scripts/provision.sh rtk2
scripts/deploy.sh all            # build, copy, install, restart (add --config to push deploy/units/*.conf)
```

`provision.sh` creates the `rtk` service user (groups `dialout`, `spi`, `gpio`),
`/etc/rtk/rtk.conf` (only if missing), `/var/lib/rtk`, `rtkd.service` and the
keypad power-off path unit, and disables the previous Python service and any
serial getty on the receiver's port.

## Daily development loop

| Script | What it does |
|---|---|
| `scripts/build.sh [test]` | static `aarch64-linux-musl` binary (`test` runs the unit tests first) |
| `scripts/deploy.sh rtk1\|rtk2\|all [--config] [--no-restart]` | build, copy (rsync if present, else scp), install, restart |
| `scripts/logs.sh rtk1\|rtk2` | `journalctl -u rtkd -f` |
| `scripts/gnss-tap.sh rtk1\|rtk2 [secs]` | stop `rtkd`, capture the raw receiver stream to `captures/`, restart `rtkd` |
| `scripts/gnss-cmd.py` / `gnss-probe.py` | copy to a Pi and send raw commands / probe bauds (stop `rtkd` first) |
| `scripts/e2e-sim.sh` | full base+rover test on this machine with simulated receivers |
| `zig build test` | unit tests (host) |
| `rtkd selftest` (on a Pi, service stopped) | UART, receiver, OLED, keys |
| `rtkd screens` | render every OLED page to the terminal |

`unit_host` prefers the USB gadget address (`ssh rtk1`) when it answers and falls
back to Wi-Fi (`ssh rtk1w`).

## Configuration

`/etc/rtk/rtk.conf`, INI. Errors name the line and show on the OLED. See
`deploy/units/*.conf` for working examples.

| Section.key | Default | Meaning |
|---|---|---|
| `unit.role` | (required) | `base` or `rover` |
| `unit.name` | `RTK` | up to 16 chars; shown on screen, used in file names and the beacon |
| `gnss.device` / `gnss.baud` | `/dev/serial0` / 115200 | receiver port |
| `caster.host` | `auto` | rover: `auto` (find the base by beacon) or an IPv4 address |
| `caster.port` / `caster.mount` | 2101 / `BASE` | base listens here; rover requests this mount (ignored in `auto`, the beacon names it) |
| `caster.user` / `caster.password` | empty | Basic auth; base enforces it when `user` is set |
| `caster.beacon_port` | 2102 | UDP discovery |
| `base.mode` | `auto` | `auto` reuse stored position else survey in; `survey_in`; `fixed` |
| `base.survey_secs` / `base.survey_acc_m` | 900 / 3.0 | survey-in minimum duration and 3D accuracy limit |
| `base.fixed` | | `lat, lon, ellipsoidal_height` for `mode = fixed` |
| `base.rtcm_msm` | 7 | 4 or 7 |
| `survey.pole_height_m` | 2.000 | antenna height above the ground mark |
| `survey.min_epochs` | 15 | epochs averaged per point (about 15 s at 1 Hz) |
| `survey.require_fixed` | yes | refuse RTK float |
| `survey.max_hacc_m` | 0.050 | epochs with a larger error estimate are skipped |
| `survey.codes` | `PT,COR,EP,FNC,BLD,TRE,UTL,PIN` | feature codes (joystick up/down) |
| `log.dir` | `/var/lib/rtk` | `raw/`, `survey/`, `base.pos` |
| `log.raw_rotate_mb` / `log.raw_keep` | 8 / 6 | raw stream rotation |
| `ui.http_port` | 8080 | `0` turns the web page off |
| `ui.rotate_180` / `ui.contrast` / `ui.sleep_secs` | yes / 127 / 120 | display |

`rtkd --config PATH check` validates a file.
