# The map viewer's compute core: WebAssembly, not WebGPU

The `/map` page (and the exported `.html`) needs a surface from the surveyed points: a Delaunay
triangulation (TIN), contour lines through it, and per-frame work for the 3D view. That used to be
JavaScript with a naive O(n^2) triangulation. It is now a small Zig library, `src/geom/`, compiled to
WebAssembly (`src/map.wasm`, 24 KB). The Pi does no extra work: `rtkd` serves the embedded bytes at
`/map.wasm`, and the browser does the computing.

## What is in `src/geom`

| File | Role |
|---|---|
| `core.zig` | everything: lon/lat to local metres, 1 mm de-duplication, TIN, long/skinny filter, contours, plan tint, 3D projection + depth sort + shading, hit test. Fixed global arrays for 20,000 points, no allocator. Natively testable. |
| `wasm.zig` | the C-style export surface (`load`, `contour_level`, `prep3d`, ... plus pointer getters for typed-array views). |

Triangulation is incremental Bowyer-Watson, chosen over divide-and-conquer or sweep-hull because it
handles the survey-specific mess (duplicates, collinear rows, co-circular grids) with one mechanism and
is simple to make exact:

* points are inserted in Hilbert-curve order, so each point starts its walk next to the previous one;
* triangles keep their neighbours, so point location is a short visibility walk and the cavity is found
  by flood fill, not by scanning every triangle (this is what removes the O(n^2));
* a ghost vertex stands for infinity, so the hull is exact (no super-triangle to swallow hull slivers);
* orientation and in-circle use a floating-point filter with a double-double fallback; near-zero results
  count as zero, which keeps the answer symmetric on exactly co-circular input such as a surveyed grid.

Same semantics as the JavaScript it replaces: 1 mm de-duplication, `maxEdge = max(15 m, 2.5 x median
nearest-neighbour spacing)`, drop triangles with area < 1e-6 or inradius/circumradius < 0.04, contours
by marching triangles with canonical edge keys so closed loops close bit-exactly. (One deliberate
change, applied to both implementations: triangle area comes from the cross product instead of Heron's
formula, which loses all precision on slivers.) Beyond 20,000 points the page says so instead of trying.

## Speed

Desktop, Node 22 on the dev box (aarch64), TIN + contours every 0.5 m, survey-like random points
(about 12 m spacing), median of 7 runs for wasm, JS timed once for 1,000+ points (`FULL=1 node tools/test_wasm.js` includes the 20,000-point JS run, about 30 s). JS is timed outside
`vm` (code inside a `vm` context runs about 8x slower and had made the old numbers look worse than a
browser really is; in headless Chromium 154 the JS TIN of 1000 / 3000 points took 77 / 351 ms).

| Points | wasm TIN | wasm contours | wasm total | JS total (old) | speed-up |
|---:|---:|---:|---:|---:|---:|
| 50 | 0.08 ms | 0.01 ms | 0.1 ms | 0.8 ms | 9x |
| 200 | 0.36 ms | 0.07 ms | 0.4 ms | 7.2 ms | 17x |
| 1,000 | 1.9 ms | 0.5 ms | 2.3 ms | 73 ms | 32x |
| 3,000 | 6.0 ms | 2.1 ms | 8.1 ms | 586 ms | 73x |
| 6,000 | 12.0 ms | 5.6 ms | 17.6 ms | 2,243 ms | 127x |
| 20,000 | 41 ms | 34 ms | 75 ms | 29,800 ms | 397x |

Target met: 6,000 points TIN in 12 ms (goal: well under 100 ms), 20,000 in 41 ms. Contours at 20,000
points are dominated by the number of levels (about 170 at 0.5 m for this synthetic relief). ReleaseFast
is about 20% faster (6,000 points: 9.9 + 3.8 ms) but 38 KB instead of 24 KB; ReleaseSmall is used because
both are far below what a page can notice. The wasm numbers inside Chromium matched Node (6,000 points:
10 ms TIN). These are desktop numbers. **Phones were not tested**; even a core several times slower than this one
would keep 6,000 points under 100 ms.

Binary and transfer sizes: `src/map.wasm` 24,108 bytes (ReleaseSmall; 37,620 ReleaseFast). `rtkd`
(ReleaseSafe, stripped, aarch64-linux-musl): 525,088 bytes before, 557,240 after (+32 KB: the page grew
from 22.9 KB to 30.5 KB, plus the wasm). Total transfer of `/map` is 30.5 KB of html plus 24.1 KB of wasm
(no compression, HTTP/1.0), about 55 KB, all static bytes. The exported standalone `.html` embeds the wasm as base64 (+32 KB, one offline file).

## WebGPU: decided no

The request was to use WebGPU only if it would make triangulation faster. It would not, at the sizes that
matter (50 to about 6,000 points, ceiling about 20,000):

1. **The CPU version already finishes in about a frame or less.** 12 ms at 6,000 points leaves nothing to
   win back. A GPU path has to beat this *after* paying its fixed costs.
2. **Fixed costs of a GPU path.** Page-level WebGPU needs adapter and device acquisition, shader module
   and pipeline compilation (each a promise), buffer uploads, one `mapAsync` readback per stage, and
   several dispatches because Delaunay is not one kernel. Typical figures are tens of milliseconds for
   device plus pipelines and a millisecond or more per readback round trip; I could not measure them
   here: headless Chromium on this machine reports `navigator.gpu` but `requestAdapter()` returns `null`
   (tried with and without `--enable-unsafe-webgpu` and the SwiftShader adapter), so there is no GPU
   number in this document and none is claimed.
3. **The algorithm is sequential at heart.** Incremental Delaunay (what the CPU version does) is
   inherently ordered. GPU methods exist (point insertion in parallel batches followed by edge flipping to
   fix the Delaunay property, as in gDel2D, or sort-based approaches), but they are involved, need a robust
   predicate in WGSL (no 64-bit floats; our fallback relies on double-double), and are reported to pay off
   at hundreds of thousands to millions of points, not at a few thousand.
4. **Availability.** WebGPU is in Chrome/Edge on desktop and recent Android, and recent Safari, but it is
   not on every phone browser or every phone GPU/driver, and it requires a secure context, and the unit serves
   plain `http://` on a private network (not a secure context, so `navigator.gpu` is not exposed there). A WASM path
   would have to exist anyway, so a GPU path would mean two triangulators to keep identical.
5. **Where the time goes now** is Canvas 2D painting of up to tens of thousands of triangles, not the
   geometry. If a future job size makes drawing the bottleneck, that is a rendering question (a WebGL or
   WebGPU renderer fed by the same wasm output) and a different decision from the one made here.

Revisit if jobs routinely exceed about 100,000 points, which a handheld RTK survey does not produce.

## Not verified

* No phone or tablet browser was run. WebAssembly (with no imports, no threads, no SIMD, no bulk memory
  in this build) is supported by every current mobile browser (Chrome and Samsung Internet on Android,
  Safari on iOS, Firefox on Android), so the wasm path should work everywhere; the JavaScript fallback is
  automatic if instantiation fails and can be forced with `?nowasm`.
* Rendering was checked with headless Chromium screenshots (plan and 3D, standalone file and served from
  a local web server, wasm and `?nowasm`), by eye and by pixel comparison: the 3D views were pixel
  identical between backends; plan views differ only in where a few contour labels sit.
* The `/map` route was tested against `rtkd` through the loopback test, but the updated binary was not
  deployed to either unit.
* Memory: the wasm instance reserves about 11 MB of linear memory for the 20,000-point capacity, mostly
  zero pages that the browser commits lazily. Not measured on a low-memory phone.

## Rebuilding

`src/map.wasm` is committed so the daemon build needs no extra step. After changing `src/geom/*.zig` run
`scripts/build-wasm.sh` (it runs `zig fmt`, `zig build wasm`, and refreshes `src/map.wasm.sha256`) and
commit both files. `node tools/test_wasm.js` fails with a clear message if the stamp does not match the
sources. `zig build test` runs the geometry's native unit tests; `zig build wasm -Dwasm-optimize=ReleaseFast`
builds the faster variant.
