# Field guide

## Day-of checklist: order of operations

**The night before** (at the office, on the same network the units already know)

1. Charge both power banks and the phone. Pack the kit (see docs/bom.md section F).
2. Teach both units the field network once: `scripts/add-wifi.sh all "YourHotspotOrRouterName"`
   (the password is typed at a prompt and goes only into the units' own NetworkManager
   profiles). Skip if you will use the office network.
3. Look at both screens: rover shows `NO FIX` indoors and `LINK OK RTK2`, base shows `NO SKY`.
   That means both are healthy, and indoors it is as good as it gets.
4. Check `survey.pole_height_m` on the rover matches the pole you will carry.

**At the site**

1. **Network first.** Turn on the phone hotspot (2.4 GHz) or the travel router, and put it near
   the middle of the site.
2. **Base: choose the spot.** Open sky, stable ground, near the centre of the site, away from
   walls, trees, parked vehicles and metal. Drive a nail or stake as the base mark, set the
   tripod over it (plumb bob), spread and tread the legs in, hang the sandbag.
3. **Base: antenna and power.** Screw the antenna on, connect the cable to the HAT, plug in the
   power bank. Write down in your notebook: base mark, antenna height above the mark, time, weather.
4. **Base: wait for BASE READY.** The screen goes through the bring-up list, then `NO SKY` until it
   sees satellites, then `SURVEYING` with a progress bar (default 15 minutes, `base.survey_secs`;
   it also needs the accuracy limit met), then `BASE READY` in inverted type. Do not touch the tripod.
   Use the time to set up the rover and walk the site. The base stores this position; every later
   power-up on the same monument reuses it.
5. **Rover: power on** (any time, before or after the base is ready). Wait for `LINK OK RTK2` on
   STATUS. If it says `searching for base` for more than a minute: check both units are on the
   same Wi-Fi (SYSTEM page shows each unit's IP and signal), then see "Known limitations" below.
6. **Rover: wait for RTK FIX** (the fix label turns solid/inverted; estimated error shows in cm).
   `RTK FLT` (float) is normal for a minute or two. Marking is refused until it is a fix.
7. **Survey.** Walk to the first point. Plumb the pole on the bubble. Pick the feature code
   (joystick up/down on the POINTS page). Press **K3** (or the joystick). Hold still until
   `SAVED 001`. Repeat. (From the phone: the web page has the same MARK button.)
8. **Check shots.** Re-occupy 2-3 earlier points near the end and compare. Over about 3 cm means
   something went wrong; see below.
9. **Finish.** On the rover and then the base, hold **K1 + K3 for 3 seconds**: the screen says
   `POWERING OFF`; wait 15 seconds, then unplug. (Do not just pull the plug: the SD card can corrupt.)
10. **Get the data.** Before shutting down, or later with the units on any network, open
    `http://<rover-ip>:8080/` on the phone and download the job CSV (and GeoJSON). The base's raw
    log (for post-processing) is on the base's web page. Then at home:
    `tools/topo.py JOB1.csv --title "Back field" --out back-field`.

**If something goes wrong**

| You see | Meaning | Do |
|---|---|---|
| `E01 RECEIVER` | wrong HAT for the role | fit the BS HAT on the base, the DA HAT on the rover |
| rover `NO FIX` outdoors | antenna cable, antenna view, or the receiver has no almanac yet | check the U.FL plug; give it 5 minutes; check sky view |
| rover stuck on `RTK FLT` | corrections arrive but ambiguities are not fixed | wait; move away from trees/walls; check baseline and that the base is READY |
| `LINK backoff: ...` | the link is retrying; the text says why | `mountpoint not found`: name mismatch; `connect timeout`: base off or on another network |
| `POWER LOW NOW` | the supply is sagging | fresh bank, shorter/thicker cable |
| `CANNOT MARK  NO RTK FIX` | refusing a float/single point | wait for RTK FIX (or set `survey.require_fixed = no` if you accept float) |
| base `K3 AGAIN: DISCARD+RESURVEY` | you pressed K3 | press K3 again within 4 s only if you moved the base to a new monument |


The goal is survey practice you could defend, with hobby-grade equipment. This
is a **hobby system: do not use its output for permits or boundary decisions**.
The practice below is what makes the numbers as trustworthy as the hardware
allows, and what a licensed surveyor would check first.

## What accuracy to expect

Dual-band L1/L5 RTK with a short baseline and a good antenna is typically
centimetre-level horizontally (a few cm) and about twice that vertically. That
needs: open sky, a rigid base antenna mount over a fixed monument, corrections
arriving every second, and a plumb, steady pole. Nothing in software can fix a
bad antenna site; multipath near walls, trees and metal is the main error.

Absolute coordinates are only as good as the base position (a survey-in is
metre-class, see below). **Relative** accuracy between your points is
centimetre-class regardless, because the base error is common to all of them.

## Setting up the base

1. Mount the antenna rigidly with a clear view of the sky, as high and as far
   from reflecting surfaces as practical. Mark the ground point beneath it.
2. Power the base. Wait for `BASE READY` (default 15 min). A longer
   `base.survey_secs` improves the absolute position.
3. Leave it alone. If you move the base to a different monument, press K3 twice.
4. For a position you know better (a published benchmark, or a PPP result from
   the raw log), set `base.mode = fixed` and `base.fixed = lat, lon, h` (ellipsoidal).

## Surveying

* Check the pole height setting (`survey.pole_height_m`) matches the pole. Elevation
  in the CSV is the **ground** mark: antenna elevation minus pole height.
* Walk to the point, plumb the pole (bubble level), wait for RTK FIX, mark.
  Keep the pole still for the whole occupation (about 15 s).
* Use the feature codes. A consistent code vocabulary is what makes a drawing
  usable later.
* **Check shots.** Re-occupy 2-3 earlier points at the end of a session and
  compare: differences above ~3 cm mean something went wrong (pole not plumb, a
  bad fix, base disturbed). Take the shots from a different time of day if possible.
* **Close the loop** on any traverse back to the start.
* **Duplicate a few points across base moves.** When the base moves to a new
  monument, re-survey 5-10 points from the previous section (see
  `docs/thoughts.md`, multi-section strategy) and compare.
* Watch the baseline (LINK page): RTK accuracy degrades with distance, roughly
  1 cm per 10 km on top of the fixed error, and Wi-Fi range limits you first.

## Reading the numbers

* `Accuracy_H` / `Accuracy_V` are the receiver's error estimate averaged over the
  occupation, but never less than the measured scatter (`SD_H` / `SD_V`).
* `Fix_Type` should be `RTK_FIXED` for everything you intend to use.
* `Epochs`, `Corr_Age` and `Baseline_m` let you screen points after the fact.
* `Elevation` is orthometric (MSL via the receiver's geoid model) of the ground;
  `Ellipsoid_H` is the ellipsoidal height of the ground.

## After the survey

```sh
tools/topo.py survey/JOB1.csv --title "Back field" --out back-field   # DXF + SVG + PNEZD
```

See the script's `--help`. Outputs a CAD-importable DXF with layered points,
labels, contours, a north arrow, scale bar and title block; an SVG preview; and
a PNEZD CSV in UTM metres.

## Known limitations

* Without sky there is no fix: indoors the units come up, link and log, but the
  position stays empty. This is the state in which the bench tests ran.
* The receiver's absolute position after a short survey-in is metre-class.
* Wi-Fi range is the real limit on baseline length (hundreds of metres); the
  protocol itself would work over any IP link, including a public caster.
* The rover cannot resolve `.local` names; use `caster.host = auto` (beacon) or
  an IPv4 address. The beacon needs UDP broadcast to pass between the units
  (some access points isolate clients; then give the base's address explicitly).
