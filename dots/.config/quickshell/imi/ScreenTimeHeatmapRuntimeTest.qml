import QtQuick
import Quickshell
import "modules/common/plugins/bundled/screentime/components"

ShellRoot {
    id: harness

    property int failures: 0
    property int checksRun: 0
    readonly property var labelNames: [
        "Aug", "Sep", "Oct", "Nov", "Dec", "Jan", "Feb",
        "Mar", "Apr", "May", "Jun", "Jul"
    ]

    function makeWeeks() {
        const weeks = [];
        for (let week = 0; week < 54; week++) {
            const days = [];
            for (let day = 0; day < 7; day++)
                days.push((week + 1) * (day + 1));
            weeks.push(days);
        }
        return weeks;
    }

    function descendants(node, found) {
        const result = found ?? [];
        const children = node?.children ?? [];
        for (let index = 0; index < children.length; index++) {
            result.push(children[index]);
            descendants(children[index], result);
        }
        return result;
    }

    function boundsInGraph(item) {
        const topLeft = item.mapToItem(graph, 0, 0);
        const bottomRight = item.mapToItem(graph, item.width, item.height);
        return {
            left: topLeft.x,
            top: topLeft.y,
            right: bottomRight.x,
            bottom: bottomRight.y
        };
    }

    function check(label, ok) {
        harness.checksRun++;
        console.log(`[ScreenTimeHeatmap] ${label}: ${ok ? "ok" : "FAIL"}`);
        if (!ok)
            harness.failures++;
    }

    function finish() {
        const items = descendants(graph);
        const cells = items.filter(function(item) {
            return item.radius !== undefined && item.width > 0 && item.height > 0;
        });
        const labels = items.filter(function(item) {
            return item.visible && typeof item.text === "string"
                && harness.labelNames.indexOf(item.text) >= 0;
        }).map(boundsInGraph).sort(function(left, right) {
            return left.left - right.left;
        });

        const cellsFit = cells.every(function(cell) {
            const bounds = boundsInGraph(cell);
            return bounds.left >= -0.01 && bounds.right <= graph.width + 0.01;
        });
        const labelsFit = labels.every(function(bounds) {
            return bounds.left >= -0.01 && bounds.right <= graph.width + 0.01;
        });
        let labelsDoNotOverlap = true;
        for (let index = 1; index < labels.length; index++) {
            if (labels[index].left < labels[index - 1].right - 0.01) {
                labelsDoNotOverlap = false;
                break;
            }
        }

        console.log(`[ScreenTimeHeatmap] geometry: width=${graph.width} cells=${cells.length} labels=${labels.length}`);
        check("all 378 day cells are rendered", cells.length === 54 * 7);
        check("every day cell fits the card content width", cellsFit);
        check("at least ten month labels remain visible", labels.length >= 10);
        check("visible month labels do not overlap", labelsDoNotOverlap);
        check("visible month labels fit the card content width", labelsFit);
        console.log(`[ScreenTimeHeatmap] checks: ${harness.checksRun} failures: ${harness.failures}`);
        Qt.exit(harness.failures === 0 ? 0 : 1);
    }

    FloatingWindow {
        implicitWidth: 500
        implicitHeight: 140
        color: "black"

        YearHeatmap {
            id: graph
            x: 16
            y: 16
            width: 468
            heatmap: harness.makeWeeks()
            monthLabels: [
                [0, "Aug"], [1, "Sep"], [5, "Oct"], [9, "Nov"],
                [14, "Dec"], [18, "Jan"], [23, "Feb"], [27, "Mar"],
                [31, "Apr"], [36, "May"], [40, "Jun"], [45, "Jul"],
                [49, "Aug"]
            ]
        }
    }

    Timer {
        interval: 500
        running: true
        repeat: false
        onTriggered: harness.finish()
    }
}
