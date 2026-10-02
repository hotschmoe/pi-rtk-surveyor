#!/usr/bin/env node
// Tests for the geometry block of src/viewer.html (Delaunay TIN, contours, projection).
//   node tools/test_viewer.js
const fs = require('fs'), vm = require('vm'), path = require('path'), assert = require('assert');
const html = fs.readFileSync(path.join(__dirname, '..', 'src', 'viewer.html'), 'utf8');
const a = html.indexOf('// ==== geometry'), b = html.indexOf('// ==== end geometry ====');
assert(a > 0 && b > a, 'geometry markers not found');
const ctx = {}; vm.createContext(ctx);
vm.runInContext(html.slice(a, b) + '\nthis.api={llToLocal,delaunay,buildTin,contourLines,niceStep};', ctx);
const { llToLocal, delaunay, buildTin, contourLines, niceStep } = ctx.api;

let n = 0; const t = (name, fn) => { fn(); n++; console.log('  ok  ' + name); };
let seed = 42; const rnd = () => (seed = (seed * 1664525 + 1013904223) >>> 0) / 4294967296;
const area = (p, [i, j, k]) => Math.abs((p[j].x - p[i].x) * (p[k].y - p[i].y) - (p[k].x - p[i].x) * (p[j].y - p[i].y)) / 2;
function hullArea(p) {
  const s = p.map(q => [q.x, q.y]).sort((u, v) => u[0] - v[0] || u[1] - v[1]), cr = (o, u, v) => (u[0] - o[0]) * (v[1] - o[1]) - (u[1] - o[1]) * (v[0] - o[0]);
  const lo = [], up = [];
  for (const q of s) { while (lo.length > 1 && cr(lo[lo.length - 2], lo[lo.length - 1], q) <= 0) lo.pop(); lo.push(q); }
  for (const q of s.slice().reverse()) { while (up.length > 1 && cr(up[up.length - 2], up[up.length - 1], q) <= 0) up.pop(); up.push(q); }
  const h = lo.slice(0, -1).concat(up.slice(0, -1)); let A = 0;
  for (let i = 0; i < h.length; i++) { const j = (i + 1) % h.length; A += h[i][0] * h[j][1] - h[j][0] * h[i][1]; }
  return Math.abs(A) / 2;
}

t('niceStep', () => { assert.strictEqual(niceStep(0.07), 0.1); assert.strictEqual(niceStep(0.3), 0.5); assert.strictEqual(niceStep(1.2), 2); assert.strictEqual(niceStep(2.1), 2.5); assert.strictEqual(niceStep(7), 10); });

t('llToLocal: centred on the mean, metres east/north at 33.46 N', () => {
  const f = [-111.7394, -111.7384].map((lon, i) => ({ geometry: { type: 'Point', coordinates: [lon, 33.4648 + i * 0.0001, 418 + i] }, properties: { id: '00' + (i + 1) } }));
  const r = llToLocal(f);
  assert(Math.abs(r.pts[0].x + r.pts[1].x) < 1e-9 && Math.abs(r.pts[0].y + r.pts[1].y) < 1e-9);
  assert(Math.abs((r.pts[1].x - r.pts[0].x) - 0.001 * 92829) < 0.5, 'east metres ' + (r.pts[1].x - r.pts[0].x));
  assert(Math.abs((r.pts[1].y - r.pts[0].y) - 0.0001 * 110900) < 0.05);
  assert.strictEqual(r.pts[1].z, 419);
});

t('delaunay: 4x4 grid has 18 triangles (Euler)', () => {
  const p = []; for (let i = 0; i < 4; i++) for (let j = 0; j < 4; j++) p.push({ x: i * 10, y: j * 10 });
  assert.strictEqual(delaunay(p).length, 18);
});

t('delaunay: random points - empty circumcircles, covers the convex hull exactly', () => {
  const p = Array.from({ length: 80 }, () => ({ x: rnd() * 200, y: rnd() * 150 }));
  const T = delaunay(p);
  let total = 0;
  for (const tri of T) {
    total += area(p, tri);
    const [A, B, C] = tri.map(i => p[i]);
    const d = 2 * (A.x * (B.y - C.y) + B.x * (C.y - A.y) + C.x * (A.y - B.y));
    const ux = ((A.x ** 2 + A.y ** 2) * (B.y - C.y) + (B.x ** 2 + B.y ** 2) * (C.y - A.y) + (C.x ** 2 + C.y ** 2) * (A.y - B.y)) / d;
    const uy = ((A.x ** 2 + A.y ** 2) * (C.x - B.x) + (B.x ** 2 + B.y ** 2) * (A.x - C.x) + (C.x ** 2 + C.y ** 2) * (B.x - A.x)) / d;
    const r2 = (A.x - ux) ** 2 + (A.y - uy) ** 2;
    p.forEach((q, i) => { if (!tri.includes(i)) assert(((q.x - ux) ** 2 + (q.y - uy) ** 2) >= r2 - 1e-6, 'point inside circumcircle'); });
  }
  assert(Math.abs(total - hullArea(p)) < 1e-6 * hullArea(p), 'area ' + total + ' vs hull ' + hullArea(p));
});

t('buildTin: duplicates are tolerated; a far outlier does not create long hull triangles', () => {
  const p = []; for (let i = 0; i < 5; i++) for (let j = 0; j < 5; j++) p.push({ x: i * 10, y: j * 10, z: 0 });
  p.push({ x: 0, y: 0, z: 0 }); // duplicate position
  p.push({ x: 900, y: 900, z: 0 }); // outlier
  const r = buildTin(p);
  assert(r.tris.length >= 30);
  assert(!r.tris.some(tri => tri.includes(p.length - 1)), 'outlier must not be triangulated');
});

t('contours of a plane are straight lines at the right place', () => {
  const p = Array.from({ length: 60 }, () => { const x = rnd() * 100, y = rnd() * 100; return { x, y, z: 10 + 0.05 * x }; });
  const T = buildTin(p).tris;
  for (const L of [11, 12, 13.5]) {
    const lines = contourLines(p, T, L); assert(lines.length >= 1);
    for (const ln of lines) for (const q of ln) assert(Math.abs(q[0] - (L - 10) / 0.05) < 1e-9, 'x=' + q[0]);
  }
  assert.strictEqual(contourLines(p, T, 99).length, 0);
});

t('contours of a cone are one closed loop of about the right radius', () => {
  const p = []; for (let i = -10; i <= 10; i++) for (let j = -10; j <= 10; j++) p.push({ x: i * 2, y: j * 2, z: 100 - Math.hypot(i * 2, j * 2) });
  const lines = contourLines(p, buildTin(p).tris, 95);
  assert.strictEqual(lines.length, 1, 'loops: ' + lines.length);
  const l = lines[0]; assert.deepStrictEqual(l[0], l[l.length - 1], 'closed');
  const rr = l.map(q => Math.hypot(q[0], q[1])); const mean = rr.reduce((s, v) => s + v, 0) / rr.length;
  assert(Math.abs(mean - 5) < 0.15, 'mean radius ' + mean);
});

console.log(n + ' viewer tests passed');
