# Hardware facts

Everything here was measured on the two units (2026-10-03) or read from the
Waveshare / Quectel documents named. Nothing is assumed from the old code.

## The two units

| Unit | Role  | Receiver (`PQTMVERNO`)               | Firmware date |
|------|-------|--------------------------------------|---------------|
| rtk1 | rover | `LC29HDANR11A03S_RSA` (LC29H **DA**) | 2024/03/19    |
| rtk2 | base  | `LC29HBSNR11A01S` (LC29H **BS**)     | 2023/02/13    |

* **The base must be a BS.** A DA cannot output RTCM3 as a base. `rtkd` checks
  the version string at start-up and, on the wrong HAT, refuses to run and shows
  `E01 RECEIVER` with the remedy on the OLED.
* The DA's NMEA output is limited by the firmware to GGA, GLL, GSA, GSV, RMC and
  VTG (`$PAIR062` types 0-5, rate 0 or 1). There is **no GST**, so there is no
  standard accuracy sentence. The rover instead enables Quectel's `$PQTMEPE`
  (estimated position error) with `$PQTMCFGMSGRATE,W,PQTMEPE,1,2`.

### Why rtk2 "printed no NMEA" in a 4 s read

It was not broken. The BS had been left configured as a base: NMEA output off
(`$PAIR063,0` rate 0), RTCM3 on (MSM4 plus the 1005 station message), survey-in
mode with a 43200 s / 15 m limit. The bytes on the wire were RTCM3 frames, which
a text-oriented reader shows as nothing. `rtkd` handles both on one stream.

Before it has a position, a BS broadcasts a **placeholder 1005 position at the
North Pole** (X = 0.1173 m, Y = 0, Z = 6,356,902.3142 m). The rover recognises
this (`rtcm.Station.plausible`) and shows "no base position".

## UART

* `/dev/serial0` -> `ttyAMA0` (PL011), GPIO14/15, **115200 8N1**. Both cards have
  `enable_uart=1`, `dtoverlay=disable-bt` and no serial console on the header.
* There is only one usable UART on the Zero 2 W header, and the HAT needs it; the
  header console is therefore gone on a stacked unit. Console access is the USB
  gadget serial port (`/dev/ttyACM*` on the dev box).
* The HAT has a yellow jumper (J1 on the schematic) choosing the module's
  UART: header or the on-board CP2102N USB-serial. It must be on the **header**
  position for `rtkd` (this is how both units are set).

## HAT schematic findings (LC29H(XX) GPS/RTK HAT, Waveshare, 4-page schematic)

Read from the schematic's module block (U3) and the Raspberry Pi header block (P2):

| Module pin      | Net on the HAT                | Raspberry Pi header |
|-----------------|-------------------------------|---------------------|
| TIMEPULSE (PPS) | via R23 0R, also drives LED PPS1 | **GPIO18** (pin 12) |
| WAKEUP          | via R19 0R                    | **GPIO4** (pin 7)   |
| WI/RES (pin 17) | via R20 0R                    | **GPIO27** (pin 13) |
| RESET_N         | only the on-board button K1 (pulled up 10k) | **not wired to a GPIO** |
| FWD/RES, WHEELTICK | via R22/R18 to a jumper area that is greyed out (DNP): P20/P21 pads | not populated |
| TXD1 / RXD1     | via the J1 jumper to H_TXD/H_RXD | GPIO14 / GPIO15 |
| SDA / SCL       | level-shifted (NDC7002N)      | GPIO2 / GPIO3       |

Consequences:

* **PPS is on GPIO18, WAKEUP on GPIO4, WI/RES on GPIO27.** None collide with the
  OLED HAT (SPI0 + GPIO24, 25, 21, 20, 16, 6, 19, 5, 26, 13).
* **There is no software reset line.** A receiver that wedges can only be reset
  by command (`$PAIR004` hot start / `$PAIR003` power-off) or by the HAT's own
  button. `rtkd` re-probes a receiver that goes silent for 5 s.
* The unpopulated wheel-tick jumper area would route onto GPIO20/21 (OLED HAT
  keys). Do not populate it.
* The ML1220 backup cell (V_BCKP) keeps ephemeris, so hot starts are quick.
* PPS is not used by `rtkd` yet. With sky it would allow timestamp discipline.

Source: `https://files.waveshare.com/wiki/LC29H(XX)-GPS-RTK-HAT/LC29H(XX)_GPS_RTK_HAT_Sch.pdf`

## OLED HAT (Waveshare 1.3", SH1106)

* SPI0 CE0 (`/dev/spidev0.0`), D/C = GPIO24, RST = GPIO25. 128x64, RAM is 132
  columns wide and the visible window starts at column 2.
* Orientation follows the earlier finding (luma `rotate=2`): standard A1/C8 scan
  setup and a 180 degree rotation of the image in software (`ui.rotate_180`).
* Keys KEY1/2/3 = GPIO 21/20/16. Joystick up/down/left/right/press =
  GPIO 6/19/5/26/13. All active low; on the idle units every line reads high.

## Kernel / OS

Raspberry Pi OS Bookworm 64-bit, kernel 6.12. `/dev/gpiochip0` is the BCM2835
chip with 54 lines (`gpiochip4` is a compatibility symlink). Users in the `gpio`,
`spi` and `dialout` groups can open the devices; the service user `rtk` is in
all three. The under-voltage flag is exposed as hwmon `rpi_volt` /
`in0_lcrit_alarm` (the older `get_throttled` sysfs file does not exist here).

## Receiver commands used

Verified against the live modules (reply formats are what `src/lc29h.zig` expects):

| Purpose | Command | Reply |
|---|---|---|
| Identify | `$PQTMVERNO` | `$PQTMVERNO,<variant>,<date>,<time>` |
| Rover mode | `$PQTMCFGRCVRMODE,R` / `,W,1` | `...,OK,1` |
| Base survey-in | `$PQTMCFGSVIN,W,1,<secs>,<acc_m>,0,0,0` | `...,OK` ; read back `OK,1,<secs>,<acc>,0.0000,0.0000,0.0000` |
| Base fixed ECEF | `$PQTMCFGSVIN,W,2,0,0,<x>,<y>,<z>` | read back `OK,2,0,0.0,<x>,<y>,<z>` (4 decimals) |
| Survey status | `$PQTMCFGMSGRATE,W,PQTMSVINSTATUS,1,1` | `$PQTMSVINSTATUS,1,,<valid>,,00,<obs>,<cfg>,<x>,<y>,<z>,<acc>` |
| Error estimate | `$PQTMCFGMSGRATE,W,PQTMEPE,1,2` | `$PQTMEPE,2,<n>,<e>,<d>,<2d>,<3d>` |
| NMEA rates | `$PAIR062,<type>,<rate>` / `$PAIR063,<type>` | `$PAIR001,062,0` / `$PAIR063,<type>,<rate>` |
| RTCM output | `$PAIR432,<0=MSM4,1=MSM7>` (`433` reads) | `$PAIR001,432,0` |
| Station position (1005) | `$PAIR434,1` (`435` reads) | |
| Ephemeris messages | `$PAIR436,0` (`437` reads) | |

The module's survey status field order (version, TOW, valid, _, _, observed s,
configured s, X, Y, Z, accuracy) is inferred from output captured before any
satellites were tracked; the `valid` states 0/1/2 (idle/in progress/complete) and
the field positions will be confirmed the first time a survey runs under sky.
