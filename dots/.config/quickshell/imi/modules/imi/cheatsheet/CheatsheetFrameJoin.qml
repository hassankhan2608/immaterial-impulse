import qs.services
import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Layouts

/**
 * The frame join's SHAPE, live, in the cheatsheet's Frame join tab.
 *
 * The join (modules/common/widgets/FrameJoin.qml) is how an element leaves the
 * frame's band and comes back: one solver, one distance field, and a silhouette
 * that has to read as two bodies parting rather than a box sliding. None of
 * that can be judged from a still, and each surface that joins the frame is
 * reviewed on its own edge at its own size - so a change to the field was
 * reviewed by toggling one element and watching one edge.
 *
 * This page is the rest of the evidence. Every surface that joins the frame
 * (frame-pin-grammar.md, the table) is here at TRUE size, with its own corner
 * radii and on its own edge, running the same solver at the same time, so a
 * change can be read against a 51 px pill and a 630 px dock at once - the ratio
 * of the blend radius to the body is what the eye actually reads, and it is
 * the thing that differs most between them. What each surface does at the
 * band is what it does in the shell: the bar's plate and its islands square
 * their band-side corners as they fuse and round them as they lift; the
 * released cards take the 1 px stroke the field draws along their free outline
 * as they lift; the notification takes none, its card never had one.
 *
 * The field's blend is one radius (its `climbFraction` stays 0); the
 * anisotropic variant this page once showed beside it was retired with the
 * question it answered.
 *
 * Behind Config.options.developer.enable - see Cheatsheet.qml for the tab. The
 * same page runs standalone as `qs -p <shell>/bench_frame_join.qml`, which is
 * the form to use when it has to be driven from a script.
 */
Item {
    id: root

    implicitWidth: Math.min(1460, (root.Window.window?.screen?.width ?? 1920) - 240)
    implicitHeight: Math.min(820, (root.Window.window?.screen?.height ?? 1080) - 260)

    // The silhouette is the whole subject, so the two colours are the strongest
    // pair the theme has rather than the surface colours the join wears in the
    // shell: an outline judged against the dock's own translucency is the thing
    // that made the first round of this unmeasurable.
    readonly property color ground: Appearance.colors.colLayer1
    readonly property color chrome: Appearance.colors.colOnLayer1

    property bool attached: true
    property real travel: 8
    property real slant: 1.1
    property real meniscus: 45
    property bool cycling: true

    // Every surface that joins the frame, at the size it really is, in the
    // rows they share on this page. `w: 0` is the plate that spans its edge.
    // `bandCorners`: the band-side corners round with the lift (the bar's
    // plateRadius). `stroke`: the released card's border, drawn by the field
    // with the lift.
    readonly property var rows: [
        [
            { label: Translation.tr("bar plate  ·  Hug / Float"), edge: "top", w: 0, h: 40,
              r: Appearance.rounding.windowRounding, bandCorners: true, stroke: true }
        ],
        [
            { label: Translation.tr("bar island"), edge: "top", w: 230, h: 40,
              r: Appearance.rounding.windowRounding, bandCorners: true, stroke: true },
            { label: Translation.tr("OSD"), edge: "top", w: 280, h: 51, r: 25.5, bandCorners: false, stroke: true }
        ],
        [
            { label: Translation.tr("bar widget popup"), edge: "top", w: 482, h: 216,
              r: Appearance.rounding.normal + 4, bandCorners: false, stroke: true },
            { label: Translation.tr("dock window preview"), edge: "bottom", w: 320, h: 208,
              r: Appearance.rounding.normal, bandCorners: false, stroke: true }
        ],
        [
            { label: Translation.tr("notification"), edge: "right", w: 330, h: 92,
              r: Appearance.rounding.normal, bandCorners: false, stroke: false },
            { label: Translation.tr("dock"), edge: "bottom", w: 630, h: 60,
              r: Appearance.rounding.large, bandCorners: false, stroke: true }
        ]
    ]

    Timer {
        interval: 2400
        repeat: true
        running: root.cycling && root.visible
        onTriggered: root.attached = !root.attached
    }

    // One surface: a band at an edge, a plate that joins it, and the join
    // between them. The plate is positioned FROM the join - nothing here
    // sequences anything, which is the whole point of the widget.
    component Surface: Item {
        id: cell
        required property var spec
        readonly property string edge: cell.spec.edge
        readonly property bool sideways: cell.edge === "left" || cell.edge === "right"
        readonly property real band: 2
        readonly property real gap: Appearance.spacing.space150
        // The plate's size: its own, or the edge's span less a margin.
        readonly property real plateW: cell.spec.w > 0 ? cell.spec.w : Math.max(0, cell.width - 2 * cell.gap)
        readonly property real plateH: cell.spec.h
        // The band-side corners round with the lift where the surface's do
        // (the bar's plateRadius); the rest keep their own radius.
        readonly property real bandRadius: cell.spec.bandCorners
            ? cell.spec.r * Math.min(1, join.lift / Math.max(1, join.travel)) : cell.spec.r
        readonly property real awayRadius: cell.spec.r

        Rectangle {
            color: root.chrome
            width: cell.sideways ? cell.band : parent.width
            height: cell.sideways ? parent.height : cell.band
            anchors {
                top: cell.edge !== "bottom" ? parent.top : undefined
                bottom: cell.edge !== "top" ? parent.bottom : undefined
                left: cell.edge !== "right" ? parent.left : undefined
                right: cell.edge !== "left" ? parent.right : undefined
            }
        }

        Rectangle {
            id: plate
            color: root.chrome
            topLeftRadius: cell.edge === "top" || cell.edge === "left" ? cell.bandRadius : cell.awayRadius
            topRightRadius: cell.edge === "top" || cell.edge === "right" ? cell.bandRadius : cell.awayRadius
            bottomRightRadius: cell.edge === "bottom" || cell.edge === "right" ? cell.bandRadius : cell.awayRadius
            bottomLeftRadius: cell.edge === "bottom" || cell.edge === "left" ? cell.bandRadius : cell.awayRadius
            // The travel axis carries the lift and the stretch; the other axis
            // is the plate's own size.
            width: cell.sideways ? cell.plateW + join.press : cell.plateW
            height: cell.sideways ? cell.plateH : cell.plateH + join.press
            x: {
                if (cell.edge === "left") return cell.band + join.lift;
                if (cell.edge === "right") return cell.width - cell.band - join.lift - width;
                return (cell.width - width) / 2;
            }
            y: {
                if (cell.edge === "top") return cell.band + join.lift;
                if (cell.edge === "bottom") return cell.height - cell.band - join.lift - height;
                return (cell.height - height) / 2;
            }
            // The field paints the plate while it has one; a translucent fill
            // drawn twice is darker than the same fill drawn once.
            opacity: join.drawsPlate ? 0 : 1
        }

        FrameJoin {
            id: join
            anchors.fill: parent
            plate: plate
            edge: cell.edge
            attached: root.attached
            travel: root.travel
            bandInset: cell.band
            color: root.chrome
            slant: root.slant
            meniscus: root.meniscus * root.slant
            // The released card's border, as the shell draws it: the field's
            // stroke along the free outline, its width following the lift.
            strokeWidth: cell.spec.stroke
                ? Appearance.borderWidth.standard * Math.min(1, join.lift / Math.max(1, join.travel)) : 0
            strokeColor: Appearance.colors.colLayer0Border
        }

        // On the INWARD side, away from the band being joined, so a label
        // never crosses the outline it is labelling.
        ColumnLayout {
            x: Appearance.spacing.space100
            y: cell.edge === "top" ? cell.height - implicitHeight - Appearance.spacing.space50
                                   : Appearance.spacing.space50
            spacing: 0
            StyledText {
                text: cell.spec.label
                color: Appearance.colors.colSubtext
                font.pixelSize: Appearance.font.pixelSize.smaller
            }
            StyledText {
                text: "lift " + join.lift.toFixed(2) + "  press " + join.press.toFixed(2)
                      + (join.fused ? "  fused" : "  free")
                color: Appearance.colors.colSubtext
                font.family: Appearance.font.family.monospace
                font.pixelSize: Appearance.font.pixelSize.smaller
            }
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: Appearance.spacing.space125

        RowLayout {
            Layout.fillWidth: true
            spacing: Appearance.spacing.space150

            RippleButtonWithIcon {
                materialIcon: root.attached ? "arrow_upward" : "arrow_downward"
                mainText: root.attached ? Translation.tr("Detach") : Translation.tr("Attach")
                onClicked: {
                    root.cycling = false;
                    root.attached = !root.attached;
                }
            }
            ConfigSwitch {
                text: Translation.tr("Cycle")
                checked: root.cycling
                onToggleRequested: root.cycling = !root.cycling
            }
            ConfigSlider {
                text: Translation.tr("Travel")
                from: 2
                to: 24
                value: root.travel
                usePercentTooltip: false
                // ConfigSlider carries no step: it is a continuous control
                // with a Behavior on its value, and the rounding belongs to
                // whoever wants whole pixels.
                onValueModified: newValue => root.travel = Math.round(newValue)
            }
            ConfigSlider {
                text: Translation.tr("Meniscus")
                from: 5
                to: 90
                value: root.meniscus
                usePercentTooltip: false
                onValueModified: newValue => root.meniscus = Math.round(newValue)
            }
            Item { Layout.fillWidth: true }
        }

        StyledText {
            Layout.fillWidth: true
            horizontalAlignment: Text.AlignHCenter
            text: Translation.tr("Every surface that joins the frame, at true size: fused on its band, then released a lift off it")
            color: Appearance.colors.colOnLayer1
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: Appearance.spacing.space100

            Repeater {
                model: root.rows
                delegate: RowLayout {
                    id: surfaceRow
                    required property var modelData
                    readonly property var specs: surfaceRow.modelData
                    // What a pane needs to hold its surface at TRUE size, with
                    // room for the lift and a readout; the row takes the
                    // tallest.
                    function paneHeight(spec) {
                        const sideways = spec.edge === "left" || spec.edge === "right";
                        return (sideways ? spec.h : spec.h + root.travel + 2) + 48;
                    }
                    readonly property real rowHeight: Math.max(...surfaceRow.specs.map(s => surfaceRow.paneHeight(s)))
                    Layout.fillWidth: true
                    Layout.preferredHeight: rowHeight
                    spacing: Appearance.spacing.space100

                    Repeater {
                        model: surfaceRow.specs
                        delegate: Rectangle {
                            id: pane
                            required property var modelData
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            color: root.ground
                            radius: Appearance.rounding.small
                            Surface {
                                anchors.fill: parent
                                anchors.margins: Appearance.borderWidth.standard
                                spec: pane.modelData
                            }
                        }
                    }
                }
            }
        }
    }
}
