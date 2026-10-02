//! WebAssembly entry points of the map viewer's geometry core (see core.zig). A small C-style API over
//! flat arrays in linear memory: the page writes lon/lat/elevation rows at `in_ptr()`, calls `load(n)`,
//! and reads typed-array views of the results at the pointers returned here. Pointers are byte offsets
//! into the module's memory; they stay valid for the life of the instance (the memory never moves
//! because the module has a fixed size and never grows it).

const core = @import("core.zig");

pub export fn max_points() u32 {
    return core.max_points;
}
pub export fn in_ptr() usize {
    return @intFromPtr(&core.in_ll);
}
pub export fn pts_ptr() usize {
    return @intFromPtr(&core.pt);
}
pub export fn tris_ptr() usize {
    return @intFromPtr(&core.tri_out);
}
pub export fn info_ptr() usize {
    return @intFromPtr(&core.info);
}
/// Number of f64 slots in the info block (lat0, lon0, minx, maxx, miny, maxy, zmin, zmax, spacing,
/// max_edge, n_valid, n_unique, n_tris).
pub export fn info_len() u32 {
    return core.info.len;
}
/// Convert, de-duplicate, triangulate and filter n rows. Returns the triangle count, or a negative status.
pub export fn load(n: u32) i32 {
    return core.load(n);
}
pub export fn tri_count() u32 {
    return @intCast(core.triCount());
}

pub export fn contour_reset() void {
    core.contourReset();
}
/// Append the contour at `level`; returns lines added or a negative status.
pub export fn contour_level(level: f64, major: u32) i32 {
    return core.contourLevel(level, major != 0);
}
pub export fn line_count() u32 {
    return @intCast(core.lineCount());
}
pub export fn line_point_count() u32 {
    return @intCast(core.linePointCount());
}
pub export fn line_start_ptr() usize {
    return @intFromPtr(&core.line_start);
}
pub export fn line_len_ptr() usize {
    return @intFromPtr(&core.line_len);
}
pub export fn line_z_ptr() usize {
    return @intFromPtr(&core.line_z);
}
pub export fn line_major_ptr() usize {
    return @intFromPtr(&core.line_major);
}
pub export fn line_xy_ptr() usize {
    return @intFromPtr(&core.line_xy);
}

/// Per-triangle plan colours (0xRRGGBB) from mean elevation.
pub export fn tint2d(zmin: f64, zmax: f64) usize {
    core.tint2d(zmin, zmax);
    return @intFromPtr(&core.tint_out);
}

/// Project all points for the 3D view and sort/shade the triangles back to front. Fills scr_ptr(),
/// ord3_ptr() (triangle numbers) and col3_ptr() (0xRRGGBB, in sorted order).
pub export fn prep3d(cx: f64, cy: f64, sc: f64, yaw: f64, pitch: f64, ex: f64, zmin: f64, zmax: f64, w: f64, h: f64) void {
    core.prep3d(.{ .cx = cx, .cy = cy, .sc = sc, .yaw = yaw, .pitch = pitch, .ex = ex, .zmin = zmin, .zmax = zmax, .w = w, .h = h });
}
pub export fn scr_ptr() usize {
    return @intFromPtr(&core.scr);
}
pub export fn ord3_ptr() usize {
    return @intFromPtr(&core.ord3);
}
pub export fn col3_ptr() usize {
    return @intFromPtr(&core.col3);
}

pub export fn nearest(sx: f64, sy: f64, cx: f64, cy: f64, sc: f64, w: f64, h: f64, maxd: f64) i32 {
    return core.nearest(sx, sy, cx, cy, sc, w, h, maxd);
}

test {
    _ = core;
}
