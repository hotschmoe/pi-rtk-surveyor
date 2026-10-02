# Operator workflow

The interface follows a few fixed rules, in the manner of an operator console:
one fact per line, units always shown, the bottom row always tells you what
K1, K2 and K3 do on the current page, **inverted means good/locked**, and every
error has a code, a plain statement and a remedy. Rendered examples of every
screen come from `rtkd screens`.

```
Power on -> splash/bring-up checklist -> status page
             (receiver found, settings confirmed, link searching)
```

Roles are fixed per unit in `/etc/rtk/rtk.conf` (rtk2 = base, rtk1 = rover). There
is no boot menu to get wrong in the field.

## Keys

| Key | Rover | Base |
|---|---|---|
| **K1** / joystick right | next page | next page |
| joystick left | previous page | previous page |
| **K3** / joystick press | **MARK** a point (start an occupation); during one: **ACCEPT** early (needs 3 epochs) | **RESURVEY**: press twice within 4 s to discard the stored base position |
| **K2** | during an occupation: **CANCEL**; on the POINTS page: **NEWJOB** | |
| joystick up/down | on the POINTS page: feature code | |
| **K1 + K3 held 3 s** | clean power off | clean power off |
| any key while the display is asleep | wakes it (and does nothing else) | |

A message ("toast") never swallows a key press: the key dismisses it and acts as usual.
The display blanks after `ui.sleep_secs` (120 s) of no input, unless an
occupation is running or an error is showing.

## Pages

Page dots at the right of the header show where you are (filled = current).

**Rover:** STATUS (fix state in large type, inverted when RTK FIX; satellites used/in
view, HDOP, estimated H/V error, link state), POSITION (lat/lon to 1e-9 degree,
MSL elevation, ground elevation after pole height, UTC), LINK (base name, address,
RTCM rate, last correction age, baseline length, the base's satellite count per
constellation), POINTS (job, count, next ID, feature code, last point), SYSTEM
(CPU temperature, load, memory, uptime, address, Wi-Fi level, **power**).

**Base:** STATUS (`NO SKY` / `SURVEYING` with progress bar and accuracy / `BASE READY`
inverted), BASE POSITION (lat/lon/height and ECEF), CASTER (port, mount, rovers
streaming, RTCM rate), SYSTEM.

The SYSTEM page doubles as the battery monitor: the Pi's under-voltage flag is
shown as `POWER LOW NOW - CHECK BATT` in reverse video. (A bare Pi cannot measure
battery percentage; the supply sagging is the honest signal.)

## Marking a point

1. Wait for **RTK FIX** (inverted). Float is refused by default (`survey.require_fixed`).
2. Choose the feature code on the POINTS page (joystick up/down).
3. Hold the pole plumb and still. Press **K3** (or the joystick). The screen shows
   progress, epoch count and the scatter of the epochs so far.
4. After `survey.min_epochs` (15) qualifying epochs it saves and shows
   `SAVED 013  COR`, the error estimate, epoch count, scatter and baseline.

What happens to epochs: each one must be RTK fixed, have corrections no older
than 30 s and an error estimate below `survey.max_hacc_m`. A bad epoch is skipped;
five bad epochs in a row restart the average, so one point never mixes good and
bad solutions. The stored position is the mean in a local east/north/up frame;
the stored accuracy is the receiver's own estimate, but **never better than the
measured scatter of that occupation**.

The point is written (and `fsync`ed) before the screen says SAVED. If the write
fails the screen says `SAVE FAILED ... Point NOT stored!` for 8 seconds and the log
has the reason.

From a phone: the web page has the same MARK / Accept / Cancel / Next-code buttons.

## Base station

* First power-up on a monument: `SURVEYING` until `base.survey_secs` have elapsed with
  the accuracy under `base.survey_acc_m`, then `BASE READY`. The result is stored in
  `/var/lib/rtk/base.pos`.
* Every later power-up reuses the stored coordinates (`STORED POSITION`), so all
  points surveyed from that monument, on any day, share one reference. Move the
  base to a new monument and press **K3 twice** to discard the old position and
  survey in again.
* Restarting `rtkd` never restarts a running survey: the receiver's configuration
  is read first and written only if different.

## Data

* `survey/JOB<n>.csv`, one file per job, one row per point; new jobs on the POINTS
  page (K2) or `POST /api/newjob`. The first eight columns are the original
  project schema: `Point_ID,Timestamp,Latitude,Longitude,Elevation,Accuracy_H,
  Accuracy_V,Fix_Type`; then `Code,Epochs,SD_H,SD_V,HDOP,Sats,Corr_Age,Baseline_m,
  Ellipsoid_H,Antenna_H,Base_ID`.
* `raw/<name>-NNNNNN.bin`, the receiver byte stream as received, rotated (default
  8 MB x 6). On the base this is the reference data for post-processing in RTKLIB.
* GeoJSON and downloads from the web page: `http://<unit>:8080/`; a live plan/3D map at `http://<unit>:8080/map`.
* `tools/topo.py` turns a job CSV into PNG/PDF/SVG sheets, an interactive HTML viewer, DXF, OBJ, and the XYZ file for ArchiCAD (see `docs/field-guide.md`).
