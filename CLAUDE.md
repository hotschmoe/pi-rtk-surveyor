# CLAUDE.md

Guidance for Claude Code (claude.ai/code) in this repository.

## What this is

Pi RTK Surveyor: two Raspberry Pi Zero 2 W units (a base and a rover), each with a Waveshare LC29H
GPS/RTK HAT and a Waveshare 1.3" OLED HAT, doing RTK surveying. The Python prototype was replaced
by a Zig daemon, `rtkd` (rewrite branch `rewrite/zig-rtkd`). See README.md first, then docs/.

## Commands

```sh
zig build test                           # unit tests, host-native (the dev box is aarch64 too)
scripts/build.sh [test]                  # static aarch64-linux-musl binary -> zig-out/bin/rtkd
scripts/deploy.sh rtk1|rtk2|all [--config]
scripts/logs.sh rtk1|rtk2
scripts/gnss-tap.sh rtk1|rtk2 [secs]     # raw receiver capture (stops rtkd, restarts it)
scripts/provision.sh rtk1|rtk2           # once per unit
scripts/e2e-sim.sh                       # full system on this machine with simulated receivers
python3 -m unittest tools/test_topo.py
node tools/test_viewer.js
node tools/test_wasm.js                  # wasm core vs JS reference + speed table
scripts/build-wasm.sh                    # rebuild src/map.wasm from src/geom (commit it)
```

Zig 0.16 at `/home/hotschmoe/tools/zig-aarch64-linux-0.16.0/zig` (or `$ZIG`). Build target for the Pis is
`aarch64-linux-musl`. `rtkd selftest`, `rtkd screens`, `rtkd check` are subcommands.

## Access

`ssh rtk1w` / `ssh rtk2w` (Wi-Fi, mDNS rtk1.local / rtk2.local), `ssh rtk1` / `ssh rtk2` (USB gadget,
when the cable is data-capable). rtk1 = rover (LC29H DA), rtk2 = base (LC29H BS). The service is `rtkd`.

## Architecture (src/)

One thread, one epoll loop (`app.zig`); no libc, no std.Io: raw syscalls through `sys.zig`.

* `nmea.zig` `rtcm.zig` `demux.zig`: pure framing, checksums, CRC24Q, resync. Tested on `src/fixtures/*.raw`
  (real captures; marked binary in .gitattributes).
* `lc29h.zig`: receiver bring-up as a pure state machine, idempotent read-compare-write. Do not make it
  write unconditionally: rewriting the base's survey-in config restarts the survey.
* `net.zig` `ntrip.zig`: caster (base), UDP beacon discovery, rover link with backoff. Pure protocol in ntrip.zig.
* `survey.zig` `geo.zig` `basepos.zig`: point occupation (gated epoch averaging), CSV/job file, stored base position.
* `ui.zig` `fb.zig` `oled.zig` `input.zig` `gpio.zig`: pure screens over a `View`, SH1106 over SPI, GPIO uAPI v2 keys.
* `http.zig` `page.html` `viewer.html` `map.wasm`: status page, downloads, POST-only actions, and `/map` (plan + 3D
  viewer) plus `/map.wasm`. The viewer's compute (TIN, contours, 3D prep) is Zig in `src/geom/` compiled to
  wasm32-freestanding; the committed `src/map.wasm` is embedded in rtkd and the Pi only serves bytes. After
  editing `src/geom` run `scripts/build-wasm.sh` and commit `map.wasm` + `map.wasm.sha256` (`tools/test_wasm.js`
  fails when stale). `viewer.html` keeps the pure-JS geometry as the automatic fallback and as the test
  reference (its geometry block is tested by `tools/test_viewer.js`; `tools/test_wasm.js` cross-checks wasm
  against it). `tools/topo.py` inlines data and the base64 wasm into one offline file. Replies go through a
  96 KB buffer, so html and wasm must each stay under ~90 KB (comptime-asserted). Decision on WebGPU: no, see
  docs/map-compute.md.

Zig idioms in use: comptime tables (CRC-24Q, config keys reflected over `Config`, NMEA/PQTM dispatch via
`StaticStringMap`, command strings via `comptimePrint`), `inline for`, comptime size assertions on kernel ABI
structs, duck-typed sinks (`anytype`) instead of vtables. **Never put large buffers in a struct that has a
default initialiser** (`.{}` / `= .{}` array-of-structs): Zig emits the whole thing as a constant in the binary
and copies it at start-up. Keep big buffers in separate `var x: [N]T = undefined;` globals and reference them
by slice (see `caster_out` in net.zig, `http_out` in http.zig; this cut the binary from 1.07 MB to 494 KB).
Build options: release builds are stripped, single-threaded, no error tracing, `simple_panic`, no segfault
handler (a stripped binary cannot symbolise traces anyway).

Rules that matter: only CRC-valid RTCM frames are forwarded to a receiver; the UI never swallows a key
press; a point is fsynced before the screen says SAVED; accuracy is never reported better than the measured
scatter; log lines go through `log.zig` (journald priority prefixes); tests keep logging quiet.

## Hardware facts (verified, docs/hardware.md)

* UART `/dev/serial0` 115200. Base HAT must be LC29H(BS); DA cannot be a base. DA has no GST (use PQTMEPE).
* LC29H HAT: PPS = GPIO18, WAKEUP = GPIO4, WI/RES = GPIO27, no reset GPIO. OLED HAT: SPI0 CE0, DC=24, RST=25,
  keys 21/20/16, joystick 6/19/5/26/13 (BCM numbers).
* Before survey-in the BS broadcasts a placeholder 1005 position at the North Pole.
* No fix is possible indoors; use `tools/gnss-sim.py` for anything that needs a position.

## Conventions

* Commit on the branch; do not push or open PRs without asking.
* Never write to the dev box's own nvme0n1. A USB SD reader reports the same serial for every card: identify a
  card by `/etc/hostname` on its root partition.
* The Wi-Fi password lives only in the cards' NetworkManager profiles; never copy it into the repo.
* Prefer editing the existing modules over adding new ones; keep functions pure where the hardware allows.
