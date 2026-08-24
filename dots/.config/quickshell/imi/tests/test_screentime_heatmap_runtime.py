#!/usr/bin/env python3
"""Checks the production Screen Time year heatmap at the popup's real width."""

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(Path(__file__).resolve().parent))
import nested_display  # noqa: E402

HARNESS = ROOT / "ScreenTimeHeatmapRuntimeTest.qml"
EXPECTED_CHECKS = 5


@unittest.skipUnless(nested_display.available(),
                     "needs qs, weston and dbus-run-session on PATH")
class ScreenTimeHeatmapRuntimeTest(unittest.TestCase):
    def setUp(self):
        self.home = Path(tempfile.mkdtemp(prefix="imi-screentime-heatmap-"))
        self.addCleanup(shutil.rmtree, self.home, ignore_errors=True)

    def test_year_grid_and_month_labels_fit_the_popup_card(self):
        env = nested_display.start(self, "screentime-heatmap", width=600, height=300)
        env["XDG_CONFIG_HOME"] = str(self.home / "config")
        env["XDG_CACHE_HOME"] = str(self.home / "cache")
        env["XDG_STATE_HOME"] = str(self.home / "state")
        env["XDG_DATA_HOME"] = str(self.home / "data")
        for key in ("XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_STATE_HOME", "XDG_DATA_HOME"):
            Path(env[key]).mkdir(parents=True, exist_ok=True)

        proc = subprocess.run(
            ["dbus-run-session", "--", "qs", "-p", str(HARNESS)],
            cwd=str(ROOT), env=env, capture_output=True, text=True, timeout=180)
        output = proc.stdout + proc.stderr
        failed = [line for line in output.splitlines() if "FAIL" in line]
        self.assertEqual(failed, [], f"harness reported failures:\n{output}")
        self.assertIn(
            f"[ScreenTimeHeatmap] checks: {EXPECTED_CHECKS} failures: 0",
            output,
            f"harness never reached a clean verdict:\n{output}")


if __name__ == "__main__":
    unittest.main()
