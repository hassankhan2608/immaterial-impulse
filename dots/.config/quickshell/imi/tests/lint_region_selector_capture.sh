#!/usr/bin/env bash
# The selector preview and the eventual crop must use the same grim output.
# A separate frozen ScreencopyView may return a stale compositor buffer.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="${REGION_LINT_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
TARGET="$PROJECT_ROOT/modules/imi/regionSelector/RegionSelection.qml"

if grep -qP '^\s*ScreencopyView\s*\{' "$TARGET"; then
    echo "Region selector capture lint FAILED: preview must not use an independent screencopy" >&2
    exit 1
fi

if ! grep -q 'source: root.screenshotSource' "$TARGET" || ! grep -q 'cache: false' "$TARGET"; then
    echo "Region selector capture lint FAILED: preview must load the uncached fresh grim output" >&2
    exit 1
fi

if ! grep -q 'status === Image.Ready' "$TARGET"; then
    echo "Region selector capture lint FAILED: selector must wait for the fresh image to decode" >&2
    exit 1
fi

# The frozen frame is written as PPM so the overlay is not held behind grim's
# single-threaded PNG encode (~570 ms vs ~55 ms at 5120x1440). magick inherits
# the input container for its outputs, so every crop ScreenshotAction emits
# must name PNG explicitly or the clipboard, the annotator and the uploader
# silently receive PPM. Pin both halves together.
UTILS="$PROJECT_ROOT/modules/common/plugins/designsystem/widgets/regionSelectorUtils"
if grep -q -- '-t ppm' "$UTILS/TempScreenshotProcess.qml"; then
    if ! grep -q 'cropToStdout = `${cropBase} png:-`' "$UTILS/ScreenshotAction.qml" \
       || ! grep -q "cropInPlace = \`\${cropBase} png:'" "$UTILS/ScreenshotAction.qml"; then
        echo "Region selector capture lint FAILED: the frame is PPM, so ScreenshotAction's crops must name png: on both outputs" >&2
        exit 1
    fi
fi

echo "Region selector capture lint passed: preview and crop share one fresh frame"
