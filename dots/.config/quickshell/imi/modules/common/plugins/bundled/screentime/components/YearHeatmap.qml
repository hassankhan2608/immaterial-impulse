pragma ComponentBehavior: Bound

import QtQuick
import qs.modules.common
import qs.modules.common.widgets
import "../ScreenTimeModel.js" as Model

// GitHub-style year heatmap: one column per week (Sun..Sat), intensity scaled
// against the busiest day of the trailing year. Ported onto M3 tokens.
Column {
    id: root

    property var heatmap: []       // weeks; each = [7 ints (secs, -1 = out of range)]
    property var monthLabels: []   // [[weekIndex, "Jan"], ...]

    readonly property real cellSize: 7
    readonly property real cellGap: 2
    readonly property real gutterWidth: 16
    readonly property int numWeeks: heatmap ? heatmap.length : 0

    spacing: 2

    readonly property real maxValue: {
        let m = 0
        const weeks = root.heatmap || []
        for (let w = 0; w < weeks.length; w++) {
            const col = weeks[w] || []
            for (let d = 0; d < col.length; d++) {
                const v = Number(col[d]) || 0
                if (v > m) m = v
            }
        }
        return m
    }

    // Month labels row
    Item {
        visible: root.numWeeks > 0
        width: root.gutterWidth + root.numWeeks * (root.cellSize + root.cellGap)
        height: Appearance.font.pixelSize.smaller

        Repeater {
            model: root.monthLabels

            StyledText {
                required property var modelData
                x: root.gutterWidth + modelData[0] * (root.cellSize + root.cellGap)
                text: modelData[1]
                color: Appearance.colors.colSubtext
                font.pixelSize: Appearance.font.pixelSize.smaller
            }
        }
    }

    // Grid
    Item {
        visible: root.numWeeks > 0
        width: root.gutterWidth + root.numWeeks * (root.cellSize + root.cellGap)
        height: 7 * (root.cellSize + root.cellGap)
        clip: true

        Repeater {
            model: root.heatmap

            Item {
                required property int index
                required property var modelData
                x: root.gutterWidth + index * (root.cellSize + root.cellGap)
                width: root.cellSize
                height: parent.height

                Repeater {
                    model: modelData

                    Rectangle {
                        required property int index
                        required property var modelData
                        y: index * (root.cellSize + root.cellGap)
                        width: root.cellSize
                        height: root.cellSize
                        radius: Math.max(1, root.cellSize / 4)
                        color: modelData < 0
                            ? "transparent"
                            : Qt.rgba(
                                Appearance.colors.colPrimary.r,
                                Appearance.colors.colPrimary.g,
                                Appearance.colors.colPrimary.b,
                                Model.heatmapOpacity(modelData, root.maxValue) * 0.9)
                        border.width: modelData < 0 ? 0 : 1
                        border.color: Appearance.colors.colLayer1Hover
                    }
                }
            }
        }
    }
}
