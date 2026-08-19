pragma ComponentBehavior: Bound
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import QtQuick
import QtQuick.Dialogs
import QtQuick.Layouts
import Quickshell
import Quickshell.Io

/**
 * Tailscale (tailnet) panel: connection toggle, exit node picker and device list.
 *
 * The UI is the left sidebar's own; every piece of tailnet state behind it comes
 * from the `Tailscale` singleton, which already owns the status polling, parsing
 * and privilege escalation for the right sidebar's quick toggle. The properties
 * below are the panel's view of that service - not a second copy of it.
 */
Item {
    id: root
    property real padding: Appearance.spacing.space100

    // ---------- state ----------
    // Devices arrive keyed by stable node ID so delegates update in place
    // instead of being recreated on every poll.
    readonly property var deviceMap: {
        const map = {}
        for (const device of Tailscale.devices)
            map[device.id] = device
        return map
    }
    readonly property var deviceIds: Tailscale.devices.map(device => device.id)
    readonly property int deviceCount: Tailscale.deviceCount
    readonly property bool statusReady: Tailscale.available
    readonly property bool isConnected: Tailscale.running
    readonly property string backendState: Tailscale.backendState
    readonly property int onlineCount: Tailscale.onlineCount
    readonly property string currentExitNode: Tailscale.currentExitNodeName
    readonly property var exitNodeOptions: Tailscale.exitNodes
    readonly property bool actionPending: Tailscale.commandPending
    readonly property int keyExpiryDays: Tailscale.keyExpiryDays
    property var pingResults: ({}) // nodeId -> latency text
    property string pendingSendTarget: ""

    // ---------- actions ----------
    function refreshStatus(): void {
        Tailscale.refresh()
    }

    function setExitNode(ip: string): void {
        if (ip.length > 0) Tailscale.setExitNode(ip)
        else Tailscale.clearExitNode()
    }

    function copyIP(ip: string): void {
        Quickshell.clipboardText = ip
    }

    function pingDevice(nodeId: string, target: string): void {
        if (target.length === 0 || pingProc.running) return
        root.setPingResult(nodeId, Translation.tr("Pinging..."))
        pingProc.nodeId = nodeId
        pingProc.exec(["tailscale", "ping", "-c", "1", target])
    }

    function setPingResult(nodeId: string, result: string): void {
        const update = {}
        update[nodeId] = result
        root.pingResults = Object.assign({}, root.pingResults, update)
    }

    function sendFile(target: string): void {
        root.pendingSendTarget = target
        sendFileDialog.open()
    }

    // Interactive by design: the login name differs per host, so it is asked for
    // in the terminal, with the last answer for that host offered back.
    function sshDevice(host: string): void {
        if (host.length === 0) return
        const stateFile = FileUtils.trimFileProtocol(Directories.state) + "/user/tailnet-ssh-users"
        const script = `
host=$1
state_file=$2
mkdir -p -- "\${state_file%/*}"
touch -- "$state_file"
saved=$(awk -v h="$host" '$1 == h { user=$2 } END { print user }' "$state_file")
read -r -e -i "\${saved:-$USER}" -p "[$host] SSH user: " user
[ -n "$user" ] || exit 0
awk -v h="$host" '$1 != h' "$state_file" > "$state_file.tmp"
printf '%s %s\\n' "$host" "$user" >> "$state_file.tmp"
mv -- "$state_file.tmp" "$state_file"
# This emulator's TERM means nothing to a host whose terminfo database has never
# heard of it, and curses programs there abort outright (clear, top, tmux). Hand
# the remote its own copy before the session starts. The name is passed in the
# command rather than read from the remote's environment: a command run over ssh
# gets no TTY, so sshd sets no TERM there at all.
term=\${TERM:-}
if [ -n "$term" ] && infocmp -x "$term" >/dev/null 2>&1; then
    infocmp -x "$term" 2>/dev/null \\
        | ssh "$user@$host" "infocmp '$term' >/dev/null 2>&1 || tic -x -" >/dev/null 2>&1
fi
ssh "$user@$host"
status=$?
if (( status != 0 )); then
    printf '\\n-- ssh failed, press any key to close --'
    read -rn1 -s
fi`
        const scriptArg = `'${StringUtils.shellSingleQuoteEscape(script)}'`
        const hostArg = `'${StringUtils.shellSingleQuoteEscape(host)}'`
        const stateArg = `'${StringUtils.shellSingleQuoteEscape(stateFile)}'`
        Quickshell.execDetached([
            "bash", "-lc",
            `${Config.options.apps.terminal} bash -lc ${scriptArg} _ ${hostArg} ${stateArg}`
        ])
    }

    // ---------- helpers ----------
    function formatBytes(bytes): string {
        return Tailscale.formatBytes(bytes)
    }

    function osIcon(os): string {
        switch ((os ?? "").toLowerCase()) {
            case "linux":   return "computer"
            case "windows": return "desktop_windows"
            case "macos":   return "laptop_mac"
            case "android": return "smartphone"
            case "ios":     return "phone_iphone"
            case "tvos":    return "tv"
            default:        return "device_unknown"
        }
    }

    function osName(os): string {
        switch ((os ?? "").toLowerCase()) {
            case "linux":   return "Linux"
            case "windows": return "Windows"
            case "macos":   return "macOS"
            case "android": return "Android"
            case "ios":     return "iOS"
            case "tvos":    return "tvOS"
            default:        return os || Translation.tr("Unknown")
        }
    }

    function timeAgo(iso): string {
        if (!iso || iso.startsWith("0001")) return ""
        const t = Date.parse(iso)
        if (isNaN(t)) return ""
        const mins = Math.floor((Date.now() - t) / 60000)
        if (mins < 1) return Translation.tr("just now")
        if (mins < 60) return Translation.tr("%1 min ago").arg(mins)
        const hrs = Math.floor(mins / 60)
        if (hrs < 24) return Translation.tr("%1 h ago").arg(hrs)
        return Translation.tr("%1 d ago").arg(Math.floor(hrs / 24))
    }

    function deviceTarget(device): string {
        if (!device) return ""
        return device.ip || device.dnsName || device.hostName || ""
    }

    Component.onCompleted: Tailscale.refresh()

    FileDialog {
        id: sendFileDialog
        title: Translation.tr("Send file via Taildrop")
        currentFolder: Directories.home
        nameFilters: [Translation.tr("All files (*)")]
        onAccepted: {
            const path = FileUtils.trimFileProtocol(selectedFile.toString())
            if (path.length === 0) return
            Tailscale.sendFile(path, root.pendingSendTarget)
        }
    }

    Process {
        id: pingProc
        property string nodeId: ""
        environment: ({ LANG: "C", LC_ALL: "C" })
        stdout: StdioCollector {
            id: pingCollector
            onStreamFinished: {
                if (pingProc.nodeId === "") return
                const m = pingCollector.text.match(/via (\S+) in ([\d.]+)ms/)
                let result = Translation.tr("No response")
                if (m) {
                    const via = m[1].startsWith("DERP(")
                        ? Translation.tr("relay %1").arg(m[1].slice(5, -1))
                        : Translation.tr("direct")
                    result = m[2] + " ms · " + via
                }
                root.setPingResult(pingProc.nodeId, result)
            }
        }
    }

    // ============= UI =============
    ColumnLayout {
        anchors {
            fill: parent
            margins: root.padding
        }
        spacing: root.padding

        // ---- header: status + connect switch ----
        Rectangle {
            Layout.fillWidth: true
            color: Appearance.colors.colLayer2
            radius: Appearance.rounding.normal
            implicitHeight: headerRow.implicitHeight + 20

            RowLayout {
                id: headerRow
                anchors {
                    left: parent.left
                    right: parent.right
                    verticalCenter: parent.verticalCenter
                    leftMargin: Appearance.spacing.space150
                    rightMargin: Appearance.spacing.space150
                }
                spacing: Appearance.spacing.space125

                Rectangle {
                    implicitWidth: 38
                    implicitHeight: 38
                    radius: Appearance.rounding.full
                    color: root.isConnected ? Appearance.colors.colPrimaryContainer : Appearance.colors.colSurfaceContainerHighest

                    Behavior on color {
                        animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                    }

                    CustomIcon {
                        anchors.centerIn: parent
                        width: 22
                        height: 22
                        source: "tailscale-symbolic.svg"
                        colorize: true
                        color: root.isConnected ? Appearance.colors.colOnPrimaryContainer : Appearance.colors.colSubtext

                        Behavior on color {
                            animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                        }
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Appearance.spacing.space25

                    StyledText {
                        Layout.fillWidth: true
                        text: "Tailscale"
                        font.pixelSize: Appearance.font.pixelSize.normal
                        color: Appearance.colors.colOnLayer2
                        elide: Text.ElideRight
                    }
                    StyledText {
                        Layout.fillWidth: true
                        text: {
                            if (!root.statusReady) return Translation.tr("Loading...")
                            if (root.actionPending) return Translation.tr("Working...")
                            if (root.isConnected) {
                                let s = Translation.tr("%1 of %2 devices online").arg(root.onlineCount).arg(root.deviceCount)
                                if (root.currentExitNode.length > 0)
                                    s += " • " + Translation.tr("via %1").arg(root.currentExitNode)
                                return s
                            }
                            return root.backendState === "Stopped"
                                ? Translation.tr("Disconnected")
                                : (root.backendState || Translation.tr("Unavailable"))
                        }
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: Appearance.colors.colSubtext
                        elide: Text.ElideRight
                    }
                    StyledText {
                        visible: root.keyExpiryDays >= 0 && root.keyExpiryDays <= 14
                        Layout.fillWidth: true
                        text: root.keyExpiryDays === 0
                            ? Translation.tr("Key expires today!")
                            : Translation.tr("Key expires in %1 day(s)").arg(root.keyExpiryDays)
                        font.pixelSize: Appearance.font.pixelSize.smallest
                        color: Appearance.m3colors.m3error
                        elide: Text.ElideRight
                    }
                }

                StyledSwitch {
                    id: connectSwitch
                    enabled: Tailscale.installed && !root.actionPending
                    checked: root.isConnected
                    // `checked` follows the daemon, so the switch must not move
                    // its own state - that write would destroy the binding.
                    checkable: false
                    onClicked: Tailscale.toggle()
                }
            }
        }

        // ---- exit node picker ----
        Rectangle {
            Layout.fillWidth: true
            visible: root.isConnected && root.exitNodeOptions.length > 0
            color: Appearance.colors.colLayer2
            radius: Appearance.rounding.normal
            implicitHeight: exitNodeCol.implicitHeight + 20

            ColumnLayout {
                id: exitNodeCol
                anchors {
                    left: parent.left
                    right: parent.right
                    verticalCenter: parent.verticalCenter
                    leftMargin: Appearance.spacing.space150
                    rightMargin: Appearance.spacing.space150
                }
                spacing: Appearance.spacing.space100

                RowLayout {
                    spacing: Appearance.spacing.space100
                    MaterialSymbol {
                        text: "alt_route"
                        iconSize: Appearance.font.pixelSize.larger
                        color: Appearance.colors.colOnLayer2
                    }
                    StyledText {
                        Layout.fillWidth: true
                        text: Translation.tr("Exit node")
                        font.pixelSize: Appearance.font.pixelSize.normal
                        color: Appearance.colors.colOnLayer2
                    }
                }

                Flow {
                    Layout.fillWidth: true
                    spacing: Appearance.spacing.space50

                    ExitNodePill {
                        label: Translation.tr("None")
                        showDot: false
                        selected: root.currentExitNode === ""
                        onClicked: root.setExitNode("")
                    }
                    Repeater {
                        model: root.exitNodeOptions
                        delegate: ExitNodePill {
                            required property var modelData
                            label: modelData.name
                            online: modelData.online
                            selected: modelData.name === root.currentExitNode
                            onClicked: root.setExitNode(modelData.name)
                        }
                    }
                }
            }
        }

        // ---- device list header ----
        RowLayout {
            Layout.fillWidth: true
            Layout.leftMargin: Appearance.spacing.space50
            Layout.rightMargin: Appearance.spacing.space50
            spacing: Appearance.spacing.space100

            StyledText {
                Layout.fillWidth: true
                text: Translation.tr("Devices")
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: Appearance.colors.colSubtext
            }
            GroupButton {
                baseWidth: 30
                baseHeight: 30
                buttonRadius: Appearance.rounding.full
                onClicked: root.refreshStatus()
                contentItem: MaterialSymbol {
                    anchors.centerIn: parent
                    horizontalAlignment: Text.AlignHCenter
                    text: "refresh"
                    iconSize: Appearance.font.pixelSize.large
                    color: Appearance.colors.colSubtext
                }
                StyledToolTip {
                    text: Translation.tr("Refresh device list")
                }
            }
        }

        // ---- device list ----
        StyledListView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: Appearance.spacing.space50
            animateAppearance: false

            model: ScriptModel {
                values: root.deviceIds
            }
            delegate: DeviceCard {
                required property var modelData
                device: root.deviceMap[modelData] ?? ({})
                anchors {
                    left: parent?.left
                    right: parent?.right
                }
            }
        }
    }

    // Placeholder when there is nothing to show
    StyledText {
        anchors.centerIn: parent
        visible: root.statusReady && root.deviceCount === 0
        text: Translation.tr("No devices")
        color: Appearance.colors.colSubtext
    }

    // ============= components =============
    // Icon action button styled like the notification action row
    component DeviceActionButton: RippleButton {
        id: actionBtn
        property string symbol
        property string tooltipText
        Layout.fillWidth: true
        implicitHeight: 30
        buttonRadius: Appearance.rounding.small
        colBackground: Appearance.colors.colLayer4
        colBackgroundHover: Appearance.colors.colLayer4Hover
        colRipple: Appearance.colors.colLayer4Active
        contentItem: MaterialSymbol {
            horizontalAlignment: Text.AlignHCenter
            text: actionBtn.symbol
            iconSize: Appearance.font.pixelSize.larger
            color: Appearance.m3colors.m3onSurface
        }
        StyledToolTip {
            text: actionBtn.tooltipText
        }
    }

    component ExitNodePill: RippleButton {
        id: pill
        property string label
        property bool selected: false
        property bool online: true
        property bool showDot: true

        // An offline pill is shown for awareness but can't be picked
        // (routing through a dead exit node kills connectivity)
        enabled: online || selected
        opacity: enabled ? 1 : 0.5
        toggled: selected
        pointingHandCursor: enabled
        buttonRadius: Appearance.rounding.full
        horizontalPadding: Appearance.spacing.space150
        verticalPadding: Appearance.spacing.space50
        implicitWidth: pillRow.implicitWidth + horizontalPadding * 2
        implicitHeight: pillRow.implicitHeight + verticalPadding * 2

        colBackground: Appearance.colors.colSurfaceContainerHighest
        colBackgroundHover: Appearance.colors.colSurfaceContainerHighestHover
        colRipple: Appearance.colors.colSurfaceContainerHighestActive

        contentItem: Row {
            id: pillRow
            anchors.centerIn: parent
            spacing: Appearance.spacing.space75

            Rectangle {
                visible: pill.showDot
                anchors.verticalCenter: parent.verticalCenter
                implicitWidth: 6
                implicitHeight: 6
                radius: Appearance.rounding.full
                color: !pill.online ? "transparent"
                    : pill.selected ? Appearance.colors.colOnPrimary : Appearance.colors.colPrimary
                border.width: pill.online ? 0 : 1
                border.color: pill.selected ? Appearance.colors.colOnPrimary : Appearance.m3colors.m3outline
            }
            StyledText {
                text: pill.label
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: pill.selected ? Appearance.colors.colOnPrimary : Appearance.colors.colOnLayer2
                Behavior on color {
                    animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                }
            }
        }
    }

    component DeviceCard: RippleButton {
        id: card
        required property var device
        property bool expanded: false
        readonly property bool online: card.device.online === true
        readonly property string target: root.deviceTarget(card.device)
        readonly property string connectionText: {
            if (!card.online) {
                const ago = root.timeAgo(card.device.lastSeen)
                return ago ? Translation.tr("Offline · seen %1").arg(ago) : Translation.tr("Offline")
            }
            if (card.device.isSelf) return Translation.tr("This device")
            if (card.device.currentAddress) return Translation.tr("Direct")
            if (card.device.relay) return Translation.tr("Relay (%1)").arg(card.device.relay)
            return Translation.tr("Connected")
        }

        onExpandedChanged: {
            // Auto-ping once when a peer card is opened
            if (expanded && card.online && !card.device.isSelf
                && !(root.pingResults[card.device.id] ?? ""))
                root.pingDevice(card.device.id, card.target)
        }

        horizontalPadding: Appearance.spacing.space150
        verticalPadding: Appearance.spacing.space125
        clip: true
        buttonRadius: Appearance.rounding.normal
        colBackground: card.expanded ? Appearance.colors.colLayer3 : Appearance.colors.colLayer2
        colBackgroundHover: card.expanded ? Appearance.colors.colLayer3Hover : Appearance.colors.colLayer2Hover
        colRipple: card.expanded ? Appearance.colors.colLayer3Active : Appearance.colors.colLayer2Active
        pointingHandCursor: true

        implicitHeight: cardCol.implicitHeight + verticalPadding * 2
        Behavior on implicitHeight {
            animation: Appearance.animation.elementMove.numberAnimation.createObject(this)
        }

        onClicked: card.expanded = !card.expanded
        altAction: () => card.expanded = !card.expanded

        contentItem: ColumnLayout {
            id: cardCol
            anchors {
                fill: parent
                topMargin: card.verticalPadding
                leftMargin: card.horizontalPadding
                rightMargin: card.horizontalPadding
            }
            spacing: Appearance.spacing.space0

            RowLayout {
                Layout.fillWidth: true
                spacing: Appearance.spacing.space125

                MouseArea {
                    implicitWidth: osIcon.implicitWidth
                    implicitHeight: osIcon.implicitHeight
                    hoverEnabled: true
                    property bool hovered: containsMouse

                    MaterialSymbol {
                        id: osIcon
                        text: root.osIcon(card.device.os)
                        iconSize: Appearance.font.pixelSize.huge
                        color: card.online ? Appearance.colors.colOnLayer2 : Appearance.colors.colSubtext
                    }
                    StyledToolTip {
                        text: root.osName(card.device.os)
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Appearance.spacing.space25

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Appearance.spacing.space75
                        StyledText {
                            text: card.device.name || card.device.hostName || ""
                            font.pixelSize: Appearance.font.pixelSize.normal
                            font.weight: card.device.isSelf ? Font.DemiBold : Font.Normal
                            color: card.online ? Appearance.colors.colOnLayer2 : Appearance.colors.colSubtext
                            elide: Text.ElideRight
                        }
                        MaterialSymbol {
                            visible: card.device.exitNodeOption === true
                            text: "alt_route"
                            iconSize: Appearance.font.pixelSize.small
                            color: Appearance.m3colors.m3tertiary
                        }
                        Item { Layout.fillWidth: true }
                    }
                    StyledText {
                        Layout.fillWidth: true
                        text: {
                            const parts = []
                            if (card.device.os) parts.push(root.osName(card.device.os))
                            if (card.device.ips?.length > 0) parts.push(card.device.ips[0])
                            parts.push(card.connectionText)
                            return parts.join(" • ")
                        }
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: Appearance.colors.colSubtext
                        elide: Text.ElideRight
                    }
                }

                // Online: filled dot. Offline: hollow ring.
                Rectangle {
                    implicitWidth: 10
                    implicitHeight: 10
                    radius: Appearance.rounding.full
                    color: card.online ? Appearance.colors.colPrimary : "transparent"
                    border.width: card.online ? 0 : 1.5
                    border.color: Appearance.m3colors.m3outline
                    Behavior on color {
                        animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                    }
                }

                MaterialSymbol {
                    text: "keyboard_arrow_down"
                    iconSize: Appearance.font.pixelSize.larger
                    color: Appearance.colors.colSubtext
                    rotation: card.expanded ? 180 : 0
                    Behavior on rotation {
                        animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                    }
                }
            }

            // ---- expanded details ----
            ColumnLayout {
                visible: card.expanded
                Layout.fillWidth: true
                Layout.topMargin: Appearance.spacing.space100
                spacing: Appearance.spacing.space75

                StyledText {
                    visible: (card.device.dnsName?.length ?? 0) > 0
                    Layout.fillWidth: true
                    text: card.device.dnsName || ""
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: Appearance.colors.colSubtext
                    elide: Text.ElideMiddle
                }
                RowLayout {
                    spacing: Appearance.spacing.space150
                    StyledText {
                        visible: (root.pingResults[card.device.id] ?? "").length > 0
                        text: Translation.tr("Ping: %1").arg(root.pingResults[card.device.id] ?? "")
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: Appearance.colors.colSubtext
                    }
                    StyledText {
                        visible: card.online && (card.device.rxBytes > 0 || card.device.txBytes > 0)
                        text: "↓ " + root.formatBytes(card.device.rxBytes) + "   ↑ " + root.formatBytes(card.device.txBytes)
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: Appearance.colors.colSubtext
                    }
                }

                RowLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: Appearance.spacing.space25
                    spacing: Appearance.spacing.space50

                    DeviceActionButton {
                        id: copyIpButton
                        visible: card.device.ips?.length > 0
                        symbol: "content_copy"
                        tooltipText: Translation.tr("Copy IP")
                        onClicked: {
                            root.copyIP(card.device.ips[0])
                            copyIpButton.symbol = "inventory"
                            copyIpResetTimer.restart()
                        }
                        Timer {
                            id: copyIpResetTimer
                            interval: 1500
                            repeat: false
                            onTriggered: copyIpButton.symbol = "content_copy"
                        }
                    }
                    DeviceActionButton {
                        visible: card.online && !card.device.isSelf
                        symbol: "network_check"
                        tooltipText: Translation.tr("Ping")
                        onClicked: root.pingDevice(card.device.id, card.target)
                    }
                    DeviceActionButton {
                        visible: card.online && !card.device.isSelf && card.device.os === "linux"
                        symbol: "terminal"
                        tooltipText: Translation.tr("SSH")
                        onClicked: root.sshDevice(card.target)
                    }
                    DeviceActionButton {
                        visible: card.online && !card.device.isSelf
                        symbol: "send"
                        tooltipText: Translation.tr("Send file")
                        onClicked: root.sendFile(card.target)
                    }
                }
            }

            Item { Layout.fillHeight: true }
        }
    }
}
