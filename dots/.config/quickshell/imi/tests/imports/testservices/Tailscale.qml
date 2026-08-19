pragma Singleton
pragma ComponentBehavior: Bound

import Quickshell
import QtQuick

// Logic-only double of services/Tailscale.qml. firstIpv4()/parseStatus() and
// the derived state properties are kept byte-for-byte in sync with the real
// service; the CLI Process/Timer I/O is omitted so tests stay deterministic
// and offline.
Singleton {
    id: root

    property bool installed: false
    property bool available: false
    property bool running: false
    property string backendState: ""
    property string currentExitNodeId: ""
    property var exitNodes: []
    property var devices: []
    property int keyExpiryDays: -1

    readonly property int deviceCount: root.devices.length
    readonly property int onlineCount: root.devices.filter(device => device.online).length
    readonly property bool exitNodeActive: root.currentExitNodeId.length > 0
    readonly property string currentExitNodeName: root.exitNodes.find(node => node.active)?.name ?? ""
    readonly property string materialSymbol: !root.running ? "vpn_key_off" : root.exitNodeActive ? "vpn_lock" : "vpn_key"

    function firstIpv4(ips: var): string {
        if (!ips || ips.length === 0) return ""
        for (const ip of ips) {
            const bare = ip.split("/")[0]
            if (!bare.includes(":")) return bare
        }
        return ips[0].split("/")[0]
    }

    function cleanDnsName(name: string): string {
        return (name ?? "").replace(/\.$/, "")
    }

    function deviceName(node: var): string {
        const hostName = node?.HostName ?? ""
        if (hostName.length > 0) return hostName
        return root.cleanDnsName(node?.DNSName ?? "").split(".")[0]
    }

    function daysUntil(isoDate: string, nowMs: double): int {
        if (!isoDate) return -1
        const expiryMs = Date.parse(isoDate)
        if (isNaN(expiryMs)) return -1
        const remainingMs = expiryMs - (nowMs ?? Date.now())
        return remainingMs < 0 ? -1 : Math.ceil(remainingMs / 86400000)
    }

    function parseDevice(node: var, isSelf: bool, backendRunning: bool, exitNodeId: string): var {
        const ips = node?.TailscaleIPs ?? []
        const id = node?.ID ?? ""
        return {
            id: id,
            isSelf: isSelf,
            hostName: node?.HostName ?? "",
            name: root.deviceName(node),
            dnsName: root.cleanDnsName(node?.DNSName ?? ""),
            ips: ips,
            ip: root.firstIpv4(ips),
            online: node?.Online === true || (isSelf && backendRunning),
            os: node?.OS ?? "",
            exitNode: node?.ExitNode === true || (exitNodeId.length > 0 && id === exitNodeId),
            exitNodeOption: node?.ExitNodeOption === true,
            relay: isSelf ? "" : (node?.Relay ?? ""),
            currentAddress: isSelf ? "" : (node?.CurAddr ?? ""),
            lastSeen: isSelf ? "" : (node?.LastSeen ?? ""),
            rxBytes: node?.RxBytes ?? 0,
            txBytes: node?.TxBytes ?? 0
        }
    }

    function parseStatus(text: string): var {
        const trimmed = (text ?? "").trim()
        if (trimmed.length === 0) return null
        let data
        try {
            data = JSON.parse(trimmed)
        } catch (e) {
            return null
        }
        if (!data || typeof data !== "object") return null

        const backendState = data.BackendState ?? ""
        const backendRunning = backendState === "Running"
        const exitId = data.ExitNodeStatus?.ID ?? ""
        const devices = []
        const nodes = []

        if (data.Self)
            devices.push(root.parseDevice(data.Self, true, backendRunning, exitId))

        const peers = data.Peer ?? {}
        for (const key in peers) {
            const peer = peers[key]
            const device = root.parseDevice(peer, false, backendRunning, exitId)
            devices.push(device)
            if (!device.exitNodeOption) continue
            nodes.push({
                id: device.id,
                name: device.name,
                ip: device.ip,
                online: device.online,
                active: device.exitNode
            })
        }

        devices.sort((a, b) => {
            if (a.online !== b.online) return a.online ? -1 : 1
            if (a.isSelf !== b.isSelf) return a.isSelf ? -1 : 1
            return a.name.localeCompare(b.name)
        })
        nodes.sort((a, b) => {
            if (a.online !== b.online) return a.online ? -1 : 1
            return a.name.localeCompare(b.name)
        })

        let currentId = exitId
        if (currentId.length === 0)
            currentId = nodes.find(node => node.active)?.id ?? ""

        return {
            backendState: backendState,
            running: backendRunning,
            currentExitNodeId: currentId,
            exitNodes: nodes,
            devices: devices,
            keyExpiryDays: root.daysUntil(data.Self?.KeyExpiry ?? "", Date.now())
        }
    }

    function parseIncomingFiles(text: string): var {
        try {
            const files = JSON.parse(text || "null")
            return Array.isArray(files) ? files : []
        } catch (e) {
            return []
        }
    }

    function formatBytes(bytes: var): string {
        if (bytes === undefined || bytes === null || bytes < 0) return "-"
        if (bytes === 0) return "0 B"
        const units = ["B", "KB", "MB", "GB", "TB"]
        let index = 0
        let value = bytes
        while (value >= 1024 && index < units.length - 1) {
            value /= 1024
            index++
        }
        return value.toFixed(index === 0 ? 0 : 1) + " " + units[index]
    }

    function applyStatus(text: string): void {
        const status = root.parseStatus(text)
        if (status === null) {
            root.available = false
            root.running = false
            root.backendState = ""
            root.currentExitNodeId = ""
            root.exitNodes = []
            root.devices = []
            root.keyExpiryDays = -1
            return
        }
        root.available = true
        root.backendState = status.backendState
        root.running = status.running
        root.currentExitNodeId = status.currentExitNodeId
        root.exitNodes = status.exitNodes
        root.devices = status.devices
        root.keyExpiryDays = status.keyExpiryDays
    }
}
