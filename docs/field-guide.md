# Field guide

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
