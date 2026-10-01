#!/usr/bin/env python3
"""An unpainted bar can shade the screen edge behind it, and its border thins with its fill.

With the background off and the groups transparent the bar is glyphs
straight over the wallpaper. `bar.edgeShadow` draws a shade at the screen
edge fading to nothing across the bar - from whichever edge the bar sits on,
the bottom flag being the right-hand side when vertical - in both bar
contents, only in that state, and only when asked; Settings > Bar carries
the switch, inert otherwise. The shade is adaptive (edge_shade.js): dark
behind light text, light behind dark text, and as strong as the wallpaper's
strip under the bar needs, from a sample Background.qml publishes per screen. Separately, `colLayer0Border` is thinned by the
background transparency rather than mixed with the thinned fill, so the
plate's border follows the shell opacity slider instead of ringing a
see-through plate.
"""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
CONTENTS = (ROOT / "modules/imi/bar/BarContent.qml", ROOT / "modules/imi/verticalBar/VerticalBarContent.qml")
BAR_CONFIG = ROOT / "modules/imi/settings/pages/BarConfig.qml"
CONFIG = ROOT / "modules/common/Config.qml"
APPEARANCE = ROOT / "modules/common/Appearance.qml"

STYLES = r"\(Config\.options\.bar\.cornerStyle === 0 \|\| Config\.options\.bar\.cornerStyle === 1 \|\| Config\.options\.bar\.cornerStyle === 4\)"
GATE = (r"visible: Config\.options\.bar\.edgeShadow && !Config\.options\.bar\.showBackground\s*&& Config\.options\.bar\.borderless === \"transparent\"\s*&& "
        + STYLES)


def strip_comments(text):
    return re.sub(r"//[^\n]*", "", re.sub(r"/\*.*?\*/", "", text, flags=re.S))


class EdgeShadowTests(unittest.TestCase):
    def test_the_option_exists_and_defaults_off(self):
        self.assertRegex(strip_comments(CONFIG.read_text(encoding="utf-8")), r"property bool edgeShadow: false")

    def test_both_bars_draw_it_only_in_the_unpainted_state_from_the_bars_edge(self):
        for path, orientation in zip(CONTENTS, ("Vertical", "Horizontal")):
            text = strip_comments(path.read_text(encoding="utf-8"))
            block = re.search(r"Rectangle \{\s*id: edgeShadow(.*?)\n    \}", text, re.S)
            self.assertIsNotNone(block, f"{path.name} draws the edge shadow")
            body = block.group(1)
            self.assertRegex(body, GATE, f"{path.name}: drawn only with the background off and the groups transparent, when asked")
            self.assertIn(f"orientation: Gradient.{orientation}", body, f"{path.name}: the shade runs across the bar's thickness")
            self.assertRegex(body, r'position: 0; color: Config\.options\.bar\.bottom \? "transparent" : edgeShadow\.shade')
            self.assertRegex(body, r'position: 1; color: Config\.options\.bar\.bottom \? edgeShadow\.shade : "transparent"')
            # Behind the plate, so a painted background (were it ever on) covers it.
            self.assertLess(text.index("id: edgeShadow"), text.index("id: barBackground"))

    def test_the_shade_adapts_to_the_wallpaper_under_the_bar(self):
        # edge_shade.js: the shade's side follows the text (light text, dark
        # shade; dark text, light shade) and its strength how little the
        # wallpaper's strip under the bar already contrasts with it, from a
        # per-screen sample Background.qml publishes; the fixed token is gone.
        appearance = strip_comments(APPEARANCE.read_text(encoding="utf-8"))
        self.assertNotIn("colBarEdgeShade", appearance)
        for path, edge in zip(CONTENTS, ('Config.options.bar.bottom ? "bottom" : "top"', 'Config.options.bar.bottom ? "right" : "left"')):
            text = strip_comments(path.read_text(encoding="utf-8"))
            self.assertIn('import "../../common/functions/edge_shade.js" as EdgeShade', text, path.name)
            self.assertIn(f"readonly property string shadeEdge: {edge}", text, path.name)
            self.assertIn('GlobalStates.wallpaperEdgeLuma[root.screen?.name ?? ""]?.[shadeEdge],', text, path.name)
            self.assertIn("Appearance.colors.colOnLayer0.hslLightness > 0.5, 0.55)", text, path.name)
            self.assertIn('readonly property color shadeBase: shadeSpec.dark ? Appearance.m3colors.m3shadow : "#ffffff"', text, path.name)
        background = strip_comments((ROOT / "modules/imi/background/Background.qml").read_text(encoding="utf-8"))
        self.assertIn("function sampleEdgeLuma() {", background)
        self.assertIn("}, Qt.size(64, 36));", background, "a small grab: the edges' brightness, not a picture")
        self.assertIn("GlobalStates.publishWallpaperEdgeLuma(bgRoot.screen.name, EdgeShade.edgeLumas(data, edgeSampler.width, edgeSampler.height, 2));", background)
        self.assertIn("running: bgRoot.weShown && !bgRoot.suppressContents", background, "a WE scene is re-read on a slow clock; an image is not")
        states = strip_comments((ROOT / "GlobalStates.qml").read_text(encoding="utf-8"))
        self.assertIn("property var wallpaperEdgeLuma: ({})", states)
        self.assertIn("function publishWallpaperEdgeLuma(screen: string, lumas: var): void {", states)
        shade = (ROOT / "modules/common/functions/edge_shade.js").read_text(encoding="utf-8")
        for fn in ("function luma(r, g, b) {", "function stripLuma(data, width, height, edge, depth) {", "function edgeLumas(data, width, height, depth) {", "function edgeShade(strip, textIsLight, maxAlpha) {"):
            self.assertIn(fn, shade)

    def test_the_switch_is_inert_outside_that_state(self):
        text = strip_comments(BAR_CONFIG.read_text(encoding="utf-8"))
        block = re.search(r'ConfigSwitch \{(?=[^}]*Translation\.tr\("Edge shadow"\))(.*?)\n\s{16}\}', text, re.S)
        self.assertIsNotNone(block, "Settings > Bar carries an Edge shadow switch")
        # Live under exactly the shade's own three conditions - never while
        # the Show Background switch above it is greyed out (M3, Islands).
        self.assertRegex(block.group(1), r'enabled: ' + STYLES + r'\s*&& !Config\.options\.bar\.showBackground && Config\.options\.bar\.borderless === "transparent"')
        self.assertRegex(block.group(1), r"checked: Config\.options\.bar\.edgeShadow")


class BorderFollowsTheFillTests(unittest.TestCase):
    def test_the_layer0_border_is_thinned_not_mixed_with_the_thinned_fill(self):
        appearance = strip_comments(APPEARANCE.read_text(encoding="utf-8"))
        self.assertRegex(appearance, r"property color colLayer0Border: ColorUtils\.transparentize\(ColorUtils\.mix\(root\.m3colors\.m3outlineVariant, colLayer0Base, 0\.4\), root\.backgroundTransparency\)")


if __name__ == "__main__":
    unittest.main()
