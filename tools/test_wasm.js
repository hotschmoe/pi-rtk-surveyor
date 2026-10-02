#!/usr/bin/env node
// Tests of the WebAssembly geometry core (src/map.wasm, from src/geom) against the pure-JS reference in
// src/viewer.html, through the same backend interface the page uses; plus the speed table.
//   node tools/test_wasm.js            tests + speed table (JS timed up to 6000 points)
//   FULL=1 node tools/test_wasm.js     also times the old JS at 20000 points (minutes)
const fs = require('fs'), path = require('path'), assert = require('assert'), crypto = require('crypto');
const root = path.join(__dirname, '..');
const html = fs.readFileSync(path.join(root, 'src', 'viewer.html'), 'utf8');
const a = html.indexOf('// ==== geometry'), b = html.indexOf('// ==== end geometry ====');
assert(a > 0 && b > a, 'geometry markers not found');
// Not vm.runInContext: code inside a vm context runs several times slower (slow global lookups), which would
// make the JS side of the speed table look worse than it is in a browser.
const { jsGeo, makeWasmGeo, loadWasmGeo } = new Function('atob', html.slice(a, b) + '\nreturn {jsGeo,makeWasmGeo,loadWasmGeo};')(s => Buffer.from(s, 'base64').toString('binary'));

let n = 0; const t = (name, fn) => { fn(); n++; console.log('  ok  ' + name); };
let seed = 7; const rnd = () => (seed = (seed * 1664525 + 1013904223) >>> 0) / 4294967296;

// ---- the committed .wasm must be built from the committed sources
const wasmBytes = fs.readFileSync(path.join(root, 'src', 'map.wasm'));
const srcHash = crypto.createHash('sha256').update(fs.readFileSync(path.join(root, 'src/geom/core.zig'))).update(fs.readFileSync(path.join(root, 'src/geom/wasm.zig'))).digest('hex');
const stamp = fs.readFileSync(path.join(root, 'src', 'map.wasm.sha256'), 'utf8').trim();
if (stamp !== srcHash) { console.error('src/map.wasm is out of date with src/geom/*.zig: run scripts/build-wasm.sh and commit the result'); process.exit(1); }

(async () => {
  const wasm = makeWasmGeo((await WebAssembly.instantiate(wasmBytes, {})).instance);

  // survey-like data: spacing ~12 m on a rolling surface, as lon/lat/elevation rows
  function survey(count, side) {
    side = side || Math.sqrt(count) * 12;
    const ll = new Float64Array(3 * count);
    for (let i = 0; i < count; i++) {
      const x = rnd() * side, y = rnd() * side;
      ll[3 * i] = -6.5 + x / 66400; ll[3 * i + 1] = 53.36 + y / 111300; ll[3 * i + 2] = 60 + 0.05 * x + 3 * Math.sin(x / 40) * Math.cos(y / 40);
    }
    return ll;
  }
  const triKey = (T, k) => [T[3 * k], T[3 * k + 1], T[3 * k + 2]].sort((p, q) => p - q).join(',');
  const triArea = (P, T) => { let s = 0; for (let k = 0; k < T.length / 3; k++) { const A = 3 * T[3 * k], B = 3 * T[3 * k + 1], C = 3 * T[3 * k + 2]; s += Math.abs((P[B] - P[A]) * (P[C + 1] - P[A + 1]) - (P[C] - P[A]) * (P[B + 1] - P[A + 1])) / 2; } return s; };
  const levelsFor = (r, step) => { const L = []; for (let z = Math.ceil(r.zmin / step) * step; z <= r.zmax; z += step) L.push([Math.round(z / step) * step, false]); return L; };
  const length = cs => { let s = 0; for (const c of cs) for (let i = 2; i < c.xy.length; i += 2) s += Math.hypot(c.xy[i] - c.xy[i - 2], c.xy[i + 1] - c.xy[i - 1]); return s; };
  const rel = (x, y) => Math.abs(x - y) / Math.max(Math.abs(x), Math.abs(y), 1e-12);

  t('wasm exports, memory and capacity', () => { assert.strictEqual(wasm.cap, 20000); assert(wasm.name === 'wasm'); });

  t('same triangles, total area, spacing and bbox as the JS reference on random sets', () => {
    for (const count of [30, 100, 300, 700]) {
      const ll = survey(count);
      const w = wasm.load(ll, count), j = jsGeo.load(ll, count);
      assert.strictEqual(w.tris.length, j.tris.length, 'triangle count at n=' + count);
      const kw = new Set(), kj = new Set();
      for (let k = 0; k < w.tris.length / 3; k++) { kw.add(triKey(w.tris, k)); kj.add(triKey(j.tris, k)); }
      assert.strictEqual(kw.size, kj.size);
      for (const k of kj) assert(kw.has(k), 'triangle ' + k + ' missing from wasm result');
      assert(rel(triArea(w.pts, w.tris), triArea(j.pts, j.tris)) < 1e-9);
      assert(rel(w.spacing, j.spacing) < 1e-9 && rel(w.maxEdge, j.maxEdge) < 1e-9);
      for (let i = 0; i < 4; i++) assert(Math.abs(w.bbox[i] - j.bbox[i]) < 1e-6);
      assert(Math.abs(w.zmin - j.zmin) < 1e-12 && Math.abs(w.zmax - j.zmax) < 1e-12);
      assert(Math.abs(w.lat0 - j.lat0) < 1e-12 && Math.abs(w.lon0 - j.lon0) < 1e-12);
      for (let i = 0; i < 3 * count; i++) assert(Math.abs(w.pts[i] - j.pts[i]) < 1e-6, 'local coordinate ' + i);
    }
  });

  t('contour segment total length within 1e-6 relative, same line count, closed loops bit-exact', () => {
    for (const [count, step] of [[100, 0.5], [400, 0.25], [900, 1]]) {
      const ll = survey(count), w = wasm.load(ll, count), j = jsGeo.load(ll, count), L = levelsFor(w, step);
      const cw = wasm.contours(L), cj = jsGeo.contours(L);
      assert(!cw.overflow);
      assert(rel(length(cw), length(cj)) < 1e-6, 'length ' + length(cw) + ' vs ' + length(cj));
      assert.strictEqual(cw.length, cj.length, 'line count');
      const closedCount = cs => cs.filter(c => { const m = c.xy.length; return c.xy[0] === c.xy[m - 2] && c.xy[1] === c.xy[m - 1]; }).length;
      assert.strictEqual(closedCount(cw), closedCount(cj), 'closed loops');
    }
    // a cone gives one closed loop whose last vertex is bit-identical to its first
    const cone = new Float64Array(3 * 441);
    for (let i = 0; i < 21; i++) for (let k = 0; k < 21; k++) { const x = (i - 10) * 2, y = (k - 10) * 2, q = 3 * (i * 21 + k); cone[q] = -6.5 + x / 66400; cone[q + 1] = 53.36 + y / 111300; cone[q + 2] = 100 - Math.hypot(x, y); }
    wasm.load(cone, 441);
    const loops = wasm.contours([[95, false]]);
    assert.strictEqual(loops.length, 1);
    const xy = loops[0].xy; assert(xy[0] === xy[xy.length - 2] && xy[1] === xy[xy.length - 1] && xy.length > 20);
  });

  t('tint2d and prep3d agree with the JS reference', () => {
    const ll = survey(250), w = wasm.load(ll, 250), j = jsGeo.load(ll, 250);
    const tw = wasm.tint2d(w.zmin, w.zmax), tj = jsGeo.tint2d(j.zmin, j.zmax), byKey = new Map();
    for (let k = 0; k < j.tris.length / 3; k++) byKey.set(triKey(j.tris, k), tj[k]);
    for (let k = 0; k < w.tris.length / 3; k++) assert.strictEqual(tw[k], byKey.get(triKey(w.tris, k)), 'tint of triangle ' + k);
    const view = { cx: 10, cy: 20, sc: 3, yaw: 0.6, pitch: 0.9, ex: 2, zmin: w.zmin, zmax: w.zmax, w: 800, h: 600 };
    const pw = wasm.prep3d(view), pj = jsGeo.prep3d(view);
    for (let i = 0; i < pj.scr.length; i++) assert(Math.abs(pw.scr[i] - pj.scr[i]) < 1e-6, 'scr ' + i);
    // colour per triangle matches; order is back to front in both
    const colOf = (P, T) => { const m = new Map(); for (let k = 0; k < P.ord.length; k++) m.set(triKey(T, P.ord[k]), P.col[k]); return m; };
    const cw = colOf(pw, w.tris), cj = colOf(pj, j.tris);
    for (const [k, v] of cj) assert.strictEqual(cw.get(k), v, 'shade of ' + k);
    const depth = (P, T, k) => (P.scr[3 * T[3 * P.ord[k]] + 2] + P.scr[3 * T[3 * P.ord[k] + 1] + 2] + P.scr[3 * T[3 * P.ord[k] + 2] + 2]) / 3;
    for (let k = 1; k < pw.ord.length; k++) assert(depth(pw, w.tris, k) >= depth(pw, w.tris, k - 1) - 1e-3);
  });

  t('nearest point hit test agrees with JS', () => {
    const ll = survey(120); wasm.load(ll, 120); jsGeo.load(ll, 120);
    for (let k = 0; k < 200; k++) {
      const args = [rnd() * 800, rnd() * 600, 10, 10, 2 + rnd() * 6, 800, 600, 12];
      assert.strictEqual(wasm.nearest(...args), jsGeo.nearest(...args));
    }
  });

  t('degenerate input: n < 3, collinear, duplicates, NaN-free rejection, identical points', () => {
    for (const count of [0, 1, 2]) { const w = wasm.load(survey(count), count); assert.strictEqual(w.tris.length, 0); }
    const line = new Float64Array(3 * 20); for (let i = 0; i < 20; i++) { line[3 * i] = -6.5 + i * 1e-4; line[3 * i + 1] = 53.36 + i * 1e-4; line[3 * i + 2] = i; }
    assert.strictEqual(wasm.load(line, 20).tris.length, 0);
    assert.strictEqual(wasm.contours([[5, false]]).length, 0);
    const dup = new Float64Array(3 * 40); for (let i = 0; i < 40; i++) { dup[3 * i] = -6.5; dup[3 * i + 1] = 53.36; dup[3 * i + 2] = 1; }
    assert.strictEqual(wasm.load(dup, 40).tris.length, 0);
    const bad = survey(50); bad[3 * 4] = NaN; bad[3 * 9 + 1] = Infinity;
    const r = wasm.load(bad, 50);
    assert(r.tris.length > 0);
    for (const v of r.tris) assert(v !== 4 && v !== 9);
    // a duplicated position keeps only the first occurrence in the mesh
    const d2 = survey(40); d2.copyWithin(3 * 20, 0, 3);
    const r2 = wasm.load(d2, 40); for (const v of r2.tris) assert(v !== 20);
  });

  t('capacity: 20000 points load, 20001 fail cleanly and the instance stays usable', () => {
    const big = survey(20000); const r = wasm.load(big, 20000); assert(r.tris.length > 3 * 10000, "tris " + r.tris.length / 3);
    const over = survey(20001);
    assert.throws(() => wasm.load(over, 20001), e => e.tooMany === true);
    const again = wasm.load(survey(60), 60); assert(again.tris.length > 0);
  });

  t('huge and tiny extents do not hang or crash', () => {
    for (const side of [1e-3, 1, 1e4, 1e6]) { const ll = survey(200, side); ll.forEach((v, i) => { if (i % 3 === 0) ll[i] = -6.5 + (v + 6.5) * side / (Math.sqrt(200) * 12); }); wasm.load(ll, 200); }
  });

  const viaB64 = await loadWasmGeo(wasmBytes.toString('base64'), null);
  t('base64 path gives the same answer', () => { const ll = survey(80); assert.strictEqual(viaB64.load(ll, 80).tris.length, jsGeo.load(ll, 80).tris.length); });

  // ---- speed table
  console.log('\nTIN + contours (0.5 m interval), median of runs, this machine (' + process.version + ')');
  console.log('  points | wasm TIN | wasm contours | wasm total |   JS TIN | JS contours |  JS total | speedup | triangles');
  const med = a_ => a_.slice().sort((p, q) => p - q)[a_.length >> 1];
  const time = fn => { const t0 = process.hrtime.bigint(); fn(); return Number(process.hrtime.bigint() - t0) / 1e6; };
  for (const count of [50, 200, 1000, 3000, 6000, 20000]) {
    const ll = survey(count); let w, L, tw = [], cw = [];
    for (let r = 0; r < 7; r++) { tw.push(time(() => { w = wasm.load(ll, count); })); L = levelsFor(w, 0.5); cw.push(time(() => wasm.contours(L))); }
    let tj = NaN, cj = NaN;
    if (count <= 6000 || process.env.FULL) {
      const reps = count <= 1000 ? 3 : 1, a1 = [], a2 = []; let j;
      for (let r = 0; r < reps; r++) { a1.push(time(() => { j = jsGeo.load(ll, count); })); a2.push(time(() => jsGeo.contours(levelsFor(j, 0.5)))); }
      tj = med(a1); cj = med(a2);
    }
    const f = (v, w_) => (isNaN(v) ? 'n/a' : v.toFixed(v < 10 ? 2 : 1)).padStart(w_);
    const wt = med(tw), wc = med(cw);
    console.log(String(count).padStart(8) + ' |' + f(wt, 9) + ' |' + f(wc, 14) + ' |' + f(wt + wc, 11) + ' |' + f(tj, 9) + ' |' + f(cj, 12) + ' |' + f(tj + cj, 10) + ' |' + (isNaN(tj) ? '    n/a' : ((tj + cj) / (wt + wc)).toFixed(0) + 'x').padStart(8) + ' | ' + w.tris.length / 3);
  }
  console.log('\n' + n + ' wasm tests passed');
})().catch(e => { console.error(e); process.exit(1); });
