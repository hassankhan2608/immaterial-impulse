import QtQuick
import QtTest
import "../modules/common/functions/edge_shade.js" as EdgeShade

// The bar's adaptive edge shadow (edge_shade.js): the strip's brightness
// from a pixel buffer, and the shade chosen from it.
TestCase {
    name: "EdgeShade"

    // A 4x4 RGBA buffer: the top two rows white, the bottom two black, the
    // left column red on the white rows.
    function buffer() {
        const w = 4, h = 4, d = new Array(w * h * 4).fill(255);
        for (let y = 2; y < 4; y++) for (let x = 0; x < 4; x++) { const i = (y * w + x) * 4; d[i] = 0; d[i + 1] = 0; d[i + 2] = 0; }
        return d;
    }

    function test_the_strip_is_the_edges_rows_or_columns() {
        const d = buffer();
        fuzzyCompare(EdgeShade.stripLuma(d, 4, 4, "top", 2), 1, 0.001);
        fuzzyCompare(EdgeShade.stripLuma(d, 4, 4, "bottom", 2), 0, 0.001);
        fuzzyCompare(EdgeShade.stripLuma(d, 4, 4, "left", 2), 0.5, 0.001);
        fuzzyCompare(EdgeShade.stripLuma(d, 4, 4, "right", 2), 0.5, 0.001);
        const all = EdgeShade.edgeLumas(d, 4, 4, 2);
        fuzzyCompare(all.top, 1, 0.001);
        fuzzyCompare(all.bottom, 0, 0.001);
        verify(isNaN(EdgeShade.stripLuma([], 0, 0, "top", 2)), "an empty buffer has no strip");
    }

    function test_light_text_gets_a_dark_shade_only_over_a_bright_strip() {
        const dark = EdgeShade.edgeShade(0.1, true, 0.55);
        verify(dark.dark); fuzzyCompare(dark.alpha, 0, 0.001);
        const bright = EdgeShade.edgeShade(0.9, true, 0.55);
        verify(bright.dark); fuzzyCompare(bright.alpha, 0.55, 0.001);
        const mid = EdgeShade.edgeShade(0.475, true, 0.55);
        fuzzyCompare(mid.alpha, 0.275, 0.001);
    }

    function test_dark_text_gets_a_light_shade_only_over_a_dark_strip() {
        const dark = EdgeShade.edgeShade(0.1, false, 0.55);
        verify(!dark.dark); fuzzyCompare(dark.alpha, 0.55, 0.001);
        const bright = EdgeShade.edgeShade(0.9, false, 0.55);
        verify(!bright.dark); fuzzyCompare(bright.alpha, 0, 0.001);
    }

    function test_no_sample_yet_is_the_fixed_shade() {
        const none = EdgeShade.edgeShade(undefined, true, 0.55);
        verify(none.dark); fuzzyCompare(none.alpha, 0.55, 0.001);
        const nan = EdgeShade.edgeShade(NaN, false, 0.55);
        verify(!nan.dark); fuzzyCompare(nan.alpha, 0.55, 0.001);
    }
}
