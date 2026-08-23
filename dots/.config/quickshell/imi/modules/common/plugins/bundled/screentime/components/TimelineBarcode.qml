pragma ComponentBehavior: Bound

import QtQuick
import qs.modules.common
import qs.modules.common.widgets
import "../ScreenTimeModel.js" as Model

// Full-width barcode of today's activity, ported from Omalog TimelineBarcode.
// Each slot is colored by the dominant category root during that day slice,
// using live M3 theme colors.
Item {
    id: root

    property var timeline: []   // [{timestamp, duration, category: [str, ...]}]
    property int slots: 96

    readonly property real barHeight: 22
    readonly property real axisHeight: Appearance.font.pixelSize.smaller + 4

    implicitHeight: barHeight + axisHeight

    readonly property var slotData: {
        const acc = []
        for (let i = 0; i < root.slots; i++) acc.push({})
        const slotSecs = 86400 / root.slots
        const events = root.timeline || []
        for (let e = 0; e < events.length; e++) {
            const ev = events[e]
            const d = new Date(ev.timestamp)
            if (isNaN(d.getTime())) continue
            const midnight = new Date(d.getFullYear(), d.getMonth(), d.getDate())
            const startSecs = (d.getTime() - midnight.getTime()) / 1000
            const endSecs = startSecs + (Number(ev.duration) || 0)
            const cat = ev.category || []
            const rootName = (cat.length > 0 && cat[0]) ? cat[0] : "Uncategorized"
            const s0 = Math.max(0, Math.floor(startSecs / slotSecs))
            const s1 = Math.min(root.slots - 1, Math.floor((endSecs - 0.001) / slotSecs))
            for (let s = s0; s <= s1; s++) {
                const ovStart = Math.max(startSecs, s * slotSecs)
                const ovEnd = Math.min(endSecs, (s + 1) * slotSecs)
                const overlap = ovEnd - ovStart
                if (overlap > 0) acc[s][rootName] = (acc[s][rootName] || 0) + overlap
            }
        }
        const out = []
        for (let j = 0; j < root.slots; j++) {
            let best = null
            let bestV = 0
            let has = false
            for (const k in acc[j]) {
                has = true
                if (acc[j][k] > bestV) { bestV = acc[j][k]; best = k }
            }
            out.push(has ? { root: best } : null)
        }
        return out
    }

    Item {
        id: barcodeArea
        width: parent.width
        height: root.barHeight

        Repeater {
            model: root.slots

            Rectangle {
                required property int index
                readonly property var slot: root.slotData ? root.slotData[index] : null

                x: index * (barcodeArea.width / root.slots)
                width: Math.max(1, barcodeArea.width / root.slots - 1)
                height: barcodeArea.height
                radius: 1
                color: slot
                    ? Model.categoryColor(slot.root, Appearance.colors)
                    : Appearance.colors.colSurfaceContainerHighest
            }
        }
    }

    Item {
        id: axisArea
        anchors.top: barcodeArea.bottom
        anchors.topMargin: 2
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
