pragma ComponentBehavior: Bound

import QtQuick
import qs.modules.common
import qs.modules.common.widgets
import "../ScreenTimeModel.js" as Model

// 24 vertical bars, one per hour, colored by the 5-band spectrum.
// Ported from Omalog HourlyChart onto M3 tokens.
Item {
    id: root

    property var hourly: []   // [{hour, duration}]

    readonly property real chartHeight: 72
    readonly property real axisHeight: Appearance.font.pixelSize.smaller + 4

    implicitHeight: chartHeight + axisHeight

    readonly property real maxDuration: {
        let m = 0
        const list = root.hourly || []
        for (let i = 0; i < list.length; i++) {
            const v = Number(list[i].duration) || 0
            if (v > m) m = v
        }
        return m
    }

    Item {
        id: chartArea
        width: parent.width
        height: root.chartHeight

        Repeater {
            model: 24

            Item {
                required property int index
                readonly property var entry: root.hourly[index] || {}
                readonly property int hour: {
                    const h = Number(entry.hour)
                    return isNaN(h) ? index : h
                }
                readonly property real duration: Number(entry.duration) || 0
                readonly property real barWidth: chartArea.width / 24

                x: hour * barWidth
                width: Math.max(2, barWidth - 1)
                height: chartArea.height

                Rectangle {
                    anchors.bottom: parent.bottom
                    width: parent.width
                    height: root.maxDuration > 0
                        ? Math.max(duration > 0 ? 2 : 0,
                                   (duration / root.maxDuration) * (chartArea.height - 2))
                        : 0
                    radius: Appearance.rounding.small
                    color: Model.spectrumColor(hour, Appearance.colors)
                }
            }
        }
    }

    Item {
        id: axisArea
        anchors.top: chartArea.bottom
        anchors.topMargin: Appearance.spacing.space25
        width: parent.width
        height: root.axisHeight

        Repeater {
            model: [0, 6, 12, 18, 23]

            StyledText {
                required property var modelData
                x: Math.min(axisArea.width - implicitWidth,
                            (modelData / 24) * axisArea.width)
                text: modelData < 10 ? "0" + modelData : "" + modelData
                color: Appearance.colors.colSubtext
                font.pixelSize: Appearance.font.pixelSize.smaller
            }
        }
    }
}
