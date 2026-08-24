pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.modules.common
import qs.modules.common.widgets
import "."
import "components"
import "ScreenTimeModel.js" as Model

// Screen Time panel — M3 Expressive composition of Omalog's feature set:
// a hero card carrying the headline number and the day timeline, stat rows
// with dividers, chart cards, apps list at full width with icons, categories
// and domains paired below. 500 wide, scroll capped at 560.
StyledPopup {
    id: root

    readonly property color cardColor: Appearance.colors.colSurfaceContainerLow

    onPopupVisibleChanged: if (!popupVisible) ScreenTimeService.onPanelClosed()

    // Card used across all tabs
    component PanelCard: Rectangle {
        id: card
        default property alias content: cardContent.data
        Layout.fillWidth: true
        Layout.preferredWidth: 500
        implicitHeight: cardContent.implicitHeight + Appearance.spacing.space300
        radius: Appearance.rounding.normal
        color: root.cardColor

        ColumnLayout {
            id: cardContent
            anchors.fill: parent
            anchors.margins: Appearance.spacing.space200
            spacing: Appearance.spacing.space150
        }
    }

    // Card title row: icon + label
    component CardTitle: RowLayout {
        id: title
        property string icon: ""
        property string label: ""
        Layout.fillWidth: true
        spacing: Appearance.spacing.space100

        MaterialSymbol {
            fill: 0
            text: title.icon
            iconSize: Appearance.font.pixelSize.normal
            color: Appearance.colors.colPrimary
        }
        StyledText {
            text: title.label
            font.pixelSize: Appearance.font.pixelSize.small
            font.weight: Font.DemiBold
            color: Appearance.colors.colOnSurfaceVariant
        }
        Item { Layout.fillWidth: true }
    }

    // Label-over-value mini stat used inside hero and stats cards
    component MiniStat: ColumnLayout {
        id: stat
        property string label: ""
        property string value: ""
        Layout.fillWidth: true
        Layout.preferredWidth: 1
        spacing: Appearance.spacing.space25

        StyledText {
            text: stat.label
            color: Appearance.colors.colOnSurfaceVariant
            font.pixelSize: Appearance.font.pixelSize.smaller
        }
        StyledText {
            Layout.fillWidth: true
            text: stat.value
            color: Appearance.colors.colOnLayer1
            font.pixelSize: Appearance.font.pixelSize.small
            font.weight: Font.Bold
            font.features: { "tnum": 1 }
            elide: Text.ElideRight
        }
    }

    ColumnLayout {
        id: panelContent
        spacing: Appearance.spacing.space150

        // ---- Header ----
        RowLayout {
            Layout.fillWidth: true
            Layout.preferredWidth: 500
            spacing: Appearance.spacing.space125

            MaterialShapeWrappedMaterialSymbol {
                text: "calendar_month"
                shape: MaterialShape.Shape.Cookie9Sided
                padding: Appearance.spacing.space125
                iconSize: Appearance.font.pixelSize.large
                color: ScreenTimeService.trackerOnline
                    ? Appearance.colors.colPrimaryContainer : Appearance.colors.colErrorContainer
                colSymbol: ScreenTimeService.trackerOnline
                    ? Appearance.colors.colOnPrimaryContainer : Appearance.colors.colOnErrorContainer
            }

            ColumnLayout {
                spacing: 0
                StyledText {
                    text: qsTr("Screen Time")
                    font.pixelSize: Appearance.font.pixelSize.large
                    font.weight: Font.DemiBold
                    color: Appearance.colors.colOnLayer1
                }
                StyledText {
                    text: ScreenTimeService.trackerOnline
                        ? qsTr("Active today: %1").arg(ScreenTimeService.todayActiveLabel)
                        : qsTr("ActivityWatch not running")
                    font.pixelSize: Appearance.font.pixelSize.small
                    color: ScreenTimeService.trackerOnline
                        ? Appearance.colors.colSubtext : Appearance.colors.colError
                }
            }

            Item { Layout.fillWidth: true }

            MaterialLoadingIndicator {
                Layout.alignment: Qt.AlignVCenter
                implicitSize: 24
                loading: ScreenTimeService.loading
                visible: ScreenTimeService.loading
            }

            IconToolbarButton {
                Layout.fillHeight: false
                implicitHeight: 36
                text: "refresh"
                enabled: !ScreenTimeService.loading
                onClicked: ScreenTimeService.refreshAll()
                StyledToolTip { text: qsTr("Refresh") }
            }
            IconToolbarButton {
                Layout.fillHeight: false
                implicitHeight: 36
                text: "close"
                onClicked: root.pinnedOpen = false
                StyledToolTip { text: qsTr("Close") }
            }
        }

        // ---- Offline banner ----
        Rectangle {
            visible: !ScreenTimeService.trackerOnline
            Layout.fillWidth: true
            Layout.preferredWidth: 500
            implicitHeight: offlineText.implicitHeight + Appearance.spacing.space300
            radius: Appearance.rounding.normal
            color: Appearance.colors.colErrorContainer

            ColumnLayout {
                id: offlineText
                anchors.centerIn: parent
                width: parent.width - Appearance.spacing.space300
                spacing: Appearance.spacing.space50

                StyledText {
                    Layout.fillWidth: true
                    text: qsTr("ActivityWatch not detected")
                    color: Appearance.colors.colOnErrorContainer
                    font.pixelSize: Appearance.font.pixelSize.normal
                    font.weight: Font.Bold
                }
                StyledText {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: qsTr("Screen Time reads ActivityWatch's local database. Start the trackers with: systemctl --user start aw-server-rust.service aw-awatcher.service — then reopen this panel. Add the ActivityWatch Web Extension in your browser for domain tracking.")
                    color: Appearance.colors.colOnErrorContainer
                    font.pixelSize: Appearance.font.pixelSize.smaller
                }
            }
        }

        // ---- Tabs ----
        SecondaryTabBar {
            id: tabBar
            Layout.fillWidth: true
            Layout.preferredWidth: 500
            Component.onCompleted: currentIndex = ScreenTimeService.activeTab
            onCurrentIndexChanged: ScreenTimeService.activeTab = currentIndex

            SecondaryTabButton { buttonIcon: "today"; buttonText: qsTr("Today") }
            SecondaryTabButton { buttonIcon: "date_range"; buttonText: qsTr("Week") }
            SecondaryTabButton { buttonIcon: "calendar_month"; buttonText: qsTr("Month") }
        }

        // ---- Scrollable body ----
        Flickable {
            id: scrollView
            Layout.fillWidth: true
            Layout.preferredWidth: 500
            Layout.preferredHeight: Math.min(bodyColumn.implicitHeight, 560)
            contentWidth: width
            contentHeight: bodyColumn.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            ScrollBar.vertical: ScrollBar {}

            ColumnLayout {
                id: bodyColumn
                width: scrollView.width
                spacing: Appearance.spacing.space125

                // ===================== TODAY =====================
                ColumnLayout {
                    visible: ScreenTimeService.activeTab === 0 && ScreenTimeService.trackerOnline
                    Layout.fillWidth: true
                    spacing: Appearance.spacing.space125

                    // Hero: headline number + mini stats + timeline
                    PanelCard {
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Appearance.spacing.space150

                            ColumnLayout {
                                spacing: 0
                                Layout.alignment: Qt.AlignTop

                                StyledText {
                                    text: qsTr("ACTIVE TODAY")
                                    color: Appearance.colors.colOnSurfaceVariant
                                    font.pixelSize: Appearance.font.pixelSize.smaller
                                    font.weight: Font.DemiBold
                                    font.capitalization: Font.AllUppercase
                                }
                                StyledText {
                                    text: Model.formatDuration(ScreenTimeService.todayData.active_secs || 0)
                                    color: Appearance.colors.colOnLayer1
                                    font.pixelSize: Appearance.font.pixelSize.hugeass
                                    font.weight: Font.Bold
                                    font.features: { "tnum": 1 }
                                }
                            }

                            Item { Layout.fillWidth: true }

                            MiniStat {
                                Layout.preferredWidth: 1
                                label: qsTr("LONGEST")
                                value: {
                                    const ls = ScreenTimeService.todayData.longest_stretch
                                    if (!ls || !ls.seconds) return "—"
                                    return Model.formatDurationShort(ls.seconds)
                                }
                            }
                            Rectangle {
                                implicitWidth: 1
                                Layout.fillHeight: true
                                color: Appearance.colors.colSurfaceContainerHighest
                            }
                            MiniStat {
                                Layout.preferredWidth: 1
                                label: qsTr("BEST WINDOW")
                                value: {
                                    const bw = ScreenTimeService.todayData.best_window
                                    if (!bw || !bw.seconds) return "—"
                                    return Model.formatWindow(bw.start_hour, bw.end_hour)
                                }
                            }
                            Rectangle {
                                implicitWidth: 1
                                Layout.fillHeight: true
                                color: Appearance.colors.colSurfaceContainerHighest
                            }
                            MiniStat {
                                Layout.preferredWidth: 1.4
                                label: qsTr("PATTERN")
                                value: Model.formatPatternShift(ScreenTimeService.todayData.pattern_shift) || "—"
                            }
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: 1
                            color: Appearance.colors.colSurfaceContainerHighest
                        }

                        TimelineBarcode {
                            Layout.fillWidth: true
                            timeline: ScreenTimeService.todayData.timeline || []
                        }
                    }

                    // Hourly chart
                    PanelCard {
                        CardTitle { icon: "schedule"; label: qsTr("Active Minutes per Hour") }
                        HourlyChart {
                            Layout.fillWidth: true
                            hourly: ScreenTimeService.todayData.hourly || []
                        }
                    }

                    // Apps at full width
                    PanelCard {
                        CardTitle { icon: "apps"; label: qsTr("Top Apps") }
                        TopList {
                            Layout.fillWidth: true
                            items: ScreenTimeService.todayData.top_apps || []
                            barColorKey: "app"
                            comfortable: true
                        }
                    }

                    // Categories + Domains paired
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Appearance.spacing.space125

                        PanelCard {
                            Layout.preferredWidth: 1
                            CardTitle { icon: "category"; label: qsTr("Categories") }
                            TopList {
                                Layout.fillWidth: true
                                items: ScreenTimeService.todayData.top_categories || []
                                barColorKey: "category"
                            }
                        }
                        PanelCard {
                            Layout.preferredWidth: 1
                            CardTitle { icon: "language"; label: qsTr("Domains") }
                            TopList {
                                Layout.fillWidth: true
                                items: ScreenTimeService.todayData.top_domains || []
                                barColorKey: "domain"
                                isDomainList: true
                            }
                        }
                    }
                }

                StyledText {
                    visible: ScreenTimeService.activeTab === 1 && ScreenTimeService.trackerOnline
                        && !ScreenTimeService.weekData.tracker_online
                    text: qsTr("Loading week…")
                    color: Appearance.colors.colSubtext
                    font.pixelSize: Appearance.font.pixelSize.small
                }

                // ===================== WEEK =====================
                ColumnLayout {
                    visible: ScreenTimeService.activeTab === 1 && ScreenTimeService.weekData.tracker_online === true
                    Layout.fillWidth: true
                    spacing: Appearance.spacing.space125

                    PanelCard {
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Appearance.spacing.space150

                            MiniStat {
                                Layout.preferredWidth: 1
                                label: qsTr("TOTAL ACTIVE")
                                value: Model.formatDuration(ScreenTimeService.weekData.total_active_secs || 0)
                            }
                            Rectangle {
                                implicitWidth: 1
                                Layout.fillHeight: true
                                color: Appearance.colors.colSurfaceContainerHighest
                            }
                            MiniStat {
                                Layout.preferredWidth: 1
                                label: qsTr("DAILY AVG")
                                value: Model.formatDuration(ScreenTimeService.weekData.daily_avg_secs || 0)
                                    + " · " + (ScreenTimeService.weekData.avg_over_days || 0) + "d"
                            }
                            Rectangle {
                                implicitWidth: 1
                                Layout.fillHeight: true
                                color: Appearance.colors.colSurfaceContainerHighest
                            }
                            MiniStat {
                                Layout.preferredWidth: 1.2
                                label: qsTr("BEST DAY")
                                value: ScreenTimeService.weekData.best_day
                                    ? Model.formatDurationShort(ScreenTimeService.weekData.best_day.secs)
                                      + " · " + ScreenTimeService.weekData.best_day.date
                                    : "—"
                            }
                        }
                    }

                    PanelCard {
                        CardTitle { icon: "calendar_view_week"; label: qsTr("This Week · Mon → Sun") }
                        StackedWeekBars {
                            Layout.fillWidth: true
                            days: ScreenTimeService.weekData.days || []
                        }
                    }

                    PanelCard {
                        CardTitle { icon: "apps"; label: qsTr("Top Apps · 7d") }
                        TopList {
                            Layout.fillWidth: true
                            items: ScreenTimeService.weekData.top_apps || []
                            barColorKey: "app"
                            comfortable: true
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Appearance.spacing.space125

                        PanelCard {
                            Layout.preferredWidth: 1
                            CardTitle { icon: "category"; label: qsTr("Categories · 7d") }
                            TopList {
                                Layout.fillWidth: true
                                items: ScreenTimeService.weekData.top_categories || []
                                barColorKey: "category"
                            }
                        }
                        PanelCard {
                            Layout.preferredWidth: 1
                            CardTitle { icon: "language"; label: qsTr("Domains · 7d") }
                            TopList {
                                Layout.fillWidth: true
                                items: ScreenTimeService.weekData.top_domains || []
                                barColorKey: "domain"
                                isDomainList: true
                            }
                        }
                    }
                }

                StyledText {
                    visible: ScreenTimeService.activeTab === 2 && ScreenTimeService.trackerOnline
                        && !ScreenTimeService.monthData.tracker_online
                    text: qsTr("Loading month…")
                    color: Appearance.colors.colSubtext
                    font.pixelSize: Appearance.font.pixelSize.small
                }

                // ===================== MONTH =====================
                ColumnLayout {
                    visible: ScreenTimeService.activeTab === 2 && ScreenTimeService.monthData.tracker_online === true
                    Layout.fillWidth: true
                    spacing: Appearance.spacing.space125

                    PanelCard {
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Appearance.spacing.space150

                            MiniStat {
                                Layout.preferredWidth: 1
                                label: qsTr("TOTAL ACTIVE")
                                value: Model.formatDuration(ScreenTimeService.monthData.total_active_secs || 0)
                            }
                            Rectangle {
                                implicitWidth: 1
                                Layout.fillHeight: true
                                color: Appearance.colors.colSurfaceContainerHighest
                            }
                            MiniStat {
                                Layout.preferredWidth: 1
                                label: qsTr("DAILY AVG")
                                value: Model.formatDuration(ScreenTimeService.monthData.daily_avg_secs || 0)
                                    + " · " + (ScreenTimeService.monthData.active_days || 0)
                                      + qsTr(" active days")
                            }
                            Rectangle {
                                implicitWidth: 1
                                Layout.fillHeight: true
                                color: Appearance.colors.colSurfaceContainerHighest
                            }
                            MiniStat {
                                Layout.preferredWidth: 1.2
                                label: qsTr("BEST DAY")
                                value: ScreenTimeService.monthData.best_day
                                    ? Model.formatDurationShort(ScreenTimeService.monthData.best_day.secs)
                                      + " · " + ScreenTimeService.monthData.best_day.date
                                    : "—"
                            }
                        }
                    }

                    PanelCard {
                        CardTitle { icon: "grid_view"; label: qsTr("Year Heatmap") }
                        YearHeatmap {
                            Layout.fillWidth: true
                            heatmap: ScreenTimeService.monthData.heatmap || []
                            monthLabels: ScreenTimeService.monthData.month_labels || []
                        }
                    }

                    PanelCard {
                        CardTitle { icon: "apps"; label: qsTr("Top Apps · 30d") }
                        TopList {
                            Layout.fillWidth: true
                            items: ScreenTimeService.monthData.top_apps || []
                            barColorKey: "app"
                            comfortable: true
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Appearance.spacing.space125

                        PanelCard {
                            Layout.preferredWidth: 1
                            CardTitle { icon: "category"; label: qsTr("Categories · 30d") }
                            TopList {
                                Layout.fillWidth: true
                                items: ScreenTimeService.monthData.top_categories || []
                                barColorKey: "category"
                            }
                        }
                        PanelCard {
                            Layout.preferredWidth: 1
                            CardTitle { icon: "language"; label: qsTr("Domains · 30d") }
                            TopList {
                                Layout.fillWidth: true
                                items: ScreenTimeService.monthData.top_domains || []
                                barColorKey: "domain"
                                isDomainList: true
                            }
                        }
                    }
                }
            }
        }
    }
}
