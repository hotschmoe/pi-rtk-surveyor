# Source notes

## build.zig

The daemon uses one thread and an epoll loop. Release binaries are stripped by default; use
`-Dstrip=false` for symbolized debugging. Error tracing and unwind tables are omitted for the
stripped field binary, which cannot symbolize stack traces.

## scripts/add-wifi.sh

The Wi-Fi password is read without echo, sent through SSH standard input, and stored only in a
root-owned NetworkManager profile. Existing profiles remain available, selected by priority.

## scripts/gnss-tap.sh

The service is stopped before the UART capture and restarted by the exit trap, including on Ctrl-C.

## scripts/lib.sh

The USB gadget host is preferred; the Wi-Fi alias is the fallback when USB is unavailable.

## scripts/provision.sh

Provisioning preserves an existing unit configuration and does not handle Wi-Fi credentials. The
old daemon and serial getty are disabled to release the UART.

## src/basepos.zig

The stored base position keeps multi-day jobs in one reference frame. Its timestamp is Unix seconds,
with zero meaning unknown; placeholders are rejected because a monument must be near Earth's surface.

## src/config.zig

Configuration is an INI file with sectioned keys and line-numbered errors. Base fixed coordinates
are latitude, longitude and ellipsoidal height; zero OLED idle timeout disables blanking.

## src/demux.zig

Only checksum-valid NMEA and CRC-valid RTCM reach the sink. Sink slices are valid only during the
callback. An invalid RTCM candidate is replayed after dropping its first byte to regain framing.

## src/geo.zig

Coordinates are WGS-84 degrees and ellipsoidal metres; ENU values are metres. Occupation statistics
use offsets from the first sample to retain precision and report sample horizontal scatter. The
height formula remains valid at the poles.

## src/input.zig

The Waveshare HAT inputs are active low with pull-ups. Debouncing waits for a quiet interval so a
bouncing release cannot leave a key stuck. Drain pending edges both on readability and on ticks.

## src/nmea.zig

Parser slices borrow the caller's line buffer. Elevations from GGA are mean sea level metres;
receiver time before first fix may contain the placeholder date 1980-01-06. GSA system IDs identify
constellations and zero PRNs denote empty slots. GSA mode 1 means no fix, 2 means 2D, and 3
means 3D; survey-in state 0 is idle, 1 in progress, and 2 complete.

## src/ntrip.zig

The server request parser returns slices into the request and the decoded credentials scratch buffer.
NTRIP 1 streams can follow their header without a blank line; the RTCM framer discards extra bytes.

## src/rtcm.zig

RTCM frames use the 10403.x transport framing and CRC-24Q. Message 1005 coordinates are ECEF metres;
the all-zero or polar position is the receiver's placeholder before survey-in.

## src/rx.zig

The receiver's GGA satellite count counts signals, so dual-band satellites may be counted twice.
GSA sentences arrive after GGA: distinct system/PRN masks are committed at the next epoch. GSV is
per band, so use the largest count per talker. A 99.99 error estimate means no solution.

## src/survey.zig

A point averages qualifying RTK epochs and never reports accuracy better than measured scatter.
Corrections past the configured age do not qualify as RTK. Consecutive bad epochs restart the
average. Ground elevation is orthometric; the first eight CSV
columns retain the original schema. A point must reach flash before the UI reports SAVED.

## src/timeutil.zig

Conversions use the proleptic Gregorian calendar and UTC. The Pi has no RTC, so point timestamps
prefer GNSS time over the system clock. The civil-day conversion follows Howard Hinnant's algorithm.

## src/app.zig

The daemon runs one epoll loop. Receiver-bound queues drop whole frames that do not fit; they never
send partial frames. A missing display or keys degrades operation instead of stopping the daemon.
The wake key only wakes the panel; a toast is dismissed without consuming a subsequent key action.
The rover sends GGA upstream for VRS casters and for base-side identification.

## src/http.zig

The server is intended for a private survey network and has no authentication; set `ui.http_port`
to zero to disable it. State-changing actions require POST to prevent link prefetch from marking a
point. Embedded pages and headers must fit the shared response buffer.

## src/lc29h.zig

Receiver settings are read before they are written. Rewriting the base survey-in setting restarts
the survey, so it must only be forced when the operator requests a new survey. The driver needs
regular ticks, at least every 100 ms. GLL and VTG are redundant load on the 115200 baud link.

## src/net.zig

Caster send buffers are separate zero-initialised globals because embedding large default-initialised
arrays in client records would emit and copy the data in the binary. A client too far behind is
disconnected rather than fed stale corrections. Only CRC-valid RTCM reaches the receiver.

## src/geom/core.zig

Fixed global arrays bound the geometry capacity and avoid embedding large initialized data in the
binary. Triangulation uses Hilbert-ordered insertion, adjacency walks and a ghost vertex; filtered
floating-point predicates fall back to double-double arithmetic. Values below the double-double
noise tolerance are treated as zero to preserve symmetry on co-circular or collinear input.
For a ghost triangle, points on the open hull edge conflict, but its endpoints do not. Input rows
are longitude, latitude and elevation; local coordinates are east, north and elevation, with NaN
rows for invalid inputs. Input is deduplicated to a 1 mm grid; slivers with inradius/circumradius below 0.04 and long edges
are filtered. Contour intersections use a canonical edge order so shared points match bit for bit;
a vertex exactly on a contour counts as at or above the level.

## src/geom/wasm.zig

The browser exchanges flat arrays through byte offsets into fixed-size WebAssembly memory. The
memory never grows, so exported pointers remain valid for the instance lifetime. The info block
contains lat0, lon0, min/max x and y, min/max elevation, spacing, max edge, and the valid, unique
and triangle counts, in that order. Plan colours are packed as `0xRRGGBB`; 3D triangles and their
colours are returned in back-to-front order.
