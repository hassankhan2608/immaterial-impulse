pragma ComponentBehavior: Bound

import QtQuick
import qs.modules.common
import qs.modules.common.widgets
import "../ScreenTimeModel.js" as Model

// Seven horizontal bars (Mon..Sun), each stacked by category root and scaled
// against the busiest day. Ported from Omalog StackedWeekBars onto M3 tokens.
Column {
    id: root

    property var days: []   // [{weekday, total_secs, is_future, is_peak, roots: [{name, secs}]}]

    readonly property real labelWidth: 34
    readonly property real durationWidth: 44
    readonly property real barWidth: width - labelWidth - durationWidth - 8

    spacing: 4

    readonly property real maxTotal: {
        let m = 0
        const list = root.days || []
        for (let i = 0; i < list.length; i++) {
            const v = Number(list[i].total_secs) || 0
            if (v > m) m = v
        }
        return m
    }

    readonly property var legendRoots: {
        const seen = []
        const list = root.days || []
        for (let i = 0; i < list.length; i++) {
            const roots = list[i].roots || []
            for (let j = 0; j < roots.length; j++) seen.push(roots[j].name)
        }
        const ordered = Model.WEEK_ROOT_ORDER.filter(r => seen.indexOf(r) !== -1)
        for (let k = 0; k < seen.length; k++)
            if (ordered.indexOf(seen[k]) === -1) ordered.push(seen[k])
        return ordered
    }

    // Inline category legend
    Row {
        visible: root.legendRoots.length > 0
        spacing: 10

        Repeater {
            model: root.legendRoots

            Row {
                required property string modelData
                spacing: 4

                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 7
                    height: 7
                    radius: 2
                    color: Model.categoryColor(modelData, Appearance.colors)
                }

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: modelData
                    color: Appearance.colors.colSubtext
                    font.pixelSize: Appearance.font.pixelSize.smaller
                }
            }
        }
    }

    Repeater {
        model: root.days.length

        Item {
            id: dayRow
            required property int index
            readonly property var day: root.days[index]
            width: parent.width
            height: 18
            opacity: day.is_future ? 0.35 : 1

            StyledText {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: root.labelWidth
                text: day.weekday || ""
                color: day.is_peak
                    ? Appearance.colors.colPrimary
                    : Appearance.colors.colOnLayer1
                font.pixelSize: Appearance.font.pixelSize.smaller
                font.weight: day.is_peak ? Font.DemiBold : Font.Normal
            }

            // Stacked bar
            Item {
                id: stackArea
                anchors.left: parent.left
                anchors.leftMargin: root.labelWidth
                anchors.verticalCenter: parent.verticalCenter
                width: root.barWidth
                height: 10

                Rectangle {
                    // Track
                    anchors.fill: parent
                    radius: Appearance.rounding.full
                    color: Appearance.colors.colSurfaceContainerHighest
                }

                Row {
                    // Segments
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    height: parent.height

                    Repeater {
                        model: day.roots || []

                        Rectangle {
                            required property var modelData
                            readonly property real ratio: root.maxTotal > 0
                                ? (Number(modelData.secs) || 0) / root.maxTotal
                                : 0
                            width: ratio * stackArea.width
                            height: parent.height
                            radius: Appearance.rounding.full
                            color: Model.categoryColor(modelData.name, Appearance.colors)
                        }
                    }
                }
            }

            StyledText {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                width: root.durationWidth
                horizontalAlignment: Text.AlignRight
                text: day.is_future ? "—" : Model.formatDurationShort(day.total_secs)
                color: Appearance.colors.colOnLayer1
                font.pixelSize: Appearance.font.pixelSize.smaller
            }
        }
    }
}
