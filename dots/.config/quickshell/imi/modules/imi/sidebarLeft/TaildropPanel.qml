pragma ComponentBehavior: Bound
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import qs.modules.imi.sidebarRight.calendar
import QtQuick
import QtQuick.Layouts
import Quickshell

/**
 * Taildrop inbox panel, styled after the right sidebar's bottom widget group:
 * fixed height, collapsible to a slim summary bar, calendar-style header.
 */
Rectangle {
    id: root
    radius: Appearance.rounding.normal
    color: Appearance.colors.colLayer1
    clip: true

    property bool collapsed: Persistent.states.sidebar.taildropCollapsed
    implicitHeight: collapsed ? collapsedRow.implicitHeight : 350

    Behavior on implicitHeight {
        NumberAnimation {
            duration: Appearance.animation.elementMove.duration
            easing.type: Appearance.animation.elementMove.type
            easing.bezierCurve: Appearance.animation.elementMove.bezierCurve
        }
    }

    function setCollapsed(state: bool): void {
        Persistent.states.sidebar.taildropCollapsed = state
    }

    component RailButton: CalendarHeaderButton {
        property string symbol
        forceCircle: true
        contentItem: MaterialSymbol {
            text: (parent as RailButton)?.symbol ?? ""
            iconSize: Appearance.font.pixelSize.larger
            horizontalAlignment: Text.AlignHCenter
            color: Appearance.colors.colOnLayer1
        }
    }

    // ---- collapsed bar ----
    RowLayout {
        id: collapsedRow
        opacity: root.collapsed ? 1 : 0
        visible: opacity > 0
        spacing: Appearance.spacing.space175
        Behavior on opacity {
            NumberAnimation {
                duration: Appearance.animation.elementMove.duration / 2
                easing.type: Appearance.animation.elementMove.type
                easing.bezierCurve: Appearance.animation.elementMove.bezierCurve
            }
        }

        RailButton {
            Layout.margins: Appearance.spacing.space125
            Layout.rightMargin: Appearance.spacing.space0
            symbol: "keyboard_arrow_up"
            tooltipText: Translation.tr("Expand")
            downAction: () => root.setCollapsed(false)
        }

        StyledText {
            Layout.margins: Appearance.spacing.space125
            Layout.leftMargin: Appearance.spacing.space0
            text: Tailscale.incomingFileCount > 0
                ? Translation.tr("%1 file(s) waiting").arg(Tailscale.incomingFileCount)
                : Translation.tr("No incoming files")
            font.pixelSize: Appearance.font.pixelSize.large
            font.weight: Tailscale.incomingFileCount > 0 ? Font.Medium : Font.Normal
            color: Tailscale.incomingFileCount > 0 ? Appearance.colors.colPrimary : Appearance.colors.colOnLayer1
        }
    }

    // ---- expanded ----
    ColumnLayout {
        opacity: root.collapsed ? 0 : 1
        visible: opacity > 0
        anchors {
            fill: parent
            margins: Appearance.spacing.space125
        }
        spacing: Appearance.spacing.space75
        Behavior on opacity {
            NumberAnimation {
                duration: Appearance.animation.elementMove.duration / 2
                easing.type: Appearance.animation.elementMove.type
                easing.bezierCurve: Appearance.animation.elementMove.bezierCurve
            }
        }

        // header: collapse | title chip | folder + refresh
        RowLayout {
            Layout.fillWidth: true
            spacing: Appearance.spacing.space50

            RailButton {
                symbol: "keyboard_arrow_down"
                tooltipText: Translation.tr("Collapse")
                downAction: () => root.setCollapsed(true)
            }
            Item { Layout.fillWidth: true }
            CalendarHeaderButton {
                clip: true
                buttonText: Tailscale.incomingFileCount > 0
                    ? Translation.tr("Incoming files (%1)").arg(Tailscale.incomingFileCount)
                    : Translation.tr("Incoming files")
            }
            Item { Layout.fillWidth: true }
            RailButton {
                tooltipText: Translation.tr("Open %1").arg(Tailscale.taildropDisplayDir)
                symbol: "folder_open"
                // The directory is created on first receive, so it may not
                // exist yet when someone goes looking for it.
                downAction: () => Quickshell.execDetached([
                    "bash", "-c",
                    "mkdir -p -- \"$1\" && exec xdg-open \"$1\"",
                    "_", Tailscale.taildropTargetDir
                ])
            }
            RailButton {
                id: refreshButton
                tooltipText: Translation.tr("Check for new files")
                symbol: "refresh"
                downAction: () => {
                    refreshSpin.restart()
                    Tailscale.refreshIncomingFiles()
                }
                RotationAnimation {
                    id: refreshSpin
                    target: refreshButton.contentItem
                    from: 0
                    to: 360
                    duration: 500
                    easing.type: Easing.OutCubic
                }
            }
        }

        // busy indicator while receiving
        StyledIndeterminateProgressBar {
            visible: Tailscale.receivingFiles
            Layout.fillWidth: true
        }

        // empty state
        ColumnLayout {
            visible: Tailscale.incomingFileCount === 0
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Appearance.spacing.space50

            Item { Layout.fillHeight: true }
            MaterialSymbol {
                Layout.alignment: Qt.AlignHCenter
                text: "inbox"
                iconSize: 48
                color: Appearance.colors.colSubtext
            }
            StyledText {
                Layout.alignment: Qt.AlignHCenter
                text: Translation.tr("No incoming files")
                font.pixelSize: Appearance.font.pixelSize.normal
                color: Appearance.colors.colSubtext
            }
            StyledText {
                Layout.alignment: Qt.AlignHCenter
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignHCenter
                text: Translation.tr("Files sent to this device land in %1").arg(Tailscale.taildropDisplayDir)
                font.pixelSize: Appearance.font.pixelSize.smaller
                color: Appearance.colors.colSubtext
                wrapMode: Text.WordWrap
            }
            Item { Layout.fillHeight: true }
        }

        // file list
        StyledListView {
            visible: Tailscale.incomingFileCount > 0
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: Appearance.spacing.space75
            animateAppearance: false

            model: ScriptModel {
                objectProp: "Name"
                values: Tailscale.incomingFiles
            }
            delegate: Rectangle {
                id: fileRow
                required property var modelData
                required property int index
                width: ListView.view?.width ?? 0
                radius: Appearance.rounding.small
                color: Appearance.colors.colLayer2
                implicitHeight: rowContent.implicitHeight + 12

                RowLayout {
                    id: rowContent
                    anchors {
                        left: parent.left
                        right: parent.right
                        verticalCenter: parent.verticalCenter
                        leftMargin: Appearance.spacing.space125
                        rightMargin: Appearance.spacing.space75
                    }
                    spacing: Appearance.spacing.space125

                    StyledText {
                        Layout.preferredWidth: 18
                        horizontalAlignment: Text.AlignHCenter
                        text: fileRow.index + 1
                        font.pixelSize: Appearance.font.pixelSize.normal
                        color: Appearance.colors.colSubtext
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Appearance.spacing.space0
                        StyledText {
                            Layout.fillWidth: true
                            text: fileRow.modelData.Name || "?"
                            font.pixelSize: Appearance.font.pixelSize.small
                            color: Appearance.colors.colOnLayer1
                            elide: Text.ElideMiddle
                        }
                        StyledText {
                            text: Tailscale.formatBytes(fileRow.modelData.Size)
                            font.pixelSize: Appearance.font.pixelSize.smallest
                            color: Appearance.colors.colSubtext
                        }
                    }
                    CalendarHeaderButton {
                        forceCircle: true
                        enabled: !Tailscale.receivingFiles
                        tooltipText: Translation.tr("Receive %1").arg(fileRow.modelData.Name)
                        downAction: () => Tailscale.receiveFile(fileRow.modelData.Name)
                        contentItem: MaterialSymbol {
                            text: "download"
                            iconSize: Appearance.font.pixelSize.larger
                            horizontalAlignment: Text.AlignHCenter
                            color: Appearance.colors.colPrimary
                        }
                    }
                }
            }
        }

        // receive all
        DialogButton {
            visible: Tailscale.incomingFileCount > 0
            Layout.fillWidth: true
            enabled: !Tailscale.receivingFiles
            colBackground: Appearance.colors.colPrimary
            colBackgroundHover: Appearance.colors.colPrimaryHover
            colRipple: Appearance.colors.colPrimaryActive
            colText: Appearance.colors.colOnPrimary
            buttonText: Tailscale.receivingFiles
                ? Translation.tr("Receiving...")
                : Translation.tr("Receive all (%1)").arg(Tailscale.incomingFileCount)
            onClicked: Tailscale.receiveAllFiles()
        }
    }
}
