.pragma library

// Frame mode's arithmetic (docs/proposals/frame-mode.md, "a single geometry
// authority"): which edge is how thick, where each band starts and stops,
// and where the four inner fillets sit. Pure, so tests/tst_frame_geometry.qml
// can pin it; FrameGeometry.qml binds it to the config and the tokens.
//
// The frame is a border of `thickness` at the screen edge on every edge, with
// ONE exception: the bar's edge, WHEN the bar's plate covers that strip edge
// to edge - the Hug style, and only it (Float and Float Islands inset their
// plates by the gap, Islands and M3 paint no strip at all). There the bar IS
// the frame's edge: the band continues under the plate, from the plate's
// bottom to where windows start, and the frame's inner corner is the bar's
// zone plus that gap. A band placed under a bar that does NOT cover its strip
// read as a stray line below a floating bar rather than a border around it,
// which is the whole point of the mode.
//
// Every other edge is the band alone - the dock included. The dock is a pill
// in the middle of its strip, not a plate: modelling it as an occupant put a
// band above its zone (a line across the wallpaper with the dock floating
// under it), and then made the band its whole strip (a border as tall as the
// dock, mostly empty on both sides of the pill). The band stays thin and the
// dock meets it on the dock's own terms (dock_geometry.js `frameOffset`):
// sitting on the band as a tab, or floating a gap above it.

// The thinnest band that actually draws. A one-pixel layer surface renders
// NOTHING here - measured, twice, with the band tinted red: at two pixels the
// rows are the band's colour, at one the wallpaper, while `hyprctl layers`
// reports the surface at both. It is what made an attached dock look like it
// sat a pixel above the screen's edge: the band it rests on was invisible.
var HAIRLINE = 2;

// The band's thickness: the configured pixels, never thinner than draws. The
// gap was 0's meaning until a user read 0 as "thinnest" and got the gap's
// five pixels, which on a floating bar is a visible ledge.
function bandThickness(configured) {
    var c = Number(configured) || 0;
    return Math.max(HAIRLINE, c);
}

// The band's thickness ON its own edge: NOTHING on a covering bar's edge,
// because there the bar's own plate is the border - it is opaque, it reaches
// both screen edges, and it is already the thickest thing on that side. A
// band under it made the frame fifty pixels thick on one edge and one pixel
// on the other three, which is not a border, and the fillet that tried to
// round that junction was the blob at each end of the bar.
// Every edge has its band, the bar's included: the bar's plate is a JOIN on
// that band (frame-pin-grammar.md, the bar row) - fused it sits on the
// hairline as one colour, released it floats a gap off it - so the band no
// longer stands aside for it. (Stage 3 had made the plate itself the band,
// which left nothing for the plate to lift off.) The arguments beyond the
// band are kept for the callers that still say them.
function bandExtent(edge, barEdge, band, gapsOut, barCovers) {
    return Number(band) || 0;
}

// How far the frame reaches in on each screen edge, i.e. where its inner
// corner is. A covering bar's edge is its zone plus the gap: the compositor
// reserves the zone and THEN applies the gap, so that is where windows start
// (measured: modelling it as the painted height left a gap-wide wallpaper
// stripe under the bar). Every other edge - a floating bar's included, where
// the bar sits inside the frame rather than being part of it - is the band.
// Not the dock's zone: the frame's inner corner on the dock's edge is where
// the band meets the inside, whatever hangs off the band there (a fillet
// placed at the dock's inset arced into wallpaper).
function edgeInsets(barEdge, barThickness, band, gapsOut, barCovers) {
    var insets = { top: band, left: band, right: band, bottom: band };
    if (barCovers && barEdge in insets)
        insets[barEdge] = (Number(barThickness) || 0) + (Number(gapsOut) || 0);
    return insets;
}

// There is no inner fillet any more, and no reader of the compositor's window
// rounding here. The frame's corners are the SCREEN's corners: a monitor has
// a black bezel with a radius, ScreenCorners has always drawn that bezel in
// black outside frame mode, and the frame's border simply runs into it. A
// frame-coloured fillet at an inner corner only ever made sense while one
// edge was thick enough to round, which is the model this file just left.

// A band's four margins. Every band is AT its screen edge; the two horizontal
// ones span the width and the two side ones run between them, from the top
// band's inner edge to the bottom band's, so no two bands overlap. Bands
// anchored the full screen length crossed at the corners, and the frame's
// colour is translucent: each crossing was a band-square painted twice,
// darker than the rest of the frame. A covering bar's edge has no band at
// all, so the side bands run to the screen edge there and the bar's own plate
// is the border across the top.
function bandMargins(edge, barEdge, band, gapsOut, barCovers) {
    var m = { top: 0, bottom: 0, left: 0, right: 0 };
    if (edge === "left" || edge === "right") {
        m.top = bandExtent("top", barEdge, band, gapsOut, barCovers);
        m.bottom = bandExtent("bottom", barEdge, band, gapsOut, barCovers);
    }
    return m;
}

// --- the join, drawn on the frame's surface (frame-one-surface.md, stage 2) --

// The band's inner edge as a coordinate along the edge's axis, in the frame
// surface's own frame (a y for top and bottom, an x for left and right): what
// the join's field is told the half-plane is at.
function joinBandEdge(edge, extent, width, height) {
    var e = Number(extent) || 0;
    if (edge === "top") return e;
    if (edge === "left") return e;
    if (edge === "bottom") return (Number(height) || 0) - e;
    return (Number(width) || 0) - e;
}

// Whether a window is in the way of the shell's element on `edge` - the bar
// (frame-pin-grammar.md, the bar row: it hugs for one) or the dock (it hides
// for one): a window on the monitor's active workspace, unless it FLOATS
// clear of the element's strip, `depth` deep along that edge (the element's
// zone, its lift and the gap). A floating window in the middle of the screen
// leaves the bar's border and the dock alone; one dragged into the strip is
// in the way, touching counts. `windows` and `monitor` are hyprctl's JSON: a
// client's `at`/`size` are logical, a monitor's `width`/`height` physical
// under its `scale`, swapped by an odd `transform`.
function edgeOccupied(windows, monitor, edge, depth) {
    if (!monitor) return false;
    var scale = Number(monitor.scale) || 1;
    var rotated = (Number(monitor.transform) || 0) % 2 === 1;
    var lw = (Number(rotated ? monitor.height : monitor.width) || 0) / scale;
    var lh = (Number(rotated ? monitor.width : monitor.height) || 0) / scale;
    var d = Math.max(0, Number(depth) || 0);
    var mx = Number(monitor.x) || 0, my = Number(monitor.y) || 0;
    var strip = edge === "bottom" ? { x: mx, y: my + lh - d, w: lw, h: d }
        : edge === "top" ? { x: mx, y: my, w: lw, h: d }
        : edge === "left" ? { x: mx, y: my, w: d, h: lh }
        : { x: mx + lw - d, y: my, w: d, h: lh };
    var ws = monitor.activeWorkspace ? monitor.activeWorkspace.id : undefined;
    // A special workspace's windows, while it is shown: never the whole
    // screen (they sit in the middle, scaled), so they count by their rect
    // like a floating window does - one over the dock hides it (screenshot).
    var special = monitor.specialWorkspace && monitor.specialWorkspace.name ? monitor.specialWorkspace.id : undefined;
    var list = windows || [];
    for (var i = 0; i < list.length; i++) {
        var w = list[i];
        if (!w || w.monitor !== monitor.id || !w.workspace) continue;
        var onActive = w.workspace.id === ws, onSpecial = special !== undefined && w.workspace.id === special;
        if (!onActive && !onSpecial) continue;
        if (onActive && !w.floating) return true;
        var at = w.at || [0, 0], size = w.size || [0, 0];
        if (at[0] <= strip.x + strip.w && at[0] + size[0] >= strip.x
            && at[1] <= strip.y + strip.h && at[1] + size[1] >= strip.y) return true;
    }
    return false;
}

// The inner edge of whatever bar sits on `edge` in a screen's join records
// (frame-pin-grammar.md, the bar row): the plate's, or the island's under
// `along` (a screen x, for a horizontal edge), else `fallback` - the band's
// own edge, for a bar that is hidden, absent or of a style that publishes no
// plate. What a card centred on the bar (the OSD) fuses to, read the same way
// by the frame's painter and by the card's own window.
function barRecordAt(joins, edge, along) {
    if (!joins) return null;
    var b = joins.bar;
    if (b && b.edge === edge) return b;
    var keys = ["barIsland:left", "barIsland:center", "barIsland:right"];
    for (var i = 0; i < keys.length; i++) {
        var isl = joins[keys[i]];
        if (isl && isl.edge === edge && along >= isl.plate.x && along <= isl.plate.x + isl.plate.width) return isl;
    }
    return null;
}
function barInnerEdgeAt(joins, edge, along, fallback) {
    var r = barRecordAt(joins, edge, along);
    if (!r) return fallback;
    return edge === "bottom" ? r.plate.y : r.plate.y + r.plate.height;
}

// The join records, many per screen (frame-pin-grammar.md §3): a map of
// screen name to a map of element key ("dock", "barPopup",
// "notification:<id>") to record. Returns a NEW outer and inner map with
// `record` set under `key`, or with the key removed when `record` is null -
// and the screen removed when nothing is left under it. New objects because
// a `property var` signals on reassignment only; nothing here mutates.
function withJoin(joins, screen, key, record) {
    var name = String(screen || ""), k = String(key || "");
    if (!name || !k) return joins || {};
    var outer = Object.assign({}, joins || {});
    var inner = Object.assign({}, outer[name] || {});
    if (record) inner[k] = record; else delete inner[k];
    if (Object.keys(inner).length) outer[name] = inner; else delete outer[name];
    return outer;
}

