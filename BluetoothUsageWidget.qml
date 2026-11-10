import QtCore
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.DCommon.Widgets
import qs.Modules.Plugins
import "./BtUsage.js" as BtUsage

PluginComponent {
    id: root

    readonly property var log: Log.scoped("BluetoothUsageWidget")

    property var usage: ({
        version: 1,
        createdAt: 0,
        updatedAt: 0,
        devices: {}
    })
    property bool usageLoaded: false
    property double nowMs: Date.now()

    readonly property bool trackAllDevices: pluginData.trackAllDevices === true
    readonly property bool hideWhenIdle: pluginData.hideWhenIdle === true
    readonly property bool showBattery: pluginData.showBattery !== false
    readonly property bool showListeningInBar: pluginData.showListeningInBar !== false
    readonly property string statePath: StandardPaths.writableLocation(StandardPaths.GenericStateLocation) + "/dms/bluetooth-usage.json"

    readonly property bool anyBluetoothConnected: BluetoothService.connected

    readonly property var connectedDevices: {
        var tick = root.nowMs;
        var any = root.anyBluetoothConnected;
        var adapter = BluetoothService.adapter;
        if (!adapter || !adapter.devices)
            return [];

        var values = adapter.devices.values || [];
        var result = [];
        for (var i = 0; i < values.length; i++) {
            var device = values[i];
            if (!device || !device.connected)
                continue;
            if (!root.trackAllDevices && !BluetoothService.isAudioDevice(device))
                continue;
            result.push(device);
        }
        return result;
    }

    readonly property bool hasConnected: connectedDevices.length > 0

    readonly property var primaryDevice: {
        var tick = root.nowMs;
        var devices = root.connectedDevices;
        if (devices.length === 0)
            return null;

        var best = devices[0];
        var bestStart = Number.MAX_VALUE;
        for (var i = 0; i < devices.length; i++) {
            var record = root.recordFor(devices[i]);
            var start = record && record.activeStart ? record.activeStart : root.nowMs;
            if (start < bestStart) {
                bestStart = start;
                best = devices[i];
            }
        }
        return best;
    }

    readonly property var primaryRecord: {
        var tick = root.nowMs;
        var used = root.usage;
        return root.primaryDevice ? root.recordFor(root.primaryDevice) : null;
    }

    readonly property double primaryLiveSeconds: {
        var tick = root.nowMs;
        return root.primaryRecord ? BtUsage.liveSeconds(root.primaryRecord, root.nowMs) : 0;
    }

    readonly property double primaryTodaySeconds: {
        var tick = root.nowMs;
        return root.primaryRecord ? BtUsage.todaySeconds(root.primaryRecord, root.nowMs) : 0;
    }

    readonly property double primaryTotalSeconds: {
        var tick = root.nowMs;
        return root.primaryRecord ? BtUsage.totalSeconds(root.primaryRecord, root.nowMs) : 0;
    }

    readonly property double primaryPlayingSeconds: {
        var tick = root.nowMs;
        return root.primaryRecord ? BtUsage.livePlaying(root.primaryRecord, root.nowMs) : 0;
    }

    readonly property double primaryIdleSeconds: {
        var tick = root.nowMs;
        return Math.max(0, root.primaryLiveSeconds - root.primaryPlayingSeconds);
    }

    readonly property double primaryPlayingToday: {
        var tick = root.nowMs;
        return root.primaryRecord ? BtUsage.playingToday(root.primaryRecord, root.nowMs) : 0;
    }

    readonly property double primaryIdleToday: {
        var tick = root.nowMs;
        return root.primaryRecord ? BtUsage.idleToday(root.primaryRecord, root.nowMs) : 0;
    }

    readonly property int primaryBattery: {
        var tick = root.nowMs;
        var device = root.primaryDevice;
        if (device && device.batteryAvailable)
            return Math.round(device.battery * 100);
        if (root.primaryRecord && root.primaryRecord.battery !== undefined && root.primaryRecord.battery >= 0)
            return root.primaryRecord.battery;
        return -1;
    }

    readonly property double todayTotal: {
        var tick = root.nowMs;
        var total = 0;
        for (var key in root.usage.devices)
            total += BtUsage.todaySeconds(root.usage.devices[key], root.nowMs);
        return total;
    }

    readonly property double liveTodayTotal: {
        var tick = root.nowMs;
        var total = 0;
        for (var key in root.usage.devices)
            total += BtUsage.liveToday(root.usage.devices[key], root.nowMs);
        return total;
    }

    readonly property double todayPlayingTotal: {
        var tick = root.nowMs;
        var total = 0;
        for (var key in root.usage.devices)
            total += BtUsage.playingToday(root.usage.devices[key], root.nowMs);
        return total;
    }

    readonly property double livePlayingTodayTotal: {
        var tick = root.nowMs;
        var total = 0;
        for (var key in root.usage.devices)
            total += BtUsage.livePlayingToday(root.usage.devices[key], root.nowMs);
        return total;
    }

    // The chart model must stay stable while the live clock ticks, otherwise
    // the Repeater would rebuild every second. It refreshes when the daemon
    // writes (every 30 s) or when the local date rolls over.
    property string todayKey: BtUsage.dateKey(Date.now())
    readonly property var weekData: {
        var day = root.todayKey;
        return BtUsage.weekDaysStored(root.usage.devices, Date.now());
    }

    readonly property var deviceList: {
        var used = root.usage;
        var list = [];
        for (var key in used.devices) {
            var record = used.devices[key];
            if (!record)
                continue;
            list.push({
                address: key,
                name: record.name || key,
                icon: record.icon || "bluetooth",
                record: record,
                lastConnected: record.lastConnected || 0,
                lastDisconnected: record.lastDisconnected || 0
            });
        }

        list.sort(function (a, b) {
            var aActive = a.record.activeStart > 0;
            var bActive = b.record.activeStart > 0;
            if (aActive !== bActive)
                return aActive ? -1 : 1;
            if (b.lastConnected !== a.lastConnected)
                return b.lastConnected - a.lastConnected;
            return a.name.localeCompare(b.name);
        });
        return list;
    }

    readonly property bool showBarPill: hasConnected || !hideWhenIdle
    readonly property string barText: {
        var tick = root.nowMs;
        var used = root.usage;
        if (root.primaryDevice)
            return root.primaryRecord ? BtUsage.duration(root.primaryLiveSeconds, true) : "--";
        if (!root.usageLoaded)
            return "";
        return BtUsage.duration(root.todayTotal, true);
    }
    readonly property string barBattery: {
        var tick = root.nowMs;
        if (!root.hasConnected || !root.showBattery)
            return "";
        return root.primaryBattery >= 0 ? root.primaryBattery + "%" : "";
    }
    readonly property string barListeningText: {
        var tick = root.nowMs;
        if (!root.showListeningInBar)
            return "";
        if (root.hasConnected) {
            if (root.primaryPlayingSeconds >= 1)
                return BtUsage.duration(root.primaryPlayingSeconds, true);
            return "idle";
        }
        return root.usageLoaded && root.todayPlayingTotal >= 1 ? BtUsage.duration(root.todayPlayingTotal, true) : "";
    }
    readonly property color barListeningColor: root.hasConnected && root.primaryPlayingSeconds >= 1
        ? Theme.primary
        : Theme.surfaceVariantText
    readonly property color barAccent: root.hasConnected ? Theme.primary : Theme.surfaceVariantText
    readonly property string barIcon: {
        if (root.primaryDevice)
            return BluetoothService.getDeviceIcon(root.primaryDevice);
        return "bluetooth";
    }

    function keyFor(device) {
        return String(device && device.address ? device.address : "").toUpperCase();
    }

    function recordFor(device) {
        var key = keyFor(device);
        if (!key || !root.usage || !root.usage.devices)
            return null;
        return root.usage.devices[key] || null;
    }

    function isConnectedByAddress(address) {
        var tick = root.nowMs;
        var devices = root.connectedDevices;
        for (var i = 0; i < devices.length; i++) {
            if (keyFor(devices[i]) === address)
                return true;
        }
        return false;
    }

    function batteryForAddress(address) {
        var tick = root.nowMs;
        var devices = root.connectedDevices;
        for (var i = 0; i < devices.length; i++) {
            if (keyFor(devices[i]) !== address)
                continue;
            if (devices[i].batteryAvailable)
                return Math.round(devices[i].battery * 100);
            break;
        }
        var record = root.usage.devices[address];
        return record && record.battery !== undefined ? record.battery : -1;
    }

    function applyUsage(text) {
        if (!text || !text.trim())
            return;
        try {
            var parsed = JSON.parse(text);
            if (parsed && typeof parsed === "object" && parsed.devices) {
                usage = parsed;
                usageLoaded = true;
            }
        } catch (error) {
            log.warn("Could not parse usage data:", error);
        }
    }

    Timer {
        interval: 1000
        repeat: true
        running: root.hasConnected
        triggeredOnStart: true
        onTriggered: root.nowMs = Date.now()
    }

    Timer {
        interval: 60000
        repeat: true
        running: true
        onTriggered: root.todayKey = BtUsage.dateKey(Date.now())
    }

    FileView {
        id: usageFile
        path: root.statePath
        blockLoading: true
        watchChanges: true
        printErrors: false
        onLoaded: root.applyUsage(usageFile.text())
        onFileChanged: usageFile.reload()
        onLoadFailed: error => {}
    }

    horizontalBarPill: Component {
        Item {
            id: horizontalPill

            visible: root.showBarPill
            implicitWidth: visible ? horizontalRow.implicitWidth + Theme.spacingS * 2 : 0
            implicitHeight: Math.max(Theme.iconSize, horizontalRow.implicitHeight)

            Row {
                id: horizontalRow
                anchors.centerIn: parent
                spacing: Theme.spacingXS

                DIcon {
                    name: root.barIcon
                    size: Theme.iconSize - Theme.spacingXS
                    color: root.barAccent
                    anchors.verticalCenter: parent.verticalCenter
                }

                StyledText {
                    text: root.barText
                    visible: text.length > 0
                    font.pixelSize: Theme.fontSizeSmall
                    font.weight: root.hasConnected ? Theme.fontWeightMedium : Font.Normal
                    color: root.hasConnected ? Theme.surfaceText : Theme.surfaceVariantText
                    anchors.verticalCenter: parent.verticalCenter
                }

                StyledText {
                    text: root.barListeningText.length > 0 ? "\u00b7 " + root.barListeningText : ""
                    visible: text.length > 0
                    font.pixelSize: Theme.fontSizeSmall
                    color: root.barListeningColor
                    anchors.verticalCenter: parent.verticalCenter
                }

                StyledText {
                    text: root.barBattery
                    visible: text.length > 0
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                    anchors.verticalCenter: parent.verticalCenter
                }
            }
        }
    }

    verticalBarPill: Component {
        Item {
            id: verticalPill

            visible: root.showBarPill
            implicitWidth: Math.max(Theme.iconSize, verticalColumn.implicitWidth)
            implicitHeight: visible ? verticalColumn.implicitHeight : 0

            Column {
                id: verticalColumn
                anchors.centerIn: parent
                spacing: Theme.spacingXXS

                DIcon {
                    name: root.barIcon
                    size: Theme.iconSize - Theme.spacingXS
                    color: root.barAccent
                    anchors.horizontalCenter: parent.horizontalCenter
                }

                StyledText {
                    text: root.barText
                    visible: text.length > 0
                    font.pixelSize: Theme.fontSizeXSmall
                    color: root.hasConnected ? Theme.surfaceText : Theme.surfaceVariantText
                    anchors.horizontalCenter: parent.horizontalCenter
                }
            }
        }
    }

    popoutContent: Component {
        BluetoothUsagePopout {
            pluginRoot: root
        }
    }

    popoutWidth: 400
    popoutHeight: 620
}
