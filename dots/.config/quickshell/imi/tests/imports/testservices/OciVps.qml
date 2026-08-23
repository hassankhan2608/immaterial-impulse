pragma Singleton
pragma ComponentBehavior: Bound

import Quickshell
import QtQuick

// Logic-only double of services/OciVps.qml. applyStatus(), applyActionResult(),
// the formatters and every derived property are kept byte-for-byte in sync with
// the real service; the Process/Timer I/O is omitted so tests stay deterministic
// and offline.
Singleton {
    id: root

    property bool configured: false
    property bool available: false
    property bool loading: false
    property string lastError: ""
    property string generatedAt: ""

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

    property real cpuPercent: -1
    property real memoryPercent: -1
    property real loadAverage: -1
    property real netInRate: -1
    property real netOutRate: -1
    property real diskReadRate: -1
    property real diskWriteRate: -1

    property var ocpuMeter: ({})
    property var memoryMeter: ({})
    property var egressMeter: ({})

    property real bootSizeGb: 0
    property real bootVpusPerGb: 0
    property bool bootVpuBillable: false
    property real blockGb: 0
    property real allocatedGb: 0
    property real allocationLimitGb: 0
    property real allocationPercent: 0
    property bool allocationFull: false

    property var dailyOcpu: []
    property var dailyEgress: []
    property var skus: []

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

    readonly property bool running: root.state === "RUNNING"
    readonly property bool hasLiveMetrics: root.cpuPercent >= 0

    property bool actionPending: false
    property string pendingAction: ""
    readonly property bool inTransition: ["STARTING", "STOPPING", "CREATING_IMAGE"].includes(root.state)
    readonly property bool canStart: root.available && root.state === "STOPPED" && !root.actionPending
    readonly property bool canStop: root.available && root.running && !root.actionPending
    readonly property bool canReboot: root.available && root.running && !root.actionPending

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
}
