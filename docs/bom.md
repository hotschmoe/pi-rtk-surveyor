# Bill of materials and build

Hardware-store (Home Depot / Ace) kit for one **base** and one **rover**, plus the few
parts that must come from elsewhere. Prices are rough US figures for planning; check
current prices and stock. Part names and search terms are given instead of SKUs, except
where a specific item was confirmed on the retailer's site (marked **confirmed**).

**Status: this is a design, not a tested build.** The software and the electronics are
tested (see README). The pole, mounts and bipod below have not been built or measured
yet; treat the first build as a prototype and run the check shots in the field guide.

## What you are building

```
   BASE                                  ROVER
   antenna (5/8"-11 thread)              antenna (5/8"-11 thread)
        |  on a tripod head                  |  on top of a 2 m pole
   [tripod, legs spread, antenna             |  round bubble level
    over a marked ground point]              |  Pi + HATs + battery strapped at chest height
   Pi + HATs + battery hung at the           |  rubber-tipped point on the ground mark
   tripod, screen readable                   (optional bipod for steadiness)
```

Standard survey antenna thread is **5/8"-11**; laser-level tripods use the same
thread, which is why a laser-level tripod makes a good base mount.

## Wireless: what you need on site

The two units talk over Wi-Fi (standard NTRIP over TCP, plus a UDP beacon so the rover
finds the base). **They need a shared Wi-Fi network; there is no radio link between
them by themselves.** Options, cheapest first:

| Option | Cost | Notes |
|---|---|---|
| **Phone hotspot** (2.4 GHz, "maximise compatibility" on iPhone) | free | Works now: run `scripts/add-wifi.sh all "YourHotspot"` once at the office so both Pis know it. Keep the phone near the middle of the site. If the rover stays on "searching for base" for more than a minute, the hotspot is probably isolating clients: use a router instead. |
| **Travel router** at the base (any small 2.4 GHz router, USB powered) | $25-40, not a hardware-store item | Most reliable, own SSID, you control range, no phone needed. Same `add-wifi.sh` once. |
| **Base as its own access point** | free | **Not built.** A Pi Zero 2 W has one radio, so the base would lose its office/ssh connection while hosting. Possible with NetworkManager; ask for it and it should be done with a cable attached so a mistake cannot strand a unit. |

Range: the Pi Zero 2 W has a small chip antenna, so plan on roughly **50-100 m** open
line of sight, less through trees and a plastic case. Put the base near the middle of
the site (the hotspot or router next to it) and keep the rover inside that circle.
The corrections stream is tiny (about 0.6 KB/s), so signal strength matters, not
bandwidth.

## A. Antennas and RF (order online; not at the hardware store)

One **dual-band L1+L5** active antenna per unit (the HAT's module is L1/L5). If your
HATs came as a kit with an antenna, start with that for the bench, but a proper
antenna on a ground plane matters most for centimetre work.

| Item | Qty | Approx. | Notes |
|---|---|---|---|
| L1/L5 (or L1/L2/L5) active GNSS antenna, **5/8"-11 thread base**, SMA or TNC | 2 | $40-150 each | Search "multi-band GNSS survey antenna 5/8-11", e.g. SparkFun SPK6618H (TNC, surveying), ArduSimple survey tripleband (TNC, thread or magnet), SparkFun L1/L2/L5 helical (SMA, small and light, fine for the rover). Waveshare lists a multi-band active antenna for this HAT. Check the antenna accepts 3.3-5 V bias: the HAT supplies it. |
| Cable: antenna connector to **U.FL / IPEX-1**, RG174 or similar, 1.5-3 m | 2 | $8-15 each | The HAT has a first-generation IPEX socket. Match the connector on the antenna (SMA or TNC) to U.FL. |
| 5/8"-11 magnetic mount (only if the antenna is magnet-type) | 0-2 | $15-30 | Optional |
| Steel plate 150 x 150 mm (6") for a magnet antenna's ground plane | 0-2 | $5 | Hardware store flat plate, or a steel cake pan lid. Not needed with a thread-mount survey antenna. |

Handle the U.FL plug gently: it is rated for a few mating cycles. Secure the cable
to the HAT standoff or the box with a zip tie so no pull ever reaches the connector.

## B. Power (you have the 10,000 mAh batteries)

| Item | Qty | Approx. | Notes |
|---|---|---|---|
| 10,000 mAh USB power bank (have) | 2 | | Output 5 V, at least 2 A. Estimate: the Pi Zero 2 W with both HATs and an active antenna draws about 0.4-0.5 A at 5 V (2-2.5 W), so 10,000 mAh (about 31 Wh usable after conversion) gives roughly **10-12 hours**. This is an estimate, not a measurement: do a full-battery test at the office once. |
| Short, thick micro-USB cable (20-22 AWG), 0.5-1 m | 2 | $6 | Into the **PWR IN** micro-USB port (outer one), not the OTG port. A thin or long cable causes under-voltage, which the SYSTEM page shows as `POWER LOW NOW`. |
| Check: bank does not auto-shut-off at low current | | | Some banks switch off below about 100-200 mA. The Pi is above that, but run the office test. |

## C. Base station kit (tripod, no building)

| Item | Qty | Approx. | Where | Notes |
|---|---|---|---|---|
| **Bosch BT170 aluminum laser-level tripod, 42-65 in., 5/8"-11 thread** | 1 | $60-110 | **Home Depot (confirmed)**; also BT160 (63 in.) or BT150 compact | Flat head with a 5/8"-11 male stud: the antenna threads straight on. A Johnson 40-6335 contractor tripod (5/8"-11) is an equivalent. |
| Plumb bob or a string with a nut and washer | 1 | $3 | HD/Ace | Hang from the tripod centre to set the antenna over a ground mark. |
| Ground marks: 6-8 in. nails or rebar stakes, flagging tape | 6+ | $6 | HD/Ace | Mark the base point and the tripod leg positions. |
| S-hook (small) | 1 | $2 | HD/Ace | Hang the battery/box bag from the tripod head hook or a leg. |
| Sandbag or a bag of gravel with a loop | 1 | $5-8 | HD/Ace | Hang low on the tripod in wind; a bumped base ruins the day. |
| Clear zip bag or small weather-resistant box, Velcro straps | 1 | $6 | HD/Ace | For the Pi stack and battery. See "Keeping it dry" below. |

## D. Rover pole (build it)

Target: a rigid, plumbable pole whose tip-to-antenna distance is a known number you set in
`survey.pole_height_m` (default 2.000 m).

| Item | Qty | Approx. | Where | Notes |
|---|---|---|---|---|
| 1 in. Schedule 40 PVC pipe, 10 ft | 1 | $10-14 | HD/Ace | Cut to about 2.0 m (78.7 in.). PVC is non-metallic, light, cheap, and easy to cap. (Upgrade path: aluminum or carbon tube.) |
| 1 in. PVC slip cap | 2 | $2 | HD/Ace | One for the top (antenna stud), one for the tip. |
| **5/8"-11 x 3 in. hex bolt**, 2 nuts, 2 washers (stainless or zinc) | 1 set | $3 | HD/Ace | Becomes the top stud the antenna screws onto. |
| 3/8"-16 x 4 in. hex or carriage bolt, nut, washer | 1 set | $2 | HD/Ace | Becomes the pointed tip. |
| 2-part epoxy (e.g. JB Weld, 5-minute) | 1 | $6 | HD/Ace | Seals the bolts and caps. |
| Round "bullseye" bubble level (circular vial) | 1 | $5 | HD levels aisle or online | Mount at chest height. |
| 2 stainless hose clamps (sized for 1 in. PVC OD 1.315 in.) | 2 | $4 | HD/Ace | Hold the bubble level and the Pi board. |
| Board for the electronics: 1/4 in. plywood or a 1x4, about 150 x 100 mm | 1 | $3 | HD/Ace | Pi stack and battery sit on it; the hose clamps hold the board to the pole. |
| Standoffs/M2.5 screws or Velcro for the Pi (the HAT stack's holes are M2.5) | 1 | $5 | HD/Ace | |
| Small rubber furniture tip for the pole tip (cover when walking) | 1 | $2 | HD/Ace | |

## E. Optional bipod (phase 2, untested design)

A handheld pole with a bubble level is workable for 15-second occupations. A bipod makes
the pole steadier and your hands free:

| Item | Qty | Approx. | Notes |
|---|---|---|---|
| 1x2 furring strips, 4 ft | 2 | $4 | The legs. |
| 3 in. zinc strap hinges | 2 | $6 | One per leg. |
| A 6 in. piece of 2x4, bored with a 1-1/16 in. spade bit to slide on the pole, with a wing-nut set screw | 1 | $3 | The collar. Screw the hinges to its sides; each leg screws to its hinge. |
| Rubber furniture tips | 2 | $3 | Leg feet. |

Collar at about chest height; splay the legs to roughly 45 degrees in a V behind the pole;
the pole tip and both feet form a stable tripod. Use the bubble level to plumb the pole.

## F. Field kit (consumables)

Tape measure (to measure pole and antenna heights), marker pens, pin flags or stakes for
site features, hammer, a notebook (record base mark, antenna height, date, weather,
anything odd), spare zip ties, Velcro straps, gloves, sunscreen for the operator and a
hat shade for the screen. A phone for the web page and the hotspot, with its own charger.

## Build steps

**Rover pole**

1. Cut the PVC to length: to start, 78.7 in. (2.000 m) minus the caps. Square the cut.
2. Top cap: drill a 5/8 in. (16 mm) hole in the centre, push the 5/8"-11 bolt through
   from the inside (head inside), add a washer and two nuts on the outside, tighten, and
   fill around it with epoxy. About 40 mm of thread must stand above the nuts for the
   antenna base to screw on.
3. Tip cap: drill 3/8 in., push the 3/8"-16 bolt through from the inside, nut and washer,
   epoxy. File the protruding end to a blunt point.
4. Epoxy both caps on and let them cure.
5. **Measure the pole height:** from the tip's point to the surface the antenna base
   seats on when threaded down fully (the antenna's reference plane; vendors call it the
   ARP, the bottom of the threaded mount). Write it down and set `survey.pole_height_m`
   in `/etc/rtk/rtk.conf` on the rover (then `scripts/deploy.sh rtk1 --config` or edit
   on the Pi). Re-measure whenever you change antenna or caps. If you want to be strict, add
   the antenna's phase-centre offset from its datasheet (a few centimetres); for hobby use
   the ARP height is fine and the offset is common to every point.
6. Hose-clamp the bubble level near chest height. Check it against a plumb bob once: hang a
   plumb bob next to the pole and adjust the vial so its bubble is centred when the pole is
   plumb. Shim with tape if it is off.
7. Fix the board to the pole with the two hose clamps, with the Pi stack mounted so the
   screen faces you and the keys are reachable, and the battery strapped behind it.

**Base**

1. Screw the antenna onto the tripod's 5/8"-11 stud. Hand-tight, not wrench-tight.
2. Route the antenna cable down a leg and zip-tie it so it cannot swing; connect to the HAT.
3. Hang the Pi and battery from the tripod with the S-hook; add the sandbag on windy days.
4. Hang the plumb bob from the tripod centre when you want the antenna over a known mark.

## Keeping it dry

The OLED and keys have to be reachable, so a sealed box is awkward. Use fair-weather
operation (shade the screen, keep the stack on the board) for the first outings. In rain, put
the Pi and battery in a clear zip bag and use the **phone web page** (MARK / Accept / Cancel
buttons, status, and downloads at `http://<unit>:8080/`) instead of the keys. A small
weatherproof electrical box with a clear cover can protect the stack, but the keys will not
work through it.

## Weight and balance

Pi Zero 2 W with two HATs about 40 g, battery about 200-250 g, antenna 20-300 g depending on
type. Keep the battery low on the pole, close to the pole, so the pole does not feel top-heavy.
