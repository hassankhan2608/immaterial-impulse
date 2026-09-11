import QtQuick
import Quickshell
import Quickshell.Io
import qs.modules.common
import qs.modules.common.functions as Functions

Process {
    id: screenshotProc
    running: true
    property string screenshotDir: Directories.screenshotTemp
    required property ShellScreen screen
    property string screenshotPath: `${screenshotDir}/image-${screen.name}`
    // The frame is written as PPM, not PNG. It is a scratch file on tmpfs that
    // the selector shows and later crops - nobody keeps it - and grim's
    // single-threaded PNG encode was the whole wait before the overlay could
    // appear: at 5120x1440, level-6 PNG measured ~570 ms against ~55 ms for
    // PPM (level-0 PNG still ~185 ms), and Qt reads the PPM back in a third
    // of the time. Every consumer of this file goes through ScreenshotAction,
    // which names PNG explicitly on its outputs, so nothing downstream sees
    // the change of container.
    command: ["bash", "-c", `mkdir -p '${Functions.StringUtils.shellSingleQuoteEscape(screenshotDir)}' && grim -t ppm -o '${Functions.StringUtils.shellSingleQuoteEscape(screen.name)}' '${Functions.StringUtils.shellSingleQuoteEscape(screenshotPath)}'`]
}
