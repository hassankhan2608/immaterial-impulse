pragma Singleton
pragma ComponentBehavior: Bound

import Quickshell
import Quickshell.Io
import QtQuick
import qs.modules.common
import qs.modules.common.functions

/**
 * One Oracle Cloud instance's status, for the left sidebar's VPS panel.
 *
 * Detection is two-staged like Tailscale.qml: `configured` (an API key exists
 * in ~/.oci/config, checked once at startup) gates everything, and `available`
 * (the last poll returned a document) tracks whether the tenancy answered. UI
 * hides entirely when !configured and degrades when !available.
 *
 * The numbers are Oracle's own metered quantities, read from the Usage API by
 * scripts/oci/vps_status.py, not the shape multiplied by elapsed time: an
 * instance resized mid-month has consumed more than its current shape implies,
 * and the naive product silently under-reports it. Live utilisation comes from
 * Monitoring in the same pass.
 *
 * The poll is deliberately slow. Metered usage moves once a day, and both APIs
 * are rate-limited per tenancy, so a sidebar that is opened and closed all day
 * must not turn into a request loop.
 */
Singleton {
    id: root

    readonly property int pollInterval: Config.options.sidebar?.ociVps?.pollInterval ?? 900000
    readonly property string instanceName: Config.options.sidebar?.ociVps?.instanceName ?? ""
    readonly property string profile: Config.options.sidebar?.ociVps?.profile ?? "DEFAULT"
    readonly property bool enableService: Config.options.sidebar?.ociVps?.enable ?? true

    // ---- detection ----
    property bool configured: false
    property bool available: false
    property bool loading: false
    property string lastError: ""
    property string generatedAt: ""

    // ---- instance ----
    property string name: ""
    property string state: ""
    property string processor: ""
    property real bandwidthGbps: 0
    property int maxVnics: 0
    property string created: ""
    property string shape: ""
    property real ocpus: 0
    property real memoryGb: 0
    property string region: ""
    property string faultDomain: ""

    // ---- live utilisation ----
    property real cpuPercent: -1
    property real memoryPercent: -1
    property real loadAverage: -1
    // Bytes per second. -1 means the agent reported nothing, which is not 0 B/s.
    property real netInRate: -1
    property real netOutRate: -1
    property real diskReadRate: -1
    property real diskWriteRate: -1

    // ---- metered allowances ----
    property var ocpuMeter: ({})
    property var memoryMeter: ({})
    property var egressMeter: ({})

    // ---- storage ----
    property real bootSizeGb: 0
    property real bootVpusPerGb: 0
    property bool bootVpuBillable: false
    property real blockGb: 0
    property real allocatedGb: 0
    property real allocationLimitGb: 0
    property real allocationPercent: 0
    property bool allocationFull: false
    // [{day, hours}] and [{day, gb}], oldest first, one point per metered day.
    property var dailyOcpu: []
    property var dailyEgress: []

    // Graph.qml wants values already in 0-1. Scaling against the series' own
    // peak keeps a resize legible as a step: the tall days stay tall.
    readonly property var dailyOcpuNormalized: {
        const values = (root.dailyOcpu ?? []).map(point => point.hours ?? 0)
        if (values.length === 0) return []
        const peak = Math.max.apply(null, values)
        if (!(peak > 0)) return []
        return values.map(value => value / peak)
    }
    readonly property real dailyOcpuPeak: {
        const values = (root.dailyOcpu ?? []).map(point => point.hours ?? 0)
        return values.length > 0 ? Math.max.apply(null, values) : 0
    }
    readonly property var dailyEgressNormalized: {
        const values = (root.dailyEgress ?? []).map(point => point.gb ?? 0)
        if (values.length === 0) return []
        const peak = Math.max.apply(null, values)
        if (!(peak > 0)) return []
        return values.map(value => value / peak)
    }
    readonly property real dailyEgressPeak: {
        const values = (root.dailyEgress ?? []).map(point => point.gb ?? 0)
        return values.length > 0 ? Math.max.apply(null, values) : 0
    }

    property var skus: []

    readonly property bool running: root.state === "RUNNING"
    readonly property bool hasLiveMetrics: root.cpuPercent >= 0

    // ---- lifecycle actions ----
    property bool actionPending: false
    property string pendingAction: ""
    // A state the API is still moving through. Offering buttons here would
    // queue a second action against a transition already under way.
    readonly property bool inTransition: ["STARTING", "STOPPING", "CREATING_IMAGE"].includes(root.state)
    readonly property bool canStart: root.available && root.state === "STOPPED" && !root.actionPending
    readonly property bool canStop: root.available && root.running && !root.actionPending
    readonly property bool canReboot: root.available && root.running && !root.actionPending
    // The worst of the three allowances is what the panel's header reports, so a
    // single glance answers "is anything about to cost money".
    readonly property string worstStatus: {
        const order = ["safe", "watch", "critical", "over"]
        const states = [root.ocpuMeter?.status, root.memoryMeter?.status, root.egressMeter?.status]
        let worst = "safe"
        for (const status of states) {
            if (!status) continue
            if (order.indexOf(status) > order.indexOf(worst)) worst = status
        }
        return worst
    }
    readonly property string materialSymbol: !root.available ? "cloud_off"
        : root.worstStatus === "safe" ? "cloud_done" : "cloud_alert"

    /**
     * A quantity of hours or gigabytes, at a readable magnitude.
     * Terabytes are spelled out because the free egress allowance is quoted in
     * them, and 10000 GB reads as a smaller number than it is.
     */
    function formatGb(value: real): string {
        if (!isFinite(value)) return "-"
        if (value >= 1000) return (value / 1000).toFixed(2) + " TB"
        if (value >= 1) return value.toFixed(1) + " GB"
        return (value * 1000).toFixed(0) + " MB"
    }

    function formatHours(value: real): string {
        if (!isFinite(value)) return "-"
        return value >= 1000 ? Math.round(value).toLocaleString(Qt.locale(), "f", 0)
            : value.toFixed(1)
    }

    /**
     * A throughput in bytes per second. Decimal units, matching how Oracle
     * quotes both the allowance and the shape's bandwidth.
     */
    function formatRate(bytesPerSecond: real): string {
        if (bytesPerSecond < 0 || !isFinite(bytesPerSecond)) return "-"
        if (bytesPerSecond >= 1e6) return (bytesPerSecond / 1e6).toFixed(2) + " MB/s"
        if (bytesPerSecond >= 1e3) return (bytesPerSecond / 1e3).toFixed(0) + " kB/s"
        return Math.round(bytesPerSecond) + " B/s"
    }

    function applyStatus(text: string): void {
        let document
        try {
            document = JSON.parse(text)
        } catch (error) {
            root.available = false
            root.lastError = "unreadable response from vps_status.py"
            return
        }
        if (!document?.ok) {
            root.available = false
            root.lastError = document?.error ?? "unknown failure"
            return
        }

        const instance = document.instance ?? {}
        const live = document.live ?? {}
        const freeTier = document.freeTier ?? {}
        const storage = document.storage ?? {}

        root.name = instance.name ?? ""
        root.state = instance.state ?? ""
        root.shape = instance.shape ?? ""
        root.ocpus = instance.ocpus ?? 0
        root.memoryGb = instance.memoryGb ?? 0
        root.region = instance.region ?? ""
        root.faultDomain = instance.faultDomain ?? ""
        root.processor = instance.processor ?? ""
        root.bandwidthGbps = instance.bandwidthGbps ?? 0
        root.maxVnics = instance.maxVnics ?? 0
        root.created = instance.created ?? ""

        // A metric the agent did not report must read as absent, not as zero
        // load - the difference matters when the agent is down.
        root.cpuPercent = live.cpuPercent ?? -1
        root.memoryPercent = live.memoryPercent ?? -1
        root.loadAverage = live.loadAverage ?? -1
        root.netInRate = live.netInRate ?? -1
        root.netOutRate = live.netOutRate ?? -1
        root.diskReadRate = live.diskReadRate ?? -1
        root.diskWriteRate = live.diskWriteRate ?? -1

        root.ocpuMeter = freeTier.ocpu ?? ({})
        root.memoryMeter = freeTier.memory ?? ({})
        root.egressMeter = document.egress ?? ({})

        root.bootSizeGb = storage.bootSizeGb ?? 0
        root.bootVpusPerGb = storage.bootVpusPerGb ?? 0
        root.bootVpuBillable = storage.bootVpuBillable ?? false
        root.blockGb = storage.blockGb ?? 0
        root.allocatedGb = storage.allocatedGb ?? 0
        root.allocationLimitGb = storage.allocationLimitGb ?? 0
        root.allocationPercent = storage.allocationPercent ?? 0
        root.allocationFull = storage.allocationFull ?? false

        root.dailyOcpu = document.dailyOcpuHours ?? []
        root.dailyEgress = document.dailyEgressGb ?? []
        root.skus = document.skus ?? []
        root.generatedAt = document.generatedAt ?? ""
        root.lastError = ""
        root.available = true
    }

    function refresh(): void {
        if (!root.configured || statusProc.running) return
        root.loading = true
        statusProc.running = true
    }

    /**
     * The result of a lifecycle action. The reported state is trusted over the
     * one polling last saw, then a refresh is asked for anyway: the API answers
     * with the transitional state (STOPPING), not the settled one.
     */
    function applyActionResult(text: string): void {
        let document
        try {
            document = JSON.parse(text)
        } catch (error) {
            root.lastError = "unreadable response to a lifecycle action"
            return
        }
        if (!document?.ok) {
            root.lastError = document?.error ?? "the action was refused"
            return
        }
        if (document.state) root.state = document.state
        root.lastError = ""
    }

    function performAction(action: string): void {
        if (!root.configured || actionProc.running) return
        root.pendingAction = action
        root.actionPending = true
        actionProc.command = [
            "python3",
            FileUtils.trimFileProtocol(`${Directories.scriptPath}/oci/vps_status.py`),
            "--instance", root.instanceName,
            "--profile", root.profile,
            "--action", action
        ]
        actionProc.running = true
    }

    Process {
        id: detectProc
        running: true
        command: ["test", "-f", `${Quickshell.env("HOME")}/.oci/config`]
        onExited: (exitCode, exitStatus) => {
            root.configured = exitCode === 0
            if (root.configured && root.enableService) root.refresh()
        }
    }

    Process {
        id: statusProc
        command: [
            "python3",
            FileUtils.trimFileProtocol(`${Directories.scriptPath}/oci/vps_status.py`),
            "--instance", root.instanceName,
            "--profile", root.profile
        ]
        stdout: StdioCollector {
            id: statusCollector
            onStreamFinished: root.applyStatus(statusCollector.text)
        }
        onExited: (exitCode, exitStatus) => {
            root.loading = false
            if (exitCode !== 0 && root.lastError.length === 0) {
                root.available = false
                root.lastError = `vps_status.py exited ${exitCode}`
            }
        }
    }

    Process {
        id: actionProc
        stdout: StdioCollector {
            id: actionCollector
            onStreamFinished: root.applyActionResult(actionCollector.text)
        }
        onExited: (exitCode, exitStatus) => {
            root.actionPending = false
            root.pendingAction = ""
            if (exitCode !== 0 && root.lastError.length === 0)
                root.lastError = `the action exited ${exitCode}`
            // Settle the transitional state the API just reported.
            root.refresh()
        }
    }

    Timer {
        interval: root.pollInterval
        running: root.configured && root.enableService
        repeat: true
        triggeredOnStart: false
        onTriggered: root.refresh()
    }
}
