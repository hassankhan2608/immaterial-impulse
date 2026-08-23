pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.modules.common
import qs.modules.common.widgets
import "../ScreenTimeModel.js" as Model

// Top-N list with app icons and duration bars.
// comfortable: full-width card mode — 24px icons, roomier rows.
// compact: half-width mode — 16px icons/dots, tighter rows.
ColumnLayout {
    id: root

    property string title: ""
    property var items: []           // [{name, duration_secs}] or [{domain, duration_secs}]
    property string barColorKey: ""  // "app" | "category" | "domain"
    property bool isDomainList: false
    property bool comfortable: false

    readonly property real iconSize: comfortable ? 24 : 16
    readonly property real symbolSize: comfortable ? 18 : 13
    readonly property real rowSpacing: comfortable
        ? Appearance.spacing.space75 : Appearance.spacing.space50

    spacing: rowSpacing

    StyledText {
        visible: root.items.length === 0
        text: qsTr("No data yet")
        color: Appearance.colors.colSubtext
        font.pixelSize: Appearance.font.pixelSize.smaller
    }

    Repeater {
        model: Math.min(root.items.length, 5)

        RowLayout {
            id: entryRow
            required property int index
            Layout.fillWidth: true
            spacing: root.comfortable
                ? Appearance.spacing.space125 : Appearance.spacing.space75

            readonly property var item: root.items[index]
            readonly property real maxSecs: Model.topListMax(root.items, "duration_secs")
            readonly property real itemSecs: Number(item.duration_secs) || 0
            readonly property real barRatio: maxSecs > 0 ? itemSecs / maxSecs : 0
            readonly property string iconSource: entryRow.item
                ? Quickshell.iconPath(entryRow.item.name ?? "", "") : ""

            // App icon (apps only; categories/domains get a colored dot)
            Item {
                implicitWidth: root.iconSize
                implicitHeight: root.iconSize
                visible: !root.isDomainList && root.barColorKey === "app"

                AppIcon {
                    anchors.fill: parent
                    implicitSize: root.iconSize
                    source: entryRow.iconSource
                    visible: entryRow.iconSource !== ""
                }
                MaterialSymbol {
                    anchors.fill: parent
                    visible: entryRow.iconSource === ""
                    text: "apps"
                    iconSize: root.symbolSize
                    color: Appearance.colors.colSubtext
                }
            }

            Rectangle {
                visible: root.isDomainList || root.barColorKey === "category"
                implicitWidth: root.comfortable ? 12 : 8
                implicitHeight: root.comfortable ? 12 : 8
                radius: Appearance.rounding.full
                color: root.barColorKey === "category"
                    ? Model.categoryColor(
                        Array.isArray(entryRow.item.name) ? entryRow.item.name[0] : "Uncategorized",
                        Appearance.colors)
                    : Appearance.colors.colSecondary
                Layout.alignment: Qt.AlignVCenter
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Appearance.spacing.space75

                    StyledText {
                        Layout.fillWidth: true
                        text: {
                            if (root.isDomainList) return entryRow.item.domain || ""
                            const n = entryRow.item.name
                            return Array.isArray(n) ? n[n.length - 1] : (n || "")
                        }
                        color: Appearance.colors.colOnLayer1
                        font.pixelSize: root.comfortable
                            ? Appearance.font.pixelSize.small
                            : Appearance.font.pixelSize.smaller
                        font.weight: Font.DemiBold
                        elide: Text.ElideRight
                    }

                    StyledText {
                        text: Model.formatDurationShort(entryRow.itemSecs)
                        color: Appearance.colors.colOnSurfaceVariant
                        font.pixelSize: root.comfortable
                            ? Appearance.font.pixelSize.small
                            : Appearance.font.pixelSize.smaller
                        font.features: { "tnum": 1 }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 4
                    radius: Appearance.rounding.full
                    color: Appearance.colors.colSurfaceContainerHighest

                    Rectangle {
                        width: parent.width * entryRow.barRatio
                        height: parent.height
                        radius: Appearance.rounding.full
                        color: {
                            if (root.barColorKey === "app") return Appearance.colors.colTertiary
                            if (root.barColorKey === "category")
                                return Model.categoryColor(
                                    Array.isArray(entryRow.item.name) ? entryRow.item.name[0] : "Uncategorized",
                                    Appearance.colors)
                            return Appearance.colors.colSecondary
                        }
                    }
                }
            }
        }
    }
}
