# Pi RTK Surveyor

A two-unit RTK surveying station on Raspberry Pi Zero 2 W: a **base** and a
**rover**, each a Waveshare LC29H GPS/RTK HAT plus a Waveshare 1.3" OLED HAT. The base
streams RTCM3 corrections over Wi-Fi using standard NTRIP; the rover applies them,
and an operator walks a site marking points with the keypad (or a phone) to get
centimetre-level coordinates, a CSV, and a drawn topographic sheet.

It is a **hobby system**: aim for survey practice you could defend, but do not use
the output for permits or boundary decisions.

One static binary, `rtkd` (Zig 0.16, `aarch64-linux-musl`, no runtime, 494 KB stripped),
runs on both units; the role comes from `/etc/rtk/rtk.conf`.

## Status

Verified on the two real units (rtk1 = rover/LC29H-DA, rtk2 = base/LC29H-BS) and by
the test suites. Indoors the units cannot get a fix, so those paths were first verified against
a simulated receiver; on 2026-10-02 both units were then run **outdoors under sky** (between two
concrete buildings, antennas a few metres apart) and the whole chain worked.

| Capability | How it is verified |
|---|---|
| Receiver bring-up, idempotent config (restart never restarts a survey) | on hardware: restart writes 0 settings; read-back of survey-in, fixed-position, RTCM and NMEA settings from the live BS |
| NMEA / RTCM3 framing, CRC24Q, resync | unit tests on real captures from both HATs (48 clean frames, 0 bad) |
| Base caster, discovery beacon, rover link, reconnect | on hardware over Wi-Fi (base restart recovered live); loopback tests; sustained 6 frames/s, 0 loss |
| OLED (SH1106), 8 keys, UART | `rtkd selftest` on both units; screens reviewed with `rtkd screens`. **Not yet confirmed by eye** that the panel shows the picture and rotation correctly |
| Point occupation, CSV, jobs, base position store | unit tests + simulated end-to-end (below) |
| RTK fix, survey-in completion, point capture | **on hardware, outdoors:** rover went float to RTK FIX (5 mm estimated error, 29 satellites) through the real corrections link; the base survey-in completed and stored its position; two points marked on the same spot agreed to 9 mm horizontally and vertically. Absolute accuracy and open-field performance not yet measured |
| Web status/downloads, phone MARK | tests + on hardware (status pages); MARK via the simulator |
| Keypad power-off (K1+K3) | logic and unit files verified; **not triggered** on hardware |
| Topo sheet and exports (PNG/PDF/SVG, DXF, ArchiCAD XYZ, OBJ, PNEZD, interactive HTML) | unit tests, plus a full simulated site (`examples/`); the in-browser viewer is tested with Node (geometry) and headless Chromium (rendering). **ArchiCAD import itself not tested** (no ArchiCAD here) |
| Live map at `/map` on the unit | served by `rtkd` and tested; **not yet deployed to the units** |

Run the whole simulated system with `scripts/e2e-sim.sh` (38 checks: survey-in,
discovery, RTK via the real corrections path, three marked points to a few mm,
corrections loss and recovery, restarts, web safety).

## Quick start

```sh
scripts/provision.sh rtk1 && scripts/provision.sh rtk2   # once
scripts/deploy.sh all --config                           # build, install, restart
scripts/logs.sh rtk1                                     # follow the journal
```

Open `http://rtk1.local:8080/` on a phone. Everything else is in:

* [docs/setup.md](docs/setup.md): card preparation, install, config reference, dev loop
* [docs/workflow.md](docs/workflow.md): screens, keys, marking a point, data formats
* [docs/field-guide.md](docs/field-guide.md): day-of checklist (order of operations), QC practice, limitations
* [docs/bom.md](docs/bom.md): hardware-store bill of materials, build steps, Wi-Fi options for the field
* [docs/hardware.md](docs/hardware.md): variants, UART, schematic findings, command set

## How it works

```
 LC29H (BS) ──UART── rtkd(base) ──NTRIP :2101──Wi-Fi──► rtkd(rover) ──UART── LC29H (DA)
   RTCM3+NMEA         │  caster + UDP beacon :2102          │  link client             NMEA
                      ├─ OLED / keys / web :8080            ├─ OLED / keys / web :8080
                      └─ raw log, base.pos                  └─ raw log, job CSV
```

One thread, one `epoll` loop. The receiver's byte stream is split into NMEA and
CRC-checked RTCM3; only valid frames are ever forwarded. Standard NTRIP means RTKLIB
`str2str`, SW Maps or a public caster can stand in for either side.

Design points that came from the hardware (see docs/hardware.md): the base must be a BS
variant and `rtkd` refuses the wrong HAT with a readable error; the DA has no GST so
accuracy comes from `PQTMEPE`; the HAT has no reset line; the base broadcasts a
placeholder North Pole position until it has surveyed in.

## Layout

```
src/            rtkd (Zig): nmea rtcm demux geo lc29h ntrip net survey ui fb oled input gpio
                uart sys config rawlog basepos sysinfo http app, plus fixtures/ from real captures
                and viewer.html (the plan + 3D map, served at /map and exported by topo.py)
scripts/        build deploy logs gnss-tap provision add-wifi e2e-sim (+ gnss-cmd/probe for the Pi)
deploy/         systemd units, per-unit configs
tools/          gnss-sim (simulated LC29H), e2e_sim, sim_survey, topo (maps), genfont
examples/       a simulated-site job and its drawn sheet
docs/           setup, workflow, field guide, hardware
```

## Footprint

Measured on the units (ReleaseSafe, stripped): **494 KB** binary, **~550 kB RSS**, one thread.
With real satellites in view CPU is about **1.1% (rover) to 1.4% (base) of one core**; the base sends
~835 B/s of corrections (6 frames/s) and its receiver UART runs at about a fifth of capacity. SoC
temperature was 49-52 C outdoors in the afternoon with no throttling and no under-voltage. Other modes, same source:
ReleaseFast 413 KB, ReleaseSmall 220 KB. The deploy build is ReleaseSafe on purpose: the daemon
is I/O bound, so the safety checks (bounds, overflow) cost nothing measurable, and a bug becomes a
panic and a 3-second systemd restart rather than silently wrong survey data.

## Development

```sh
zig build test                 # 85 unit tests, host-native, uses real receiver captures
python3 -m unittest tools/test_topo.py
node tools/test_viewer.js      # geometry of the in-browser map: Delaunay TIN, contours
scripts/e2e-sim.sh             # full base+rover system on this machine, no hardware
tools/sim_survey.py            # survey a synthetic site through the real stack, then draw it
```

Zig is at `/home/hotschmoe/tools/zig-aarch64-linux-0.16.0/zig` (override with `$ZIG`).
Never run unit tests or the simulator against `/dev/serial0` on a unit: stop the
service first (`scripts/gnss-tap.sh` does).

## License

MIT, see LICENSE.
