# Pi RTK Surveyor

A two-unit RTK surveying station on Raspberry Pi Zero 2 W: a **base** and a
**rover**, each a Waveshare LC29H GPS/RTK HAT plus a Waveshare 1.3" OLED HAT. The base
streams RTCM3 corrections over Wi-Fi using standard NTRIP; the rover applies them,
and an operator walks a site marking points with the keypad (or a phone) to get
centimetre-level coordinates, a CSV, and a drawn topographic sheet.

It is a **hobby system**: aim for survey practice you could defend, but do not use
the output for permits or boundary decisions.

One static binary, `rtkd` (Zig 0.16, `aarch64-linux-musl`, no runtime, ~3.8 MB),
runs on both units; the role comes from `/etc/rtk/rtk.conf`.

## Status

Verified on the two real units (rtk1 = rover/LC29H-DA, rtk2 = base/LC29H-BS) and by
the test suites. The units cannot get a fix indoors, so everything that needs
satellites is verified against a simulated receiver, not sky.

| Capability | How it is verified |
|---|---|
| Receiver bring-up, idempotent config (restart never restarts a survey) | on hardware: restart writes 0 settings; read-back of survey-in, fixed-position, RTCM and NMEA settings from the live BS |
| NMEA / RTCM3 framing, CRC24Q, resync | unit tests on real captures from both HATs (48 clean frames, 0 bad) |
| Base caster, discovery beacon, rover link, reconnect | on hardware over Wi-Fi (base restart recovered live); loopback tests; sustained 6 frames/s, 0 loss |
| OLED (SH1106), 8 keys, UART | `rtkd selftest` on both units; screens reviewed with `rtkd screens`. **Not yet confirmed by eye** that the panel shows the picture and rotation correctly |
| Point occupation, CSV, jobs, base position store | unit tests + simulated end-to-end (below) |
| RTK fix, survey-in completion, accuracy | **simulated receiver only** (needs sky on hardware) |
| Web status/downloads, phone MARK | tests + on hardware (status pages); MARK via the simulator |
| Keypad power-off (K1+K3) | logic and unit files verified; **not triggered** on hardware |
| Topo sheet (DXF, PNG/SVG, PNEZD) | unit tests, plus a full simulated site (`examples/`) |

Run the whole simulated system with `scripts/e2e-sim.sh` (about 40 checks: survey-in,
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
* [docs/field-guide.md](docs/field-guide.md): setting up the base, QC practice, limitations
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
scripts/        build deploy logs gnss-tap provision e2e-sim (+ gnss-cmd/probe for the Pi)
deploy/         systemd units, per-unit configs
tools/          gnss-sim (simulated LC29H), e2e_sim, sim_survey, topo (maps), genfont
examples/       a simulated-site job and its drawn sheet
docs/           setup, workflow, field guide, hardware
```

## Development

```sh
zig build test                 # ~90 unit tests, host-native, uses real receiver captures
python3 -m unittest tools/test_topo.py
scripts/e2e-sim.sh             # full base+rover system on this machine, no hardware
tools/sim_survey.py            # survey a synthetic site through the real stack, then draw it
```

Zig is at `/home/hotschmoe/tools/zig-aarch64-linux-0.16.0/zig` (override with `$ZIG`).
Never run unit tests or the simulator against `/dev/serial0` on a unit: stop the
service first (`scripts/gnss-tap.sh` does).

## License

MIT, see LICENSE.
