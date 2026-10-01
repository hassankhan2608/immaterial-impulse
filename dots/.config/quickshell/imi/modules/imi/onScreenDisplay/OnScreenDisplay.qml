import qs
import qs.services
import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import "../../../services/frame_geometry.js" as Geo

Scope {
    id: root
    property string protectionMessage: ""
    // Frame mode (frame-pin-grammar.md, the OSD row): a transient card, so
    // it is fused - it grows out of the bar's plate (or the band where no
    // plate sits on that edge) and sinks back into it when it times out; the
    // frame paints its pill under "osd". `leaving` keeps the window alive
    // for the sink. Not under the M3 style, whose bar publishes no plate to
    // grow out of: the OSD keeps its place under the bar there.
    readonly property bool joinsFrame: FrameGeometry.popupsJoinBar
    property bool leaving: false
    // The window's lifetime, set from here in order - never a binding on
    // osdVolumeOpen: a binding re-evaluated on the same signal that set
    // `leaving` from inside the window destroyed the window before its
    // handler ran, and the pill vanished in one frame instead of sinking
    // (burst). Up from the trigger until the sink has run (frame mode) or
    // until the timeout (otherwise).
    property bool windowUp: false
    Connections {
        target: GlobalStates
        function onOsdVolumeOpenChanged() {
            if (GlobalStates.osdVolumeOpen) {
                root.windowUp = true;
                root.leaving = false;
            } else if (root.joinsFrame && root.windowUp) {
                root.leaving = true;
            } else {
                root.windowUp = false;
            }
        }
    }
    Component.onCompleted: root.windowUp = GlobalStates.osdVolumeOpen
    property var focusedScreen: Quickshell.screens.find(s => s.name === Hyprland.focusedMonitor?.name)

    property string currentIndicator: "volume"
    property var indicators: [
        {
            id: "volume",
            sourceUrl: "indicators/VolumeIndicator.qml"
        },
        {
            id: "brightness",
            sourceUrl: "indicators/BrightnessIndicator.qml"
        },
        {
            id: "gamma",
            sourceUrl: "indicators/GammaIndicator.qml"
        },
        {
            id: "clightTemperature",
            sourceUrl: "indicators/ClightTemperatureIndicator.qml"
        },
        {
            id: "keyboardLayout",
            sourceUrl: "indicators/KeyboardLayoutIndicator.qml"
        },
        {
            id: "audioOutput",
            sourceUrl: "indicators/AudioOutputIndicator.qml"
        },
        {
            id: "audioInput",
            sourceUrl: "indicators/AudioInputIndicator.qml"
        },
        {
            id: "capsLock",
            sourceUrl: "indicators/CapsLockIndicator.qml"
        },
        {
            id: "numLock",
            sourceUrl: "indicators/NumLockIndicator.qml"
        },
    ]

    function triggerOsd() {
        GlobalStates.osdVolumeOpen = true;
        osdTimeout.restart();
    }

    Timer {
        id: osdTimeout
        interval: Config.options.osd.timeout
        repeat: false
        running: false
        onTriggered: {
            GlobalStates.osdVolumeOpen = false;
            root.protectionMessage = "";
        }
    }

    Connections {
        target: Brightness
        function onBrightnessChanged() {
            root.protectionMessage = "";
            root.currentIndicator = "brightness";
            root.triggerOsd();
        }
    }

    Connections {
        target: Hyprsunset
        function onGammaChangeAttempt() {
            root.protectionMessage = "";
            root.currentIndicator = "gamma";
            root.triggerOsd();
        }
    }

    Connections {
        // Clight only signals a Temp change the daemon made after its first
        // report (day/night transitions), so this cannot fire at startup.
        target: Clight
        function onTemperatureChangedByDaemon() {
            root.protectionMessage = "";
            root.currentIndicator = "clightTemperature";
            root.triggerOsd();
        }
    }

    Connections {
        // Listen to volume changes
        target: Audio.sink?.audio ?? null
        function onVolumeChanged() {
            if (!Audio.ready)
                return;
            root.currentIndicator = "volume";
            root.triggerOsd();
        }
        function onMutedChanged() {
            if (!Audio.ready)
                return;
            root.currentIndicator = "volume";
            root.triggerOsd();
        }
    }

    Connections {
        // Listen to protection triggers
        target: Audio
        function onSinkProtectionTriggered(reason) {
            root.protectionMessage = reason;
            root.currentIndicator = "volume";
            root.triggerOsd();
        }
        function onSinkChanged() {
            if (!Audio.sink) return;
            root.protectionMessage = "";
            root.currentIndicator = "audioOutput";
            root.triggerOsd();
        }
        function onSourceChanged() {
            if (!Audio.source) return;
            root.protectionMessage = "";
            root.currentIndicator = "audioInput";
            root.triggerOsd();
        }
    }

    Connections {
        // Listen to lock key toggles (ignore the initial state read on startup)
        target: KeyboardLocks
        function onCapsLockOnChanged() {
            if (!KeyboardLocks.ready) return;
            root.protectionMessage = "";
            root.currentIndicator = "capsLock";
            root.triggerOsd();
        }
        function onNumLockOnChanged() {
            if (!KeyboardLocks.ready) return;
            root.protectionMessage = "";
            root.currentIndicator = "numLock";
            root.triggerOsd();
        }
    }

    Connections {
        // Listen to keyboard layout switches
        target: HyprlandXkb
        function onCurrentLayoutNameChanged() {
            // Nothing to announce a switch to/from if there's only one layout
            if (HyprlandXkb.layoutCodes.length <= 1) return;
            root.protectionMessage = "";
            root.currentIndicator = "keyboardLayout";
            root.triggerOsd();
        }
    }

    Loader {
        id: osdLoader
        active: root.windowUp

        sourceComponent: PanelWindow {
            id: osdRoot
            color: "transparent"

            Connections {
                target: root
                function onFocusedScreenChanged() {
                    osdRoot.screen = root.focusedScreen;
                }
            }

            WlrLayershell.namespace: "quickshell:onScreenDisplay"
            WlrLayershell.layer: WlrLayer.Overlay
            readonly property bool bottom: Config.options.bar.bottom
            readonly property string edge: osdRoot.bottom ? "bottom" : "top"
            // Joined to the frame the window spans the screen's width, so
            // the card's x IS its screen x (the record needs screen
            // coordinates), and sits at the plate's inner edge (barInner), so
            // the card at lift 0 is on the plate and bandInset is 0.
            anchors {
                top: !osdRoot.bottom
                bottom: osdRoot.bottom
                left: root.joinsFrame
                right: root.joinsFrame
            }
            mask: Region {
                item: osdValuesWrapper
            }

            // ---- the join ---------------------------------------------------
            //
            // The plate's inner edge on this edge, measured from the screen
            // edge: the bar's plate, the island under the OSD's centre, or
            // the band (Geo.barInnerEdgeAt - the frame paints by the same
            // rule). Taken up from the event loop, never bound: this window
            // publishes its own record into the same map.
            // ...or, for a bar with no plate (its background off), the bar's
            // zone edge, where the OSD emerges as a drop with no meniscus.
            readonly property real bandFallback: FrameGeometry.barPlateless && osdRoot.edge === FrameGeometry.barEdge
                ? FrameGeometry.barThickness : FrameGeometry.bandExtent(osdRoot.edge)
            property real barInner: osdRoot.bandFallback
            // The plate's flat along the bar, between its corner radii;
            // boundless where the OSD joins the band.
            property real barFlat: 1e9
            function takeBarInner() {
                const joins = GlobalStates.frameJoins[osdRoot.screen?.name ?? ""] ?? null;
                const w = osdRoot.screen?.width ?? 0, h = osdRoot.screen?.height ?? 0;
                const band = Geo.joinBandEdge(osdRoot.edge, osdRoot.bandFallback, w, h);
                const inner = Geo.barInnerEdgeAt(joins, osdRoot.edge, w / 2, band);
                const fromEdge = osdRoot.bottom ? h - inner : inner;
                if (Math.abs(fromEdge - osdRoot.barInner) > 0.01) osdRoot.barInner = fromEdge;
                const rec = Geo.barRecordAt(joins, osdRoot.edge, w / 2);
                const flat = rec ? rec.plate.width - 2 * Appearance.rounding.windowRounding : 1e9;
                if (flat !== osdRoot.barFlat) osdRoot.barFlat = flat;
            }
            Connections {
                target: GlobalStates
                function onFrameJoinsChanged() { Qt.callLater(osdRoot.takeBarInner); }
            }
            // One scalar grows the pill out of the plate: 0 nothing, 1 the
            // whole pill, on the spatial tier; the content is revealed by
            // the growth (the wrapper clips, the pill is pinned to the
            // plate's side). The exit is the same run back; the window goes
            // when it has run.
            property real openProgress: 0
            readonly property NumberAnimation openAnim: Appearance.animation.elementMove.numberAnimation.createObject(osdRoot)
            Behavior on openProgress {
                enabled: root.joinsFrame
                animation: osdRoot.openAnim
            }
            // Attached (Settings > Appearance > Frame): fused the whole time.
            // Detached, the default: the dock preview's phases - fused while
            // it grows and lifting off once grown, or from the first frame
            // when the pill outgrows the plate's flat (then without a
            // meniscus); on the timeout a fitting pill lands first and sinks
            // when landed, an outgrowing one shrinks first and re-attaches
            // as a drop once it fits.
            property bool openDone: false
            property bool landing: false
            readonly property bool willOutgrow: osdValuesWrapper.pillWidth > osdRoot.barFlat
            readonly property bool outgrows: osdValuesWrapper.width > osdRoot.barFlat
            readonly property bool fusedNow: FrameGeometry.osdAttached ? true
                : FrameGeometry.barPlateless ? false
                : (GlobalStates.osdVolumeOpen ? !(osdRoot.willOutgrow || osdRoot.openDone) : !osdRoot.outgrows)
            // A bar with no plate: released from the first frame, and the lift
            // RIDES the growth - the pill grows out of the bar's edge and
            // settles its gap on the one scalar, and sinks back the same way.
            // With the lift on the join's own spring the pill grew, then crept
            // 10 px away over 400 ms, and crept back before it collapsed
            // (footage, 60 fps): two motions in sequence, read as a drift.
            // There is no neck here to make the second one a cleavage.
            readonly property real liftRide: FrameGeometry.barPlateless ? osdValuesWrapper.grow : 1
            Connections {
                target: GlobalStates
                function onOsdVolumeOpenChanged() {
                    if (!root.joinsFrame) return;
                    if (GlobalStates.osdVolumeOpen) {
                        osdRoot.landing = false;
                        sinkFade.stop();
                        contentColumnLayout.opacity = 1;
                        osdRoot.openDone = osdRoot.openProgress >= 0.999 && osdValuesWrapper.height > 0;
                        osdRoot.openProgress = 1;
                        return;
                    }
                    osdRoot.openDone = false;
                    if (FrameGeometry.osdAttached || FrameGeometry.barPlateless || osdRoot.willOutgrow || osdJoin.lift <= 0.5) osdRoot.sink();
                    else osdRoot.landing = true;
                }
            }
            // Released when the growth ARRIVES, not when its animation ends:
            // the spatial tier's curve has the pill at full size a third of
            // the way in and spends the rest settling, and a release on the
            // animation's end put a 280 ms pause between the growth and the
            // lift (footage, 30 fps frames). The end stays as the fallback.
            onOpenProgressChanged: {
                if (GlobalStates.osdVolumeOpen && !osdRoot.openDone && osdRoot.openProgress >= 0.97) osdRoot.openDone = true;
            }
            Connections {
                target: osdRoot.openAnim
                function onRunningChanged() {
                    if (osdRoot.openAnim.running) return;
                    if (GlobalStates.osdVolumeOpen && osdRoot.openProgress >= 0.999) osdRoot.openDone = true;
                    if (root.leaving && osdRoot.openProgress <= 0.001) {
                        root.leaving = false;
                        root.windowUp = false;
                    }
                }
            }
            // Landed when the gap is closed and the neck whole (the bar
            // popup's test).
            Connections {
                target: osdJoin
                function onStateChanged() {
                    if (osdRoot.landing && osdJoin.lift < 0.75 && osdJoin.state.neck > 0.9) { osdRoot.landing = false; osdRoot.sink(); }
                }
                function onMovingChanged() {
                    if (!osdJoin.moving && osdRoot.landing) { osdRoot.landing = false; osdRoot.sink(); }
                }
            }
            // The sink: the indicator vanishes in place as the pill starts to
            // collapse - the fast tier, decelerating (the bar popup's lesson:
            // a clip cut it, a fade held first stalled the close, a scale
            // squashed it).
            function sink() {
                if (GlobalStates.osdVolumeOpen) return;
                if (!sinkFade.running) sinkFade.restart();
                osdRoot.openProgress = 0;
            }
            NumberAnimation {
                id: sinkFade
                target: contentColumnLayout
                property: "opacity"
                to: 0
                duration: Appearance.animation.elementMoveFast.duration
                easing.type: Easing.BezierSpline
                easing.bezierCurve: Appearance.animationCurves.emphasizedDecel
            }
            Component.onCompleted: {
                osdRoot.takeBarInner();
                if (root.joinsFrame) osdRoot.openProgress = 1;
            }
            FrameJoin {
                id: osdJoin
                anchors.fill: parent
                plate: osdValuesWrapper
                edge: osdRoot.edge
                attached: osdRoot.fusedNow
                travel: Appearance.sizes.elevationMargin
                bandInset: 0
                color: FrameGeometry.color
                active: root.joinsFrame
                paintsLocally: false
                paintsAtRest: true
            }
            readonly property bool plateOnFrame: root.joinsFrame && osdJoin.drawsPlate
            // The plate's colour: the band's while fused, the pill's own
            // while released, on the colour tier.
            property color platePaint: osdJoin.fused ? FrameGeometry.color : Appearance.colors.colLayer0
            Behavior on platePaint { animation: Appearance.animation.elementMoveFast.colorAnimation.createObject(this) }
            readonly property var frameJoinRecord: {
                if (!osdJoin.active || !osdJoin.painting || !osdRoot.screen) return null;
                if (osdValuesWrapper.height <= 3 || osdValuesWrapper.width <= 0) return null;
                osdValuesWrapper.x; osdValuesWrapper.y; columnLayout.x; columnLayout.y;
                const at = osdValuesWrapper.mapToItem(null, 0, 0);
                const oy = osdRoot.bottom ? osdRoot.screen.height - osdRoot.barInner - osdRoot.height : osdRoot.barInner;
                // The pill's visible part: as tall as the wrapper has grown,
                // never taller than the pill (the protection message below
                // it is its own red card, not part of the plate).
                const h = Math.min(osdValuesWrapper.height, osdValuesWrapper.pillHeight);
                const r = Math.min(osdValuesWrapper.pillRadius, h / 2, osdValuesWrapper.width / 2);
                const grown = Math.pow(Math.min(1, h / Math.max(1, osdJoin.meniscus)), 2);
                // No meniscus for a pill that outgrows the plate (the dock
                // preview's rule): released from its first frame, it was
                // never fused.
                const necked = (!FrameGeometry.osdAttached && osdRoot.willOutgrow) || FrameGeometry.barPlateless ? 0 : grown;
                return {
                    edge: osdRoot.edge,
                    plate: { x: at.x, y: at.y + oy + (osdRoot.bottom ? osdValuesWrapper.height - h : 0), width: osdValuesWrapper.width, height: h },
                    radii: { topLeft: r, topRight: r, bottomRight: r, bottomLeft: r },
                    gap: osdJoin.state.gap * osdRoot.liftRide, neck: osdJoin.state.neck * necked, bulge: osdJoin.state.bulge * necked,
                    meniscus: osdJoin.meniscus, blendPerPixel: osdJoin.blendPerPixel,
                    climbFraction: osdJoin.climbFraction, color: osdRoot.platePaint,
                    // The released pill's border, fading in with the lift.
                    strokeWidth: Appearance.borderWidth.standard * Math.min(1, osdJoin.lift * osdRoot.liftRide / Math.max(1, osdJoin.travel)),
                    strokeColor: Appearance.colors.colLayer0Border
                };
            }
            function publishFrameJoin(record) {
                const name = osdRoot.screen?.name ?? "";
                if (!name) return;
                GlobalStates.publishFrameJoin(name, "osd", record);
            }
            onFrameJoinRecordChanged: publishFrameJoin(frameJoinRecord)
            Component.onDestruction: publishFrameJoin(null)

            // Blur only the painted indicator body. Every indicator reserves an
            // elevation margin inside this surface and the text ones draw their
            // drop shadow into it, which the catch-all whole-surface blur frosted
            // into a muddy fringe (#89, the deferred half of #82; the caps lock
            // OSD is the one apollo79 reported). Same treatment as the
            // bar/sidebars/dock; pairs with rules.lua turning the layerrule
            // blur off for this namespace. The protection message is left out:
            // its m3error fill is a flat opaque hex, so a backdrop blur behind
            // it can never show, and it keeps its row in the column even while
            // hidden by opacity alone - covering it would be a no-op that only
            // risks frosting bare wallpaper if that gate were ever wrong.
            // ...and not while the frame paints the pill: the frost for it
            // is the frame's outline region then (the islands learnt this).
            WindowBlurRegion {
                targetWindow: osdRoot
                regionItem: osdRoot.plateOnFrame ? null : (osdIndicatorLoader.item?.backgroundItem ?? null)
                regionRadius: osdIndicatorLoader.item?.backgroundRadius ?? 0
            }

            exclusionMode: ExclusionMode.Ignore
            exclusiveZone: 0
            margins {
                top: root.joinsFrame ? osdRoot.barInner : Appearance.sizes.barHeight
                bottom: root.joinsFrame ? osdRoot.barInner : Appearance.sizes.barHeight
            }

            implicitWidth: columnLayout.implicitWidth
            // Room for the pill at full size, the message under it and the
            // meniscus' reach, whatever the growth has revealed.
            implicitHeight: root.joinsFrame ? contentColumnLayout.implicitHeight + Appearance.sizes.elevationMargin * 2 : columnLayout.implicitHeight
            visible: osdLoader.active

            ColumnLayout {
                id: columnLayout
                anchors.horizontalCenter: parent.horizontalCenter
                // On the plate's edge less the join's lift, joined; where it
                // always was otherwise.
                y: !root.joinsFrame ? 0 : (osdRoot.bottom ? osdRoot.height - height - osdJoin.lift * osdRoot.liftRide : osdJoin.lift * osdRoot.liftRide)

                Item {
                    id: osdValuesWrapper
                    // The pill, out of the indicator's box: the indicator keeps
                    // an elevation margin around it for its shadow.
                    readonly property real pillWidth: Math.max(0, contentColumnLayout.implicitWidth - 2 * Appearance.sizes.elevationMargin)
                    readonly property real pillHeight: Math.max(0, (osdIndicatorLoader.item?.implicitHeight ?? 0) - 2 * Appearance.sizes.elevationMargin)
                    readonly property real pillRadius: osdIndicatorLoader.item?.backgroundRadius ?? 0
                    // The growth (frame mode): the pill unrolls out of the
                    // plate from a parked square's width and no height; the
                    // message row below it comes with the height.
                    readonly property real grow: root.joinsFrame ? Math.max(0, Math.min(1, osdRoot.openProgress)) : 1
                    readonly property real parkedSize: Appearance.sizes.elevationMargin * 2
                    readonly property real fullHeight: root.joinsFrame
                        ? pillHeight + (root.protectionMessage !== "" ? protectionMessageWrapper.implicitHeight : 0)
                        : contentColumnLayout.implicitHeight
                    implicitHeight: root.joinsFrame ? Math.max(0, fullHeight * grow) : contentColumnLayout.implicitHeight
                    implicitWidth: root.joinsFrame
                        ? Math.min(pillWidth, parkedSize) + (pillWidth - Math.min(pillWidth, parkedSize)) * grow
                        : contentColumnLayout.implicitWidth
                    clip: true

                    MouseArea {
                        anchors.fill: parent
                        hoverEnabled: true
                        onEntered: GlobalStates.osdVolumeOpen = false
                    }

                    Column {
                        id: contentColumnLayout
                        // Joined: the pill's plate-side edge on the wrapper's,
                        // centred along it, so the growth reveals it out of
                        // the plate (coordinates, the indicator's margin taken
                        // off). Otherwise the box the wrapper is sized to.
                        width: root.joinsFrame ? implicitWidth : parent.width
                        x: root.joinsFrame ? (parent.width - width) / 2 : 0
                        y: root.joinsFrame
                            ? (osdRoot.bottom ? parent.height - implicitHeight + Appearance.sizes.elevationMargin : -Appearance.sizes.elevationMargin)
                            : 0
                        spacing: 0

                        Loader {
                            id: osdIndicatorLoader
                            source: root.indicators.find(i => i.id === root.currentIndicator)?.sourceUrl
                            onLoaded: if (item && item.hasOwnProperty("plateOnFrame")) item.plateOnFrame = Qt.binding(() => osdRoot.plateOnFrame)

                            // A `url` cannot be interpolated, so this Behavior
                            // does not animate the property - it DEFERS the
                            // write. The bare `PropertyAction {}` is the whole
                            // of it: with no target and no property, inside a
                            // Behavior it means "apply the pending write
                            // here", so the outgoing indicator leaves before
                            // it is destroyed rather than being cut off in the
                            // frame its replacement arrives. There is no
                            // pending-value field, no state machine and no
                            // pair of chained Timers whose intervals have to
                            // keep agreeing with two animations' durations.
                            //
                            // It belongs on THIS loader because the OSD is one
                            // window that nine sources write into: touching
                            // volume and then brightness inside
                            // Config.options.osd.timeout swaps the indicator
                            // under a surface that is already up, so the swap
                            // is a transition the user watches rather than a
                            // build nobody sees. Measured with a qml6 probe
                            // before it was written: the initial source is
                            // still applied immediately (a Behavior does not
                            // fire before its component is finalized), so an
                            // OSD that is opening does not wait for a fade of
                            // nothing.
                            Behavior on source {
                                SequentialAnimation {
                                    NumberAnimation {
                                        target: osdIndicatorLoader
                                        property: "opacity"
                                        to: 0
                                        duration: Appearance.animation.elementMoveExit.duration
                                        easing.type: Appearance.animation.elementMoveExit.type
                                        easing.bezierCurve: Appearance.animation.elementMoveExit.bezierCurve
                                    }
                                    PropertyAction {}
                                    NumberAnimation {
                                        target: osdIndicatorLoader
                                        property: "opacity"
                                        to: 1
                                        duration: Appearance.animation.elementMoveEnter.duration
                                        easing.type: Appearance.animation.elementMoveEnter.type
                                        easing.bezierCurve: Appearance.animation.elementMoveEnter.bezierCurve
                                    }
                                }
                            }
                        }

                        Item {
                            id: protectionMessageWrapper
                            anchors.horizontalCenter: parent.horizontalCenter
                            implicitHeight: protectionMessageBackground.implicitHeight
                            implicitWidth: protectionMessageBackground.implicitWidth
                            opacity: root.protectionMessage !== "" ? 1 : 0

                            StyledRectangularShadow {
                                target: protectionMessageBackground
                            }
                            Rectangle {
                                id: protectionMessageBackground
                                anchors.centerIn: parent
                                color: Appearance.m3colors.m3error
                                property real padding: Appearance.spacing.space150
                                implicitHeight: protectionMessageRowLayout.implicitHeight + padding * 2
                                implicitWidth: protectionMessageRowLayout.implicitWidth + padding * 2
                                radius: Appearance.rounding.normal

                                RowLayout {
                                    id: protectionMessageRowLayout
                                    anchors.centerIn: parent
                                    MaterialSymbol {
                                        id: protectionMessageIcon
                                        text: "dangerous"
                                        iconSize: Appearance.font.pixelSize.hugeass
                                        color: Appearance.m3colors.m3onError
                                    }
                                    StyledText {
                                        id: protectionMessageTextWidget
                                        horizontalAlignment: Text.AlignHCenter
                                        color: Appearance.m3colors.m3onError
                                        wrapMode: Text.Wrap
                                        text: root.protectionMessage
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    IpcHandler {
        target: "osdVolume"

        function trigger() {
            root.triggerOsd();
        }

        function hide() {
            GlobalStates.osdVolumeOpen = false;
        }

        function toggle() {
            GlobalStates.osdVolumeOpen = !GlobalStates.osdVolumeOpen;
        }
    }
    GlobalShortcut {
        name: "osdVolumeTrigger"
        description: "Triggers volume OSD on press"

        onPressed: {
            root.triggerOsd();
        }
    }
    GlobalShortcut {
        name: "osdVolumeHide"
        description: "Hides volume OSD on press"

        onPressed: {
            GlobalStates.osdVolumeOpen = false;
        }
    }
}
