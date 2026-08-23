pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.modules.common
import qs.modules.common.functions
import qs.modules.common.plugins

// Ported from Omalog Service.qml onto the shell's PluginState/Process pattern.
// Runs the vendored stdlib-only screentime_data.py against ActivityWatch's local
// SQLite DB. No network, no privileges - the process permission only spawns
// python3 for reads.
Singleton {
    id: root

    readonly property string pluginId: "screentime"
    readonly property string scriptPath:
        Quickshell.shellPath("modules/common/plugins/bundled/screentime/screentime_data.py")

    // Payloads from screentime_data.py: today/week/month
    property var todayData: ({})
    property var weekData: ({})
    property var monthData: ({})
    property bool trackerOnline: false
    property bool loading: false
    property string lastError: ""
    property int activeTab: 0

    // Hover / bar tooltip: today's active time, cheap 30s poll.
    property string todayActiveLabel: "0m"

    function onPanelOpened() {
        root.refreshAll()
        fastTimer.restart()
        slowTimer.restart()
    }

    function onPanelClosed() {
        fastTimer.stop()
        slowTimer.stop()
    }

    function refreshAll() {
        root.checkStatus()
    }

    function checkStatus() {
        runHelper("status", function(payload) {
            const online = payload.online === true
            if (root.trackerOnline !== online) root.trackerOnline = online
            if (online) {
                root.fetchToday()
                root.fetchWeek()
                root.fetchMonth()
            } else {
                root.todayData = {}
                root.weekData = {}
                root.monthData = {}
            }
        })
    }

    function fetchToday() {
        runHelper("today", function(payload) {
            root.todayData = payload
            root.todayActiveLabel = root.formatDuration(payload.active_secs || 0)
        })
    }

    function fetchWeek() {
        runHelper("week", function(payload) { root.weekData = payload })
    }

    function fetchMonth() {
        runHelper("month", function(payload) { root.monthData = payload })
    }

    function runHelper(command, onSuccess) {
        root.loading = true
        root.onSuccess = onSuccess
        helperProc.command = ["python3", FileUtils.trimFileProtocol(root.scriptPath), command]
        helperProc.running = true
    }

    property var onSuccess: null

    Process {
        id: helperProc
        stdout: StdioCollector { id: helperOutput }
        onExited: (exitCode, exitStatus) => {
            root.loading = false
            if (exitCode !== 0) {
                root.lastError = "helper exited " + exitCode
                if (root.trackerOnline) root.trackerOnline = false
                return
            }
            try {
                const payload = JSON.parse(helperOutput.text)
                if (payload.error) {
                    root.lastError = payload.error
                    return
                }
                root.lastError = ""
                if (root.onSuccess) root.onSuccess(payload)
            } catch (e) {
                root.lastError = "invalid payload: " + e
            }
        }
    }

    // Live refresh while the panel is open, matching Omalog's cadence.
    Timer {
        id: fastTimer
        interval: 5000
        repeat: true
        onTriggered: if (root.trackerOnline) root.fetchToday()
    }
    Timer {
        id: slowTimer
        interval: 30000
        repeat: true
        onTriggered: if (root.trackerOnline) { root.fetchWeek(); root.fetchMonth() }
    }

    // Bar tooltip refresh, independent of the panel.
    Timer {
        interval: 30000
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: if (!fastTimer.running) root.fetchToday()
    }

    function formatDuration(secs) {
        const v = Number(secs) || 0
        if (v <= 0) return "0m"
        const h = Math.floor(v / 3600)
        const m = Math.floor((v % 3600) / 60)
        if (h > 0 && m > 0) return h + "h " + m + "m"
        if (h > 0) return h + "h"
        return m + "m"
    }
}
