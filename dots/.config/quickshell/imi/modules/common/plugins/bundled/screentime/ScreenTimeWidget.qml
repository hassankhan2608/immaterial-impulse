pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import qs.modules.common
import qs.modules.common.widgets
import "."

// Same geometry contract as DockerWidget: fixed bounded canvas (the BarGroup
// Loader derives its width from this item), value first, primary-colored
// circular icon closing the row. Click toggles the popup.
MouseArea {
    id: root

    property bool vertical: Config.options.bar.vertical
    property bool isMaterial: Config.options.bar.cornerStyle === 3
    property bool popupOpen: false

    implicitWidth: root.vertical ? 32 : 64
    implicitHeight: root.vertical ? 54 : Appearance.sizes.barHeight
    width: implicitWidth
    height: implicitHeight

    acceptedButtons: Qt.LeftButton
    hoverEnabled: false
    cursorShape: Qt.PointingHandCursor
    onClicked: {
        root.popupOpen = !root.popupOpen;
        if (root.popupOpen) ScreenTimeService.onPanelOpened();
    }

    Item {
        id: rowContent
        visible: !root.vertical
        anchors.fill: parent

        StyledText {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: ScreenTimeService.todayActiveLabel
            font.pixelSize: Appearance.font.pixelSize.small
            color: root.isMaterial && ScreenTimeService.trackerOnline
                ? Appearance.colors.colPrimary
                : ScreenTimeService.trackerOnline
                    ? Appearance.colors.colOnLayer1 : Appearance.colors.colError
        }

        Rectangle {
            width: 25
            height: 25
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            radius: Appearance.rounding.full
            color: ScreenTimeService.trackerOnline
                ? Appearance.colors.colPrimary : Appearance.colors.colError

            MaterialSymbol {
                anchors.centerIn: parent
                fill: 0
                text: "calendar_month"
                iconSize: Appearance.font.pixelSize.normal
                color: ScreenTimeService.trackerOnline
                    ? Appearance.colors.colOnPrimary : Appearance.colors.colOnError
            }
        }
    }

    Item {
        id: colContent
        visible: root.vertical
        anchors.fill: parent

        Rectangle {
            width: 25
            height: 25
            anchors.top: parent.top
            anchors.horizontalCenter: parent.horizontalCenter
            radius: Appearance.rounding.full
            color: ScreenTimeService.trackerOnline
                ? Appearance.colors.colPrimary : Appearance.colors.colError

            MaterialSymbol {
                anchors.centerIn: parent
                fill: 0
                text: "calendar_month"
                iconSize: Appearance.font.pixelSize.normal
                color: ScreenTimeService.trackerOnline
                    ? Appearance.colors.colOnPrimary : Appearance.colors.colOnError
            }
        }

        StyledText {
            anchors.bottom: parent.bottom
            anchors.horizontalCenter: parent.horizontalCenter
            text: ScreenTimeService.todayActiveLabel
            font.pixelSize: Appearance.font.pixelSize.small
            color: root.isMaterial && ScreenTimeService.trackerOnline
                ? Appearance.colors.colPrimary
                : ScreenTimeService.trackerOnline
                    ? Appearance.colors.colOnLayer1 : Appearance.colors.colError
        }
    }

    Loader {
        id: popupLoader
        active: root.popupOpen
        sourceComponent: ScreenTimePopup {
            pinnedOpen: true
            hoverTarget: root
            onDismissRequested: root.popupOpen = false
            onPinnedOpenChanged: {
                if (!pinnedOpen) root.popupOpen = false;
            }
        }
    }
}
