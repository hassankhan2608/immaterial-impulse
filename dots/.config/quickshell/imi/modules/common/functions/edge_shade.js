.pragma library

// The bar's edge shadow, adaptive (Settings > Bar > Edge shadow): with the
// bar's background off its glyphs sit straight on the wallpaper, and one
// fixed dark shade at the screen edge helped light text over a dark sky and
// hurt it over a bright one - the shade the glyphs need depends on what is
// under them. So the wallpaper's brightness along each screen edge is sampled
// (Background.qml, a 64x36 grab of the wallpaper item) and the shade is
// chosen from it: its SIDE from the text (light text wants a dark shade, dark
// text a light one) and its STRENGTH from how little the strip already
// contrasts with the text - nothing where the strip contrasts on its own,
// the full shade where it does not. Pure, so tests can drive it.

// Rec. 709 luma of an 8-bit RGB triple, 0..1.
function luma(r, g, b) {
    return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;
}

// The mean luma of the strip along `edge` of an RGBA pixel buffer `data` of
// `width` x `height` (a Canvas ImageData's), `depth` rows (or columns) deep.
// NaN for an empty strip.
function stripLuma(data, width, height, edge, depth) {
    var w = Math.max(0, Math.floor(width)), h = Math.max(0, Math.floor(height));
    var d = Math.max(1, Math.min(Math.floor(depth), edge === "left" || edge === "right" ? w : h));
    var x0 = 0, x1 = w, y0 = 0, y1 = h;
    if (edge === "top") y1 = d;
    else if (edge === "bottom") y0 = h - d;
    else if (edge === "left") x1 = d;
    else x0 = w - d;
    var sum = 0, n = 0;
    for (var y = y0; y < y1; y++) {
        for (var x = x0; x < x1; x++) {
            var i = (y * w + x) * 4;
            sum += luma(data[i], data[i + 1], data[i + 2]);
            n++;
        }
    }
    return n > 0 ? sum / n : NaN;
}

// All four edges at once, as the sampler publishes them.
function edgeLumas(data, width, height, depth) {
    return {
        top: stripLuma(data, width, height, "top", depth),
        bottom: stripLuma(data, width, height, "bottom", depth),
        left: stripLuma(data, width, height, "left", depth),
        right: stripLuma(data, width, height, "right", depth)
    };
}

// The shade for glyphs over a strip of brightness `strip` (0..1; anything
// else - no sample yet - gives the fixed shade the bar always drew): `dark`
// says which side it is on, `alpha` how strong, up to `maxAlpha`. The
// strip's own contrast with the text is what is missing: light text over a
// strip darker than 0.25 needs nothing, over one brighter than 0.7 needs it
// all, linear between; dark text the mirror.
function edgeShade(strip, textIsLight, maxAlpha) {
    var max = Math.max(0, Number(maxAlpha) || 0);
    if (!(strip >= 0 && strip <= 1)) return { dark: !!textIsLight, alpha: max };
    var need = textIsLight ? strip : 1 - strip;
    var t = Math.max(0, Math.min(1, (need - 0.25) / 0.45));
    return { dark: !!textIsLight, alpha: max * t };
}
