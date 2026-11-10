import QtQuick
import qs.Common
import qs.Widgets
import qs.DCommon.Widgets
import qs.Modules.Plugins
import "./BtUsage.js" as BtUsage

PopoutComponent {
    id: root

    property var pluginRoot: null
    property int contentHeight: pluginRoot ? pluginRoot.popoutHeight : 540

    width: pluginRoot ? pluginRoot.popoutWidth : 400

    readonly property bool loaded: pluginRoot ? pluginRoot.usageLoaded : false
    readonly property bool connected: pluginRoot ? pluginRoot.hasConnected : false
    readonly property int connectedCount: pluginRoot ? pluginRoot.connectedDevices.length : 0
    readonly property var devices: pluginRoot ? pluginRoot.deviceList : []
    readonly property var week: pluginRoot ? pluginRoot.weekData : []
    readonly property double todaySeconds: pluginRoot ? pluginRoot.todayTotal : 0
    readonly property double todayPlaying: pluginRoot ? pluginRoot.todayPlayingTotal : 0
    readonly property double primaryLive: pluginRoot ? pluginRoot.primaryLiveSeconds : 0
    readonly property double primaryPlaying: pluginRoot ? pluginRoot.primaryPlayingSeconds : 0
    readonly property double primaryIdle: pluginRoot ? pluginRoot.primaryIdleSeconds : 0
    readonly property double primaryToday: pluginRoot ? pluginRoot.primaryTodaySeconds : 0
    readonly property double primaryPlayingToday: pluginRoot ? pluginRoot.primaryPlayingToday : 0
    readonly property double primaryIdleToday: pluginRoot ? pluginRoot.primaryIdleToday : 0
    readonly property double primaryTotal: pluginRoot ? pluginRoot.primaryTotalSeconds : 0
    readonly property int primaryBattery: pluginRoot ? pluginRoot.primaryBattery : -1
    readonly property string primaryName: pluginRoot && pluginRoot.primaryDevice
        ? (pluginRoot.primaryDevice.name || pluginRoot.primaryDevice.deviceName || "Bluetooth device")
        : ""
    readonly property string trackingSince: {
        var since = pluginRoot ? pluginRoot.usage.createdAt : 0;
        if (!since)
            return "";
        return new Date(since).toLocaleDateString(Qt.locale(), "d MMM yyyy");
    }

    readonly property double weekLive: pluginRoot ? pluginRoot.liveTodayTotal : 0
    readonly property double weekLivePlaying: pluginRoot ? pluginRoot.livePlayingTodayTotal : 0

    readonly property real weekMax: {
        var max = 1;
        for (var i = 0; i < week.length; i++) {
            var seconds = week[i].seconds + (week[i].isToday ? weekLive : 0);
            if (seconds > max)
                max = seconds;
        }
        return max;
    }

    readonly property double weekTotal: {
        var total = weekLive;
        for (var i = 0; i < week.length; i++)
            total += week[i].seconds;
        return total;
    }

    readonly property double weekPlayingTotal: {
        var total = weekLivePlaying;
        for (var i = 0; i < week.length; i++)
            total += week[i].playingSeconds || 0;
        return total;
    }

    readonly property double weekIdleTotal: Math.max(0, weekTotal - weekPlayingTotal)

    headerText: "Bluetooth usage"
    detailsText: {
        if (!loaded)
            return "Waiting for the usage daemon to write its first record";
        var parts = [];
        if (connected)
            parts.push(connectedCount + (connectedCount === 1 ? " device connected" : " devices connected"));
        parts.push(BtUsage.duration(todaySeconds) + " connected today");
        parts.push(BtUsage.duration(todayPlaying) + " listening today");
        if (trackingSince.length > 0)
            parts.push("since " + trackingSince);
        return parts.join(" \u00b7 ");
    }

    Item {
        width: parent.width
        implicitHeight: Math.max(200, root.contentHeight - root.headerHeight - root.detailsHeight - Theme.spacingL)

        DFlickable {
            id: flickable
            anchors.fill: parent
            contentWidth: width
            contentHeight: contentColumn.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Column {
                id: contentColumn
                width: flickable.width
                spacing: Theme.spacingM

                // Live status -------------------------------------------------
                StyledRect {
                    width: parent.width
                    height: liveColumn.implicitHeight + Theme.spacingL * 2
                    radius: Theme.cornerRadiusLarge
                    color: root.connected
                        ? Theme.surfaceContainerHigh
                        : Theme.surfaceContainer
                    border.width: root.connected ? Theme.outlineWidth : 0
                    border.color: Theme.withAlpha(Theme.primary, 0.25)

                    Column {
                        id: liveColumn
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: Theme.spacingL
                        spacing: Theme.spacingXS

                        Row {
                            width: parent.width
                            spacing: Theme.spacingS

                            DIcon {
                                name: root.connected ? "headset" : "bluetooth_disabled"
                                size: Theme.iconSize
                                color: root.connected ? Theme.primary : Theme.surfaceVariantText
                                anchors.verticalCenter: parent.verticalCenter
                            }

                            StyledText {
                                width: parent.width - Theme.iconSize - Theme.spacingS
                                text: {
                                    if (!root.connected)
                                        return "Nothing connected";
                                    var suffix = root.connectedCount > 1 ? "  +" + (root.connectedCount - 1) + " more" : "";
                                    return root.primaryName + suffix;
                                }
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Theme.fontWeightMedium
                                color: Theme.surfaceText
                                elide: Text.ElideRight
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }

                        StyledText {
                            text: root.connected
                                ? BtUsage.duration(root.primaryLive)
                                : BtUsage.duration(root.todaySeconds)
                            font.pixelSize: Theme.fontSizeDisplay
                            font.weight: Theme.fontWeightBold
                            color: root.connected ? Theme.primary : Theme.surfaceText
                        }

                        StyledText {
                            width: parent.width
                            text: root.connected
                                ? "Listening " + BtUsage.duration(root.primaryPlaying) + " \u00b7 Idle " + BtUsage.duration(root.primaryIdle)
                                : "Connected today " + BtUsage.duration(root.todaySeconds) + " \u00b7 Listening " + BtUsage.duration(root.todayPlaying)
                            font.pixelSize: Theme.fontSizeSmall
                            font.weight: Theme.fontWeightMedium
                            color: root.connected ? Theme.primary : Theme.surfaceVariantText
                            wrapMode: Text.WordWrap
                        }

                        StyledText {
                            width: parent.width
                            text: {
                                if (!root.connected)
                                    return root.todaySeconds > 0 ? "This week " + BtUsage.duration(root.weekTotal) + " connected \u00b7 " + BtUsage.duration(root.weekPlayingTotal) + " listening"
                                                                : "Connect your earbuds or headset to start tracking";
                                var text = "Today " + BtUsage.duration(root.primaryToday) + " connected \u00b7 " + BtUsage.duration(root.primaryPlayingToday) + " listening";
                                if (root.primaryBattery >= 0)
                                    text += " \u00b7 Battery " + root.primaryBattery + "%";
                                return text;
                            }
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                            wrapMode: Text.WordWrap
                        }
                    }
                }

                // Last seven days ---------------------------------------------
                StyledRect {
                    width: parent.width
                    height: chartColumn.implicitHeight + Theme.spacingL * 2
                    radius: Theme.cornerRadiusLarge
                    color: Theme.surfaceContainer

                    Column {
                        id: chartColumn
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: Theme.spacingL
                        spacing: Theme.spacingM

                        Item {
                            width: parent.width
                            height: Math.max(weekTitle.implicitHeight, weekTotalLabel.implicitHeight)

                            StyledText {
                                id: weekTitle
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                text: "Last 7 days"
                                font.pixelSize: Theme.fontSizeMedium
                                font.weight: Theme.fontWeightMedium
                                color: Theme.surfaceText
                            }

                            StyledText {
                                id: weekTotalLabel
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                text: BtUsage.duration(root.weekTotal)
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                            }
                        }

                        Item {
                            width: parent.width
                            height: Theme.listItemHeight + Theme.spacingXL

                            Row {
                                anchors.fill: parent
                                spacing: Theme.spacingXS

                                Repeater {
                                    model: root.week

                                    Column {
                                        id: dayColumn

                                        width: (parent.width - Theme.spacingXS * 6) / 7
                                        height: parent.height
                                        spacing: Theme.spacingXS

                                        readonly property double connectedSeconds: modelData.seconds + (modelData.isToday ? root.weekLive : 0)
                                        readonly property double playingSeconds: Math.min(dayColumn.connectedSeconds,
                                                                                            (modelData.playingSeconds || 0) + (modelData.isToday ? root.weekLivePlaying : 0))

                                        Item {
                                            width: parent.width
                                            height: Theme.listItemHeight

                                            Rectangle {
                                                anchors.bottom: parent.bottom
                                                width: parent.width
                                                height: parent.height
                                                radius: Theme.cornerRadiusSmall
                                                color: Theme.withAlpha(Theme.primary, 0.06)
                                            }

                                            Rectangle {
                                                anchors.bottom: parent.bottom
                                                width: parent.width
                                                height: Math.max(dayColumn.connectedSeconds > 0 ? Theme.spacingXXS : 0,
                                                                 (dayColumn.connectedSeconds / root.weekMax) * parent.height)
                                                radius: Theme.cornerRadiusSmall
                                                color: Theme.withAlpha(Theme.primary, modelData.isToday ? 0.45 : 0.28)
                                            }

                                            Rectangle {
                                                anchors.bottom: parent.bottom
                                                width: parent.width
                                                height: Math.max(dayColumn.playingSeconds > 0 ? Theme.spacingXXS : 0,
                                                                 (dayColumn.playingSeconds / root.weekMax) * parent.height)
                                                radius: Theme.cornerRadiusSmall
                                                color: modelData.isToday ? Theme.primary : Theme.withAlpha(Theme.primary, 0.8)
                                            }
                                        }

                                        StyledText {
                                            width: parent.width
                                            text: modelData.label
                                            horizontalAlignment: Text.AlignHCenter
                                            font.pixelSize: Theme.fontSizeXSmall
                                            color: modelData.isToday ? Theme.primary : Theme.surfaceVariantText
                                        }
                                    }
                                }
                            }
                        }

                        Row {
                            width: parent.width
                            spacing: Theme.spacingM

                            Row {
                                spacing: Theme.spacingXS

                                Rectangle {
                                    width: Theme.spacingS
                                    height: Theme.spacingS
                                    radius: Theme.spacingXS
                                    color: Theme.withAlpha(Theme.primary, 0.45)
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                StyledText {
                                    text: "Connected " + BtUsage.duration(root.weekTotal)
                                    font.pixelSize: Theme.fontSizeXSmall
                                    color: Theme.surfaceVariantText
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            Row {
                                spacing: Theme.spacingXS

                                Rectangle {
                                    width: Theme.spacingS
                                    height: Theme.spacingS
                                    radius: Theme.spacingXS
                                    color: Theme.primary
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                StyledText {
                                    text: "Listening " + BtUsage.duration(root.weekPlayingTotal)
                                    font.pixelSize: Theme.fontSizeXSmall
                                    color: Theme.surfaceVariantText
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }
                        }
                    }
                }

                // Devices -----------------------------------------------------
                StyledText {
                    width: parent.width
                    text: "Devices"
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Theme.fontWeightMedium
                    color: Theme.surfaceText
                    topPadding: Theme.spacingXS
                }

                Repeater {
                    model: root.devices

                    StyledRect {
                        id: deviceCard

                        width: contentColumn.width
                        height: Theme.listItemHeight + Theme.spacingXL + Theme.spacingS
                        radius: Theme.cornerRadius
                        color: deviceCard.isLive ? Theme.surfaceContainerHigh : Theme.surfaceContainer
                        border.width: deviceCard.isLive ? Theme.outlineWidth : 0
                        border.color: Theme.withAlpha(Theme.primary, 0.2)

                        readonly property bool isLive: root.pluginRoot ? root.pluginRoot.isConnectedByAddress(modelData.address) : false
                        readonly property bool isPlaying: record ? record.playingStart > 0 : false
                        readonly property double now: root.pluginRoot ? root.pluginRoot.nowMs : Date.now()
                        readonly property var record: modelData.record
                        readonly property double todaySeconds: record ? BtUsage.todaySeconds(record, deviceCard.now) : 0
                        readonly property double playingToday: record ? BtUsage.playingToday(record, deviceCard.now) : 0
                        readonly property double totalSeconds: record ? BtUsage.totalSeconds(record, deviceCard.now) : 0
                        readonly property double playingTotal: record ? BtUsage.playingTotal(record, deviceCard.now) : 0
                        readonly property double sessionSeconds: record ? (record.activeStart ? BtUsage.liveSeconds(record, deviceCard.now) : (record.lastSessionSeconds || 0)) : 0
                        readonly property int battery: root.pluginRoot ? root.pluginRoot.batteryForAddress(modelData.address) : -1

                        Row {
                            id: cardRow
                            anchors.fill: parent
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingM

                            Item {
                                width: Theme.iconSize + Theme.spacingS
                                height: cardRow.height

                                DIcon {
                                    anchors.centerIn: parent
                                    name: modelData.icon || "bluetooth"
                                    size: Theme.iconSize
                                    color: deviceCard.isLive ? Theme.primary : Theme.surfaceVariantText
                                }
                            }

                            Column {
                                width: cardRow.width - (Theme.iconSize + Theme.spacingS) - statsColumn.width - cardRow.spacing * 2
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: Theme.spacingXXS

                                StyledText {
                                    width: parent.width
                                    text: modelData.name
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Theme.fontWeightMedium
                                    color: Theme.surfaceText
                                    elide: Text.ElideRight
                                }

                                StyledText {
                                    width: parent.width
                                    text: {
                                        if (deviceCard.isLive) {
                                            var state = deviceCard.isPlaying ? "Playing now" : "Connected \u00b7 idle";
                                            return state + (deviceCard.battery >= 0 ? " \u00b7 " + deviceCard.battery + "%" : "");
                                        }
                                        if (!modelData.lastDisconnected)
                                            return "No sessions yet";
                                        return "Last used " + BtUsage.relativeTime(modelData.lastDisconnected, deviceCard.now)
                                             + " \u00b7 " + BtUsage.duration(deviceCard.sessionSeconds) + " session";
                                    }
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: deviceCard.isLive ? Theme.primary : Theme.surfaceVariantText
                                    elide: Text.ElideRight
                                }

                                StyledText {
                                    width: parent.width
                                    text: "All time " + BtUsage.duration(deviceCard.totalSeconds)
                                         + " \u00b7 " + BtUsage.duration(deviceCard.playingTotal) + " listening"
                                    font.pixelSize: Theme.fontSizeXSmall
                                    color: Theme.surfaceVariantText
                                    elide: Text.ElideRight
                                }
                            }

                            Column {
                                id: statsColumn
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 0

                                StyledText {
                                    text: BtUsage.duration(deviceCard.todaySeconds)
                                    horizontalAlignment: Text.AlignRight
                                    font.pixelSize: Theme.fontSizeLarge
                                    font.weight: Theme.fontWeightBold
                                    color: deviceCard.isLive ? Theme.primary : Theme.surfaceText
                                }

                                StyledText {
                                    text: "today"
                                    horizontalAlignment: Text.AlignRight
                                    font.pixelSize: Theme.fontSizeXSmall
                                    color: Theme.surfaceVariantText
                                }

                                StyledText {
                                    text: BtUsage.duration(deviceCard.playingToday) + " listening"
                                    horizontalAlignment: Text.AlignRight
                                    font.pixelSize: Theme.fontSizeXSmall
                                    color: deviceCard.isPlaying ? Theme.primary : Theme.surfaceVariantText
                                }
                            }
                        }
                    }
                }

                StyledRect {
                    width: parent.width
                    height: emptyColumn.implicitHeight + Theme.spacingL * 2
                    radius: Theme.cornerRadiusLarge
                    color: Theme.surfaceContainer
                    visible: root.devices.length === 0

                    Column {
                        id: emptyColumn
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: Theme.spacingL
                        spacing: Theme.spacingXS

                        StyledText {
                            width: parent.width
                            text: "No devices tracked yet"
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Theme.fontWeightMedium
                            color: Theme.surfaceText
                        }

                        StyledText {
                            width: parent.width
                            text: "Connect a Bluetooth headset, speaker or earbuds. Its session time will show up here within a couple of seconds."
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                            wrapMode: Text.WordWrap
                        }
                    }
                }

                Item {
                    width: parent.width
                    height: Theme.spacingS
                }
            }
        }
    }
}
