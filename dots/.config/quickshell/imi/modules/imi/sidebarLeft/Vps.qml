pragma ComponentBehavior: Bound
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.common.functions
import QtQuick
import QtQuick.Layouts
import Qt5Compat.GraphicalEffects

/**
 * Oracle Cloud VPS panel: what the box is, what it is doing, and how much of
 * the Always Free allowance the month has spent.
 *
 * Every figure comes from the `OciVps` singleton, which reads Oracle's own
 * metered quantities rather than multiplying the current shape by elapsed time.
 * That distinction is the reason the allowance section leads with a graph: an
 * instance resized mid-month draws a step, and a panel that inferred usage from
 * the shape running now would draw a straight line at the wrong height.
 */
Item {
    id: root
    // Which destructive action is armed and waiting for its second tap, if any.
    property string armed: ""
    // Which series the shared graph well is drawing.
    property bool graphEgress: false
    // Whether the metered SKU list is unfolded.
    property bool skusExpanded: false
    property real padding: Appearance.spacing.space100

    readonly property bool ready: OciVps.available
    readonly property string worstStatus: OciVps.worstStatus

    /**
     * The palette for an allowance's four bands. Amber and red are the theme's
     * own error/tertiary roles rather than literal colours, so a light theme
     * gets a legible warning instead of a fixed dark-theme yellow.
     */
    function statusColor(status: string): color {
        switch (status) {
        case "over": return Appearance.colors.colError
        case "critical": return Appearance.colors.colError
        case "watch": return Appearance.colors.colTertiary
        default: return Appearance.colors.colPrimary
        }
    }

    function statusLabel(status: string): string {
        switch (status) {
        case "over": return Translation.tr("Over limit")
        case "critical": return Translation.tr("Watch closely")
        case "watch": return Translation.tr("Watch")
        default: return Translation.tr("Safe")
        }
    }

    // ---------- reusable pieces ----------

    // One allowance: what is spent, the bar, and where the month lands if
    // nothing changes. The projection is the number that actually decides
    // whether to shut something down, so it is never hidden behind a hover.
    component Meter: ColumnLayout {
        id: meterRoot
        required property string label
        required property var meter
        required property string formatted
        required property string formattedLimit
        required property string projected

        Layout.fillWidth: true
        spacing: Appearance.spacing.space50

        RowLayout {
            Layout.fillWidth: true
            spacing: Appearance.spacing.space100

            StyledText {
                Layout.fillWidth: true
                text: meterRoot.label
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: Appearance.colors.colSubtext
            }
            StyledText {
                text: `${meterRoot.formatted} / ${meterRoot.formattedLimit}`
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: Appearance.colors.colOnLayer2
            }
        }

        Rectangle {
            id: track
            Layout.fillWidth: true
            implicitHeight: 8
            radius: Appearance.rounding.full
            color: Appearance.colors.colSecondaryContainer

            Rectangle {
                width: Math.max(0, Math.min(1, (meterRoot.meter?.percent ?? 0) / 100)) * track.width
                height: parent.height
                radius: parent.radius
                color: root.statusColor(meterRoot.meter?.status ?? "safe")

                Behavior on width {
                    animation: Appearance.animation.elementMoveFast.numberAnimation.createObject(this)
                }
                Behavior on color {
                    animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                }
            }
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: Appearance.spacing.space100

            StyledText {
                text: `${(meterRoot.meter?.percent ?? 0).toFixed(1)}%`
                font.pixelSize: Appearance.font.pixelSize.smallie
                color: Appearance.colors.colSubtext
            }
            Item { Layout.fillWidth: true }
            StyledText {
                text: Translation.tr("month-end ~%1 (%2%)")
                    .arg(meterRoot.projected)
                    .arg((meterRoot.meter?.projectedPercent ?? 0).toFixed(0))
                font.pixelSize: Appearance.font.pixelSize.smallie
                color: root.statusColor(meterRoot.meter?.projectedStatus ?? "safe")
            }
        }
    }

    // A live reading from Monitoring. Absent is drawn as a dash, because a
    // reading of zero and an agent that stopped reporting are different facts.
    component StatTile: Rectangle {
        id: tileRoot
        required property string symbol
        required property string label
        required property real value
        required property string suffix

        Layout.fillWidth: true
        implicitHeight: 64
        radius: Appearance.rounding.small
        color: Appearance.colors.colLayer1

        ColumnLayout {
            anchors.centerIn: parent
            spacing: Appearance.spacing.space25

            MaterialSymbol {
                Layout.alignment: Qt.AlignHCenter
                text: tileRoot.symbol
                iconSize: Appearance.font.pixelSize.large
                color: Appearance.colors.colSubtext
            }
            StyledText {
                Layout.alignment: Qt.AlignHCenter
                text: tileRoot.value < 0 ? "-" : tileRoot.value.toFixed(1) + tileRoot.suffix
                font.pixelSize: Appearance.font.pixelSize.normal
                color: Appearance.colors.colOnLayer1
            }
            StyledText {
                Layout.alignment: Qt.AlignHCenter
                text: tileRoot.label
                font.pixelSize: Appearance.font.pixelSize.smallie
                color: Appearance.colors.colSubtext
            }
        }
    }

    Component.onCompleted: OciVps.refresh()

    // ============= UI =============
    ColumnLayout {
        anchors {
            fill: parent
            margins: root.padding
        }
        spacing: root.padding

        // ---- header: instance identity and overall verdict ----
        Rectangle {
            Layout.fillWidth: true
            color: Appearance.colors.colLayer2
            radius: Appearance.rounding.normal
            implicitHeight: headerRow.implicitHeight + Appearance.spacing.space250

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
                    color: root.ready && root.worstStatus === "safe"
                        ? Appearance.colors.colPrimaryContainer
                        : root.ready ? Appearance.colors.colErrorContainer
                        : Appearance.colors.colSurfaceContainerHighest

                    Behavior on color {
                        animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this)
                    }

                    MaterialSymbol {
                        anchors.centerIn: parent
                        text: OciVps.materialSymbol
                        iconSize: Appearance.font.pixelSize.huge
                        color: root.ready && root.worstStatus === "safe"
                            ? Appearance.colors.colOnPrimaryContainer
                            : root.ready ? Appearance.colors.colOnErrorContainer
                            : Appearance.colors.colSubtext
                    }
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Appearance.spacing.space25

                    StyledText {
                        Layout.fillWidth: true
                        text: OciVps.name.length > 0 ? OciVps.name : Translation.tr("Oracle Cloud")
                        font.pixelSize: Appearance.font.pixelSize.normal
                        color: Appearance.colors.colOnLayer2
                        elide: Text.ElideRight
                    }
                    StyledText {
                        Layout.fillWidth: true
                        text: !OciVps.configured ? Translation.tr("No API key in ~/.oci/config")
                            : !root.ready ? (OciVps.lastError.length > 0 ? OciVps.lastError : Translation.tr("Loading..."))
                            : `${OciVps.ocpus} OCPU · ${OciVps.memoryGb} GB · ${OciVps.region}`
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: Appearance.colors.colSubtext
                        elide: Text.ElideRight
                    }
                }

                Rectangle {
                    visible: root.ready
                    implicitWidth: stateText.implicitWidth + Appearance.spacing.space150
                    implicitHeight: 24
                    radius: Appearance.rounding.full
                    color: OciVps.running ? Appearance.colors.colPrimaryContainer : Appearance.colors.colSurfaceContainerHighest

                    StyledText {
                        id: stateText
                        anchors.centerIn: parent
                        text: OciVps.state
                        font.pixelSize: Appearance.font.pixelSize.smallie
                        color: OciVps.running ? Appearance.colors.colOnPrimaryContainer : Appearance.colors.colSubtext
                    }
                }

                GroupButton {
                    baseWidth: 30
                    baseHeight: 30
                    buttonRadius: Appearance.rounding.full
                    enabled: OciVps.configured && !OciVps.loading
                    onClicked: OciVps.refresh()
                    contentItem: MaterialSymbol {
                        anchors.centerIn: parent
                        horizontalAlignment: Text.AlignHCenter
                        text: OciVps.loading ? "progress_activity" : "refresh"
                        iconSize: Appearance.font.pixelSize.large
                        color: Appearance.colors.colSubtext
                    }
                    StyledToolTip {
                        text: Translation.tr("Refresh from Oracle")
                    }
                }
            }
        }

        // ---- lifecycle actions ----
        // Two taps for anything destructive: the first arms, the second sends.
        // A sidebar is an easy place to brush against a button, and this box
        // serves things.
        Rectangle {
            Layout.fillWidth: true
            visible: root.ready
            color: Appearance.colors.colLayer2
            radius: Appearance.rounding.normal
            implicitHeight: actionsColumn.implicitHeight + Appearance.spacing.space250

            ColumnLayout {
                id: actionsColumn
                anchors {
                    left: parent.left
                    right: parent.right
                    verticalCenter: parent.verticalCenter
                    leftMargin: Appearance.spacing.space150
                    rightMargin: Appearance.spacing.space150
                }
                spacing: Appearance.spacing.space100

                RowLayout {
                    Layout.fillWidth: true
                    visible: root.armed.length === 0
                    spacing: Appearance.spacing.space100

                    StyledText {
                        Layout.fillWidth: true
                        text: OciVps.actionPending
                            ? Translation.tr("Sending %1...").arg(OciVps.pendingAction)
                            : OciVps.inTransition ? OciVps.state
                            : Translation.tr("Power")
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: Appearance.colors.colSubtext
                        elide: Text.ElideRight
                    }

                    GroupButton {
                        baseWidth: 34
                        baseHeight: 30
                        buttonRadius: Appearance.rounding.full
                        enabled: OciVps.canStart
                        onClicked: OciVps.performAction("start")
                        contentItem: MaterialSymbol {
                            anchors.centerIn: parent
                            horizontalAlignment: Text.AlignHCenter
                            text: "play_arrow"
                            iconSize: Appearance.font.pixelSize.large
                            color: Appearance.colors.colSubtext
                        }
                        StyledToolTip { text: Translation.tr("Start the instance") }
                    }
                    GroupButton {
                        baseWidth: 34
                        baseHeight: 30
                        buttonRadius: Appearance.rounding.full
                        enabled: OciVps.canReboot
                        onClicked: root.armed = "reboot"
                        contentItem: MaterialSymbol {
                            anchors.centerIn: parent
                            horizontalAlignment: Text.AlignHCenter
                            text: "restart_alt"
                            iconSize: Appearance.font.pixelSize.large
                            color: Appearance.colors.colSubtext
                        }
                        StyledToolTip { text: Translation.tr("Reboot gracefully") }
                    }
                    GroupButton {
                        baseWidth: 34
                        baseHeight: 30
                        buttonRadius: Appearance.rounding.full
                        enabled: OciVps.canStop
                        onClicked: root.armed = "stop"
                        contentItem: MaterialSymbol {
                            anchors.centerIn: parent
                            horizontalAlignment: Text.AlignHCenter
                            text: "power_settings_new"
                            iconSize: Appearance.font.pixelSize.large
                            color: Appearance.colors.colError
                        }
                        StyledToolTip { text: Translation.tr("Shut down gracefully") }
                    }
                }

                // ---- armed: the confirm row replaces the buttons in place ----
                RowLayout {
                    Layout.fillWidth: true
                    visible: root.armed.length > 0
                    spacing: Appearance.spacing.space100

                    StyledText {
                        Layout.fillWidth: true
                        text: root.armed === "stop"
                            ? Translation.tr("Shut down %1?").arg(OciVps.name)
                            : Translation.tr("Reboot %1?").arg(OciVps.name)
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: Appearance.colors.colOnLayer2
                        elide: Text.ElideRight
                    }
                    GroupButton {
                        baseHeight: 30
                        buttonRadius: Appearance.rounding.full
                        onClicked: root.armed = ""
                        contentItem: StyledText {
                            anchors.centerIn: parent
                            text: Translation.tr("Cancel")
                            font.pixelSize: Appearance.font.pixelSize.smaller
                            color: Appearance.colors.colSubtext
                        }
                    }
                    GroupButton {
                        baseHeight: 30
                        buttonRadius: Appearance.rounding.full
                        colBackground: Appearance.colors.colErrorContainer
                        onClicked: {
                            OciVps.performAction(root.armed)
                            root.armed = ""
                        }
                        contentItem: StyledText {
                            anchors.centerIn: parent
                            text: root.armed === "stop" ? Translation.tr("Shut down") : Translation.tr("Reboot")
                            font.pixelSize: Appearance.font.pixelSize.smaller
                            color: Appearance.colors.colOnErrorContainer
                        }
                    }
                }
            }
        }

        // ---- always free allowance ----
        Rectangle {
            Layout.fillWidth: true
            visible: root.ready
            color: Appearance.colors.colLayer2
            radius: Appearance.rounding.normal
            implicitHeight: allowanceColumn.implicitHeight + Appearance.spacing.space300

            ColumnLayout {
                id: allowanceColumn
                anchors {
                    left: parent.left
                    right: parent.right
                    verticalCenter: parent.verticalCenter
                    leftMargin: Appearance.spacing.space150
                    rightMargin: Appearance.spacing.space150
                }
                spacing: Appearance.spacing.space125

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Appearance.spacing.space100

                    StyledText {
                        Layout.fillWidth: true
                        text: Translation.tr("Always Free this month")
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: Appearance.colors.colOnLayer2
                    }
                    Rectangle {
                        implicitWidth: verdictText.implicitWidth + Appearance.spacing.space150
                        implicitHeight: 22
                        radius: Appearance.rounding.full
                        color: ColorUtils.transparentize(root.statusColor(root.worstStatus), 0.85)

                        StyledText {
                            id: verdictText
                            anchors.centerIn: parent
                            text: root.statusLabel(root.worstStatus)
                            font.pixelSize: Appearance.font.pixelSize.smallie
                            color: root.statusColor(root.worstStatus)
                        }
                    }
                }

                Meter {
                    label: Translation.tr("OCPU-hours")
                    meter: OciVps.ocpuMeter
                    formatted: OciVps.formatHours(OciVps.ocpuMeter?.used ?? 0)
                    formattedLimit: OciVps.formatHours(OciVps.ocpuMeter?.limit ?? 0)
                    projected: OciVps.formatHours(OciVps.ocpuMeter?.projected ?? 0)
                }

                Meter {
                    label: Translation.tr("Memory GB-hours")
                    meter: OciVps.memoryMeter
                    formatted: OciVps.formatHours(OciVps.memoryMeter?.used ?? 0)
                    formattedLimit: OciVps.formatHours(OciVps.memoryMeter?.limit ?? 0)
                    projected: OciVps.formatHours(OciVps.memoryMeter?.projected ?? 0)
                }

                // ---- daily OCPU-hours, where a resize reads as a step ----
                ColumnLayout {
                    Layout.fillWidth: true
                    visible: OciVps.dailyOcpuNormalized.length > 1
                    spacing: Appearance.spacing.space50

                    Rectangle {
                        id: graphWell
                        Layout.fillWidth: true
                        implicitHeight: 48
                        radius: Appearance.rounding.small
                        color: Appearance.colors.colSecondaryContainer
                        layer.enabled: true
                        layer.effect: OpacityMask {
                            maskSource: Rectangle {
                                width: graphWell.width
                                height: graphWell.height
                                radius: graphWell.radius
                            }
                        }

                        Graph {
                            anchors.fill: parent
                            values: root.graphEgress ? OciVps.dailyEgressNormalized : OciVps.dailyOcpuNormalized
                            color: root.graphEgress
                                ? root.statusColor(OciVps.egressMeter?.status ?? "safe")
                                : root.statusColor(OciVps.ocpuMeter?.status ?? "safe")
                            alignment: Graph.Alignment.Left
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Appearance.spacing.space100

                        StyledText {
                            Layout.fillWidth: true
                            text: root.graphEgress
                                ? Translation.tr("Daily egress · peak %1").arg(OciVps.formatGb(OciVps.dailyEgressPeak))
                                : Translation.tr("Daily OCPU-hours · peak %1").arg(OciVps.formatHours(OciVps.dailyOcpuPeak))
                            font.pixelSize: Appearance.font.pixelSize.smallie
                            color: Appearance.colors.colSubtext
                            elide: Text.ElideRight
                        }

                        // Two series share one well; the chips say which is drawn.
                        GroupButton {
                            baseHeight: 22
                            buttonRadius: Appearance.rounding.full
                            toggled: !root.graphEgress
                            onClicked: root.graphEgress = false
                            contentItem: StyledText {
                                anchors.centerIn: parent
                                text: Translation.tr("OCPU")
                                font.pixelSize: Appearance.font.pixelSize.smallie
                                color: root.graphEgress ? Appearance.colors.colSubtext : Appearance.colors.colOnSecondaryContainer
                            }
                        }
                        GroupButton {
                            baseHeight: 22
                            buttonRadius: Appearance.rounding.full
                            toggled: root.graphEgress
                            onClicked: root.graphEgress = true
                            contentItem: StyledText {
                                anchors.centerIn: parent
                                text: Translation.tr("Egress")
                                font.pixelSize: Appearance.font.pixelSize.smallie
                                color: root.graphEgress ? Appearance.colors.colOnSecondaryContainer : Appearance.colors.colSubtext
                            }
                        }
                    }
                }
            }
        }

        // ---- egress ----
        Rectangle {
            Layout.fillWidth: true
            visible: root.ready
            color: Appearance.colors.colLayer2
            radius: Appearance.rounding.normal
            implicitHeight: egressColumn.implicitHeight + Appearance.spacing.space300

            ColumnLayout {
                id: egressColumn
                anchors {
                    left: parent.left
                    right: parent.right
                    verticalCenter: parent.verticalCenter
                    leftMargin: Appearance.spacing.space150
                    rightMargin: Appearance.spacing.space150
                }
                spacing: Appearance.spacing.space100

                Meter {
                    label: Translation.tr("Outbound data transfer")
                    meter: OciVps.egressMeter
                    formatted: OciVps.formatGb(OciVps.egressMeter?.used ?? 0)
                    formattedLimit: OciVps.formatGb(OciVps.egressMeter?.limit ?? 0)
                    projected: OciVps.formatGb(OciVps.egressMeter?.projected ?? 0)
                }

                StyledText {
                    Layout.fillWidth: true
                    text: Translation.tr("Metered by Oracle, so internal traffic is not counted")
                    font.pixelSize: Appearance.font.pixelSize.smallie
                    color: Appearance.colors.colSubtext
                    wrapMode: Text.Wrap
                }
            }
        }

        // ---- live utilisation ----
        RowLayout {
            Layout.fillWidth: true
            visible: root.ready
            spacing: root.padding

            StatTile {
                symbol: "memory"
                label: Translation.tr("CPU")
                value: OciVps.cpuPercent
                suffix: "%"
            }
            StatTile {
                symbol: "memory_alt"
                label: Translation.tr("Memory")
                value: OciVps.memoryPercent
                suffix: "%"
            }
            StatTile {
                symbol: "speed"
                label: Translation.tr("Load")
                value: OciVps.loadAverage
                suffix: ""
            }
        }

        // ---- throughput ----
        // Rates, not totals: the counters behind these reset whenever the agent
        // restarts, so only their slope is meaningful.
        Rectangle {
            Layout.fillWidth: true
            visible: root.ready && (OciVps.netInRate >= 0 || OciVps.netOutRate >= 0)
            color: Appearance.colors.colLayer2
            radius: Appearance.rounding.normal
            implicitHeight: throughputColumn.implicitHeight + Appearance.spacing.space250

            ColumnLayout {
                id: throughputColumn
                anchors {
                    left: parent.left
                    right: parent.right
                    verticalCenter: parent.verticalCenter
                    leftMargin: Appearance.spacing.space150
                    rightMargin: Appearance.spacing.space150
                }
                spacing: Appearance.spacing.space50

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Appearance.spacing.space100

                    StyledText {
                        Layout.fillWidth: true
                        text: Translation.tr("Throughput")
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: Appearance.colors.colOnLayer2
                    }
                    StyledText {
                        text: OciVps.bandwidthGbps > 0
                            ? Translation.tr("%1 Gbps link").arg(OciVps.bandwidthGbps)
                            : ""
                        font.pixelSize: Appearance.font.pixelSize.smallie
                        color: Appearance.colors.colSubtext
                    }
                }

                Repeater {
                    model: [
                        { "symbol": "download", "label": Translation.tr("Network in"), "rate": OciVps.netInRate },
                        { "symbol": "upload", "label": Translation.tr("Network out"), "rate": OciVps.netOutRate },
                        { "symbol": "hard_drive", "label": Translation.tr("Disk read"), "rate": OciVps.diskReadRate },
                        { "symbol": "save", "label": Translation.tr("Disk write"), "rate": OciVps.diskWriteRate }
                    ]

                    RowLayout {
                        id: rateRow
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: Appearance.spacing.space100

                        MaterialSymbol {
                            text: rateRow.modelData.symbol
                            iconSize: Appearance.font.pixelSize.normal
                            color: Appearance.colors.colSubtext
                        }
                        StyledText {
                            Layout.fillWidth: true
                            text: rateRow.modelData.label
                            font.pixelSize: Appearance.font.pixelSize.smallie
                            color: Appearance.colors.colSubtext
                            elide: Text.ElideRight
                        }
                        StyledText {
                            text: OciVps.formatRate(rateRow.modelData.rate)
                            font.pixelSize: Appearance.font.pixelSize.smallie
                            color: Appearance.colors.colOnLayer2
                        }
                    }
                }
            }
        }

        // ---- storage ----
        Rectangle {
            Layout.fillWidth: true
            visible: root.ready && OciVps.bootSizeGb > 0
            color: Appearance.colors.colLayer2
            radius: Appearance.rounding.normal
            implicitHeight: storageRow.implicitHeight + Appearance.spacing.space250

            RowLayout {
                id: storageRow
                anchors {
                    left: parent.left
                    right: parent.right
                    verticalCenter: parent.verticalCenter
                    leftMargin: Appearance.spacing.space150
                    rightMargin: Appearance.spacing.space150
                }
                spacing: Appearance.spacing.space125

                MaterialSymbol {
                    text: "storage"
                    iconSize: Appearance.font.pixelSize.larger
                    color: Appearance.colors.colSubtext
                }
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Appearance.spacing.space25

                    StyledText {
                        Layout.fillWidth: true
                        text: OciVps.blockGb > 0
                            ? Translation.tr("Boot %1 GB + block %2 GB").arg(OciVps.bootSizeGb).arg(OciVps.blockGb)
                            : Translation.tr("Boot volume %1 GB").arg(OciVps.bootSizeGb)
                        font.pixelSize: Appearance.font.pixelSize.smaller
                        color: Appearance.colors.colOnLayer2
                    }
                    StyledText {
                        Layout.fillWidth: true
                        // The free 200 GB covers boot and block together, so a
                        // full allocation means no new volume can be attached -
                        // it is a fact worth stating, not an error.
                        text: Translation.tr("%1 / %2 GB allocated")
                            .arg(OciVps.allocatedGb).arg(OciVps.allocationLimitGb)
                            + (OciVps.allocationFull ? " · " + Translation.tr("fully allocated") : "")
                        font.pixelSize: Appearance.font.pixelSize.smallie
                        color: OciVps.allocationFull ? Appearance.colors.colTertiary : Appearance.colors.colSubtext
                        wrapMode: Text.Wrap
                    }
                    StyledText {
                        Layout.fillWidth: true
                        text: OciVps.bootVpuBillable
                            ? Translation.tr("%1 VPU/GB - above the free 10, this is billable").arg(OciVps.bootVpusPerGb)
                            : Translation.tr("%1 VPU/GB - within the free tier").arg(OciVps.bootVpusPerGb)
                        font.pixelSize: Appearance.font.pixelSize.smallie
                        color: OciVps.bootVpuBillable ? Appearance.colors.colError : Appearance.colors.colSubtext
                        wrapMode: Text.Wrap
                    }
                }
            }
        }

        // ---- empty / error state ----
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: !root.ready
            spacing: Appearance.spacing.space100

            Item { Layout.fillHeight: true }

            MaterialSymbol {
                Layout.alignment: Qt.AlignHCenter
                text: OciVps.configured ? "cloud_sync" : "key_off"
                iconSize: Appearance.font.pixelSize.title
                color: Appearance.colors.colSubtext
            }
            StyledText {
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                text: !OciVps.configured
                    ? Translation.tr("Add an API key to ~/.oci/config to see this instance")
                    : OciVps.lastError.length > 0 ? OciVps.lastError
                    : Translation.tr("Asking Oracle...")
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: Appearance.colors.colSubtext
                wrapMode: Text.Wrap
            }

            Item { Layout.fillHeight: true }
        }

        Item {
            Layout.fillHeight: true
            visible: root.ready
        }

        // ---- what Oracle actually metered ----
        // Folded away by default: it answers "why is that number what it is",
        // which is a question you only ask sometimes.
        Rectangle {
            Layout.fillWidth: true
            visible: root.ready && OciVps.skus.length > 0
            color: Appearance.colors.colLayer2
            radius: Appearance.rounding.normal
            implicitHeight: skuColumn.implicitHeight + Appearance.spacing.space250

            ColumnLayout {
                id: skuColumn
                anchors {
                    left: parent.left
                    right: parent.right
                    verticalCenter: parent.verticalCenter
                    leftMargin: Appearance.spacing.space150
                    rightMargin: Appearance.spacing.space150
                }
                spacing: Appearance.spacing.space50

                RippleButton {
                    Layout.fillWidth: true
                    implicitHeight: 28
                    buttonRadius: Appearance.rounding.small
                    onClicked: root.skusExpanded = !root.skusExpanded

                    contentItem: RowLayout {
                        spacing: Appearance.spacing.space100

                        StyledText {
                            Layout.fillWidth: true
                            text: Translation.tr("Metered line items")
                            font.pixelSize: Appearance.font.pixelSize.smaller
                            color: Appearance.colors.colOnLayer2
                        }
                        StyledText {
                            text: Translation.tr("%1 SKUs").arg(OciVps.skus.length)
                            font.pixelSize: Appearance.font.pixelSize.smallie
                            color: Appearance.colors.colSubtext
                        }
                        MaterialSymbol {
                            text: root.skusExpanded ? "expand_less" : "expand_more"
                            iconSize: Appearance.font.pixelSize.large
                            color: Appearance.colors.colSubtext
                        }
                    }
                }

                Repeater {
                    model: root.skusExpanded ? OciVps.skus : []

                    RowLayout {
                        id: skuRow
                        required property var modelData
                        Layout.fillWidth: true
                        spacing: Appearance.spacing.space100

                        StyledText {
                            Layout.fillWidth: true
                            text: skuRow.modelData.name
                            font.pixelSize: Appearance.font.pixelSize.smallie
                            color: Appearance.colors.colSubtext
                            elide: Text.ElideRight
                        }
                        StyledText {
                            text: skuRow.modelData.quantity.toFixed(2)
                            font.pixelSize: Appearance.font.pixelSize.smallie
                            color: Appearance.colors.colOnLayer2
                        }
                    }
                }
            }
        }

        // ---- footer ----
        StyledText {
            Layout.fillWidth: true
            visible: root.ready
            horizontalAlignment: Text.AlignHCenter
            // "created", not "up since": the API knows when the instance was
            // provisioned, and nothing about when it last booted.
            text: OciVps.processor.length > 0
                ? `${OciVps.processor} · ${Translation.tr("created %1").arg(OciVps.created.slice(0, 10))}`
                : Translation.tr("Oracle's own metering, resizes included")
            font.pixelSize: Appearance.font.pixelSize.smallie
            color: Appearance.colors.colSubtext
            wrapMode: Text.Wrap
        }
    }
}
