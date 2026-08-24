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

    readonly property real preferredCellSize: 7
    readonly property real preferredCellGap: 2
    readonly property real gutterWidth: 16
    readonly property int numWeeks: heatmap ? heatmap.length : 0
    readonly property real preferredGridWidth: numWeeks > 0
        ? gutterWidth + numWeeks * preferredCellSize + (numWeeks - 1) * preferredCellGap
        : 0
    readonly property real layoutWidth: root.width > 0 ? root.width : preferredGridWidth
    readonly property real availableGridWidth: Math.max(0, layoutWidth - gutterWidth)
    readonly property real cellGap: {
        if (numWeeks <= 1)
            return 0
        return Math.max(0, Math.min(preferredCellGap,
            (availableGridWidth - numWeeks * preferredCellSize) / (numWeeks - 1)))
    }
    readonly property real cellSize: {
        if (numWeeks === 0)
            return preferredCellSize
        return Math.min(preferredCellSize, Math.max(0,
            (availableGridWidth - (numWeeks - 1) * cellGap) / numWeeks))
    }
    readonly property real weekStride: cellSize + cellGap
    readonly property real gridWidth: numWeeks > 0
        ? gutterWidth + numWeeks * cellSize + (numWeeks - 1) * cellGap
        : 0
    spacing: Appearance.spacing.space25

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
        width: root.gridWidth
        height: Appearance.font.pixelSize.smaller

        Repeater {
            model: root.monthLabels

            StyledText {
                required property int index
                required property var modelData
                readonly property int startWeek: Math.max(0,
                    Math.min(root.numWeeks, Number(modelData[0])))
                readonly property int endWeek: index + 1 < root.monthLabels.length
                    ? Math.max(startWeek, Math.min(root.numWeeks,
                        Number(root.monthLabels[index + 1][0])))
                    : root.numWeeks
                readonly property real slotEndX: endWeek < root.numWeeks
                    ? root.gutterWidth + endWeek * root.weekStride
                    : root.gridWidth

                x: root.gutterWidth + startWeek * root.weekStride
                width: Math.max(0, slotEndX - x)
                visible: width + 0.01 >= implicitWidth
                clip: true
                text: modelData[1]
                color: Appearance.colors.colSubtext
                font.pixelSize: Appearance.font.pixelSize.smaller
            }
        }
    }

    // Grid
    Item {
        visible: root.numWeeks > 0
        width: root.gridWidth
        height: 7 * root.cellSize + 6 * root.cellGap
        clip: true

        Repeater {
            model: root.heatmap

            Item {
                required property int index
                required property var modelData
                x: root.gutterWidth + index * root.weekStride
                width: root.cellSize
                height: parent.height

                Repeater {
                    model: modelData

                    Rectangle {
                        required property int index
                        required property var modelData
                        y: index * root.weekStride
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
