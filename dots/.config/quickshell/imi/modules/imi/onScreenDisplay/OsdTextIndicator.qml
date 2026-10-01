import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Layouts

Item {
    id: root
    required property string icon
    required property string name
    required property string value

    // The painted body, exposed so the OSD window can scope its compositor blur
    // region to it (see WindowBlurRegion in OnScreenDisplay.qml). The radius is
    // resolved here rather than at the call site because Appearance.rounding.full
    // is the "round me completely" sentinel (9999) and not a length - a region is
    // a plain rounded rect and would otherwise be squared off against the pill.
    readonly property Item backgroundItem: indicator
    // The frame paints the pill (frame-pin-grammar.md, the OSD row): the
    // pill's own fill and shadow stand down, its content stays.
    property bool plateOnFrame: false
    readonly property real backgroundRadius: Math.round(indicator.height / 2)

    implicitWidth: Appearance.sizes.osdWidth + 4 * Appearance.sizes.elevationMargin
    implicitHeight: indicator.implicitHeight + 2 * Appearance.sizes.elevationMargin

    StyledRectangularShadow {
        target: indicator
        visible: !root.plateOnFrame
    }
    Rectangle {
        id: indicator
        anchors {
            fill: parent
            margins: Appearance.sizes.elevationMargin
        }
        radius: Appearance.rounding.full
        color: root.plateOnFrame ? "transparent" : Appearance.colors.colLayer0
        implicitWidth: contentRow.implicitWidth + 30
        implicitHeight: contentRow.implicitHeight + 18

        RowLayout {
            id: contentRow
            anchors.centerIn: parent
            spacing: Appearance.spacing.space150

            MaterialSymbol {
                Layout.alignment: Qt.AlignVCenter
                text: root.icon
                iconSize: 25
                color: Appearance.colors.colOnLayer0
            }

            ColumnLayout {
                Layout.alignment: Qt.AlignVCenter
                Layout.maximumWidth: Appearance.sizes.osdWidth - 50
                spacing: 0

                StyledText {
                    Layout.fillWidth: true
                    text: root.name
                    font.pixelSize: Appearance.font.pixelSize.smaller
                    color: Appearance.colors.colSubtext
                }
                StyledText {
                    Layout.fillWidth: true
                    text: root.value
                    font.pixelSize: Appearance.font.pixelSize.small
                    color: Appearance.colors.colOnLayer0
                    elide: Text.ElideRight
                }
            }
        }
    }
}
