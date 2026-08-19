import qs.services
import qs.modules.common
import qs.modules.common.widgets
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Qt5Compat.GraphicalEffects
import Qt.labs.synchronizer

Item {
    id: root
    required property var scopeRoot
    property int sidebarPadding: Appearance.spacing.space125
    anchors.fill: parent
    property bool aiChatEnabled: Config.options.policies.ai !== 0
    property bool tailnetEnabled: Config.options.sidebar.tailnet.enable && Tailscale.installed
    property bool translatorEnabled: Config.options.sidebar.translator.enable
    property bool animeEnabled: Config.options.policies.weeb !== 0
    property bool animeCloset: Config.options.policies.weeb === 2
    property bool mediaEnabled: Config.options.sidebar.media.enable
    readonly property int tailnetIndex: root.tailnetEnabled ? (root.aiChatEnabled ? 1 : 0) : -1
    property var tabButtonList: [
        ...(root.aiChatEnabled ? [{"icon": "neurology", "name": Translation.tr("Intelligence")}] : []),
        ...(root.tailnetEnabled ? [{"icon": Tailscale.materialSymbol, "name": Translation.tr("Tailnet")}] : []),
        ...(root.translatorEnabled ? [{"icon": "translate", "name": Translation.tr("Translator")}] : []),
        ...(root.mediaEnabled ? [{"icon": "music_note", "name": Translation.tr("Media")}] : []),
        ...((root.animeEnabled && !root.animeCloset) ? [{"icon": "bookmark_heart", "name": Translation.tr("Anime")}] : [])
    ]
    property int tabCount: swipeView.count

    function focusActiveItem() {
        swipeView.currentItem.forceActiveFocus()
    }

    Keys.onPressed: (event) => {
        if (event.modifiers === Qt.ControlModifier) {
            if (event.key === Qt.Key_PageDown) {
                swipeView.incrementCurrentIndex()
                event.accepted = true;
            }
            else if (event.key === Qt.Key_PageUp) {
                swipeView.decrementCurrentIndex()
                event.accepted = true;
            }
        }
    }

    ColumnLayout {
        anchors {
            fill: parent
            margins: sidebarPadding
        }
        spacing: verticalTabBar.expanded ? -Appearance.spacing.space25 : 0

        VerticalTabBar {
            id: verticalTabBar
            visible: tabButtonList.length > 0
            Layout.fillWidth: true
            tabButtonList: root.tabButtonList
            currentIndex: swipeView.currentIndex
            onCurrentIndexChanged: swipeView.currentIndex = currentIndex
        }

        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            implicitWidth: swipeView.implicitWidth
            implicitHeight: swipeView.implicitHeight
            topLeftRadius: 0
            bottomLeftRadius: Appearance.rounding.normal
            topRightRadius: 0
            bottomRightRadius: Appearance.rounding.normal
            color: Appearance.colors.colLayer1

            SwipeView { // Content pages
                id: swipeView
                anchors.fill: parent
                spacing: Appearance.spacing.space150

                clip: true
                layer.enabled: true
                layer.effect: OpacityMask {
                    maskSource: Rectangle {
                        width: swipeView.width
                        height: swipeView.height
                        radius: Appearance.rounding.small
                    }
                }

                contentChildren: [
                    ...(root.aiChatEnabled ? [aiChat.createObject()] : []),
                    ...(root.tailnetEnabled ? [tailnet.createObject()] : []),
                    ...(root.translatorEnabled ? [translator.createObject()] : []),
                    ...(root.mediaEnabled ? [media.createObject()] : []),
                    ...((root.tabButtonList.length === 0 || (!root.aiChatEnabled && !root.tailnetEnabled && !root.translatorEnabled && root.animeCloset)) ? [placeholder.createObject()] : []),
                    ...(root.animeEnabled ? [anime.createObject()] : []),
                ]
            }
        }

        TaildropPanel {
            // The column's own spacing keeps the tab bar flush against the
            // content pane, so this group asks for its gap itself - same
            // rhythm as the right sidebar's bottom widget group.
            Layout.topMargin: sidebarPadding
            visible: root.tailnetIndex >= 0 && swipeView.currentIndex === root.tailnetIndex
            Layout.fillWidth: true
        }

        Component {
            id: aiChat
            AiChat {}
        }
        Component {
            id: tailnet
            Tailnet {}
        }
        Component {
            id: translator
            Translator {}
        }
        Component {
            id: media
            SidebarPlayerControl {}
        }
        Component {
            id: anime
            Anime {}
        }
        Component {
            id: placeholder
            Item {
                StyledText {
                    anchors.centerIn: parent
                    text: root.animeCloset ? Translation.tr("Nothing") : Translation.tr("Enjoy your empty sidebar...")
                    color: Appearance.colors.colSubtext
                }
            }
        }
    }
}