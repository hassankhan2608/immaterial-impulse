pragma Singleton
pragma ComponentBehavior: Bound

import Quickshell
import Quickshell.Io
import QtQuick
import qs.modules.common
import qs.modules.common.functions

/**
 * Tailscale state and control (CLI-backed, like Vpn.qml is for nmcli).
 *
 * Detection is two-staged: `installed` (binary on PATH, checked once at
 * startup) gates everything else, and `available` (the daemon answered the
 * last `tailscale status --json` poll) tracks whether tailscaled is up.
 * UI should hide entirely when !installed and degrade when !available.
 *
 * Exposes the peers that advertise themselves as exit nodes and which one
 * (if any) is currently in use. Selecting one runs `tailscale set
 * --exit-node=…`; toggling runs `tailscale up` / `tailscale down`. On
 * machines where the user is not the Tailscale operator the plain command is
 * denied, so a failed command is retried once through `pkexec` (a polkit
 * prompt). Running `sudo tailscale set --operator=$USER` once makes it
 * seamless.
 *
 * Every invocation is built as an argv array; values are never spliced into
 * a shell string.
 */
Singleton {
    id: root

    readonly property int pollInterval: Config.options.networking?.tailscale?.pollInterval ?? 5000
    readonly property bool enableService: Config.options.networking?.tailscale?.enable ?? true

    property bool installed: false
    property bool available: false
    property bool running: false
    property string backendState: ""
    property string currentExitNodeId: ""
    property var exitNodes: []
    property var devices: []
    property int keyExpiryDays: -1

    property var incomingFiles: []
    property bool receivingFiles: false
    property string activeTransferName: ""
    // Received files land beside every other download, not in a folder of
    // their own at the top of $HOME.
    readonly property string taildropTargetDir: FileUtils.trimFileProtocol(Directories.downloads) + "/Taildrop"
    readonly property string taildropDisplayDir: root.taildropTargetDir.replace(Quickshell.env("HOME") ?? "", "~")

    readonly property int deviceCount: root.devices.length
    readonly property int onlineCount: root.devices.filter(device => device.online).length
    readonly property int incomingFileCount: root.incomingFiles.length
    readonly property bool commandPending: cmdProc.running
    readonly property bool sendingFile: fileSendProc.running
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

    function refresh(): void {
        if (!root.enableService || !root.installed || statusProc.running) return
        statusProc.running = true
    }

    function refreshIncomingFiles(): void {
        if (!root.enableService || !root.installed || incomingFilesProc.running) return
        incomingFilesProc.running = true
    }

    function toggle(): void {
        root.runCommand(["tailscale", root.running ? "down" : "up"])
    }

    function setExitNode(ip: string): void {
        if (!ip) return
        root.runCommand(["tailscale", "set", `--exit-node=${ip}`, "--exit-node-allow-lan-access=true"])
    }

    function clearExitNode(): void {
        root.runCommand(["tailscale", "set", "--exit-node="])
    }

    function sendFile(path: string, target: string): void {
        if (!path || !target || fileSendProc.running) return
        root.activeTransferName = path.split("/").pop()
        fileSendProc.exec(["tailscale", "file", "cp", path, target + ":"])
        root.notify(Translation.tr("Taildrop"), Translation.tr("Sending %1...").arg(root.activeTransferName))
    }

    function receiveAllFiles(): void {
        if (root.receivingFiles) return
        root.receivingFiles = true
        root.activeTransferName = ""
        receiveAllProc.exec([
            "bash", "-c",
            "mkdir -p -- \"$1\" && exec tailscale file get --conflict=rename --verbose \"$1\"",
            "_", root.taildropTargetDir
        ])
    }

    function receiveFile(name: string): void {
        if (!name || root.receivingFiles) return
        root.receivingFiles = true
        root.activeTransferName = name
        const url = "http://local-tailscaled.sock/localapi/v0/files/" + encodeURIComponent(name)
        receiveFileProc.exec([
            "bash", "-c",
            "set -e; d=$1; n=${2##*/}; url=$3; [ -n \"$n\" ]; mkdir -p -- \"$d\"; " +
                "out=\"$d/$n\"; [ ! -e \"$out\" ] || out=\"$d/$(date +%s)-$n\"; " +
                "curl -fSs --unix-socket /var/run/tailscale/tailscaled.sock -o \"$out\" \"$url\"; " +
                "curl -fSs -X DELETE --unix-socket /var/run/tailscale/tailscaled.sock \"$url\"",
            "_", root.taildropTargetDir, name, url
        ])
    }

    function runCommand(argv: var): void {
        if (cmdProc.running) return
        root.pendingCommand = argv
        root.triedPkexec = false
        cmdProc.exec(argv)
    }

    function notify(summary: string, body: string): void {
        Quickshell.execDetached(["notify-send", summary, body, "-a", "Shell"])
    }

    property var pendingCommand: []
    property bool triedPkexec: false

    Process {
        id: cmdProc
        environment: ({
            LANG: "C",
            LC_ALL: "C"
        })
        stderr: StdioCollector {
            id: cmdErr
        }
        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0 && !root.triedPkexec) {
                root.triedPkexec = true
                cmdProc.exec(["pkexec", ...root.pendingCommand])
                return
            }
            if (exitCode !== 0)
                root.notify(Translation.tr("Tailscale"), cmdErr.text.trim() || Translation.tr("Tailscale command failed"))
            root.refresh()
        }
    }

    Process {
        id: whichProc
        running: root.enableService
        command: ["sh", "-c", "command -v tailscale"]
        onExited: (exitCode, exitStatus) => {
            root.installed = exitCode === 0
            if (root.installed) {
                root.refresh()
                root.refreshIncomingFiles()
            }
        }
    }

    Process {
        id: statusProc
        environment: ({
            LANG: "C",
            LC_ALL: "C"
        })
        command: ["tailscale", "status", "--json"]
        stdout: StdioCollector {
            id: statusOutput
        }
        onExited: (exitCode, exitStatus) => root.applyStatus(exitCode === 0 ? statusOutput.text : "")
    }

    Process {
        id: incomingFilesProc
        command: [
            "curl", "-fSs",
            "--unix-socket", "/var/run/tailscale/tailscaled.sock",
            "http://local-tailscaled.sock/localapi/v0/files/"
        ]
        stdout: StdioCollector {
            id: incomingFilesOutput
        }
        onExited: (exitCode, exitStatus) => {
            root.incomingFiles = exitCode === 0
                ? root.parseIncomingFiles(incomingFilesOutput.text)
                : []
        }
    }

    Process {
        id: fileSendProc
        stderr: StdioCollector {
            id: fileSendError
        }
        onExited: (exitCode, exitStatus) => {
            root.notify(
                exitCode === 0 ? Translation.tr("File sent") : Translation.tr("File send failed"),
                exitCode === 0 ? root.activeTransferName : (fileSendError.text.trim() || root.activeTransferName)
            )
        }
    }

    Process {
        id: receiveAllProc
        stdout: StdioCollector {
            id: receiveAllOutput
        }
        stderr: StdioCollector {
            id: receiveAllError
        }
        onExited: (exitCode, exitStatus) => {
            root.receivingFiles = false
            const output = (receiveAllOutput.text + "\n" + receiveAllError.text).trim()
            root.notify(
                exitCode === 0 ? Translation.tr("Taildrop") : Translation.tr("Taildrop receive failed"),
                output || (exitCode === 0
                    ? Translation.tr("Files received into %1").arg(root.taildropDisplayDir)
                    : Translation.tr("Unknown error"))
            )
            root.refreshIncomingFiles()
        }
    }

    Process {
        id: receiveFileProc
        stderr: StdioCollector {
            id: receiveFileError
        }
        onExited: (exitCode, exitStatus) => {
            root.receivingFiles = false
            root.notify(
                exitCode === 0 ? Translation.tr("Taildrop") : Translation.tr("Taildrop receive failed"),
                exitCode === 0
                    ? Translation.tr("Received %1 into %2").arg(root.activeTransferName).arg(root.taildropDisplayDir)
                    : (receiveFileError.text.trim() || Translation.tr("Failed to receive %1").arg(root.activeTransferName))
            )
            root.refreshIncomingFiles()
        }
    }

    Timer {
        interval: root.pollInterval
        running: root.enableService && root.installed
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refresh()
    }

    Timer {
        interval: 30000
        running: root.enableService && root.installed
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refreshIncomingFiles()
    }
}
