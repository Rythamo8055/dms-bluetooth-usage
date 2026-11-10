import QtCore
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Modules.Plugins
import "./BtUsage.js" as BtUsage

// Records connect/disconnect sessions for Bluetooth audio devices.
//
// Data lives outside DMS' own settings so it can grow to a few hundred
// sessions without bloating plugin_settings.json. The widget reads the same
// file and layers the live (not yet closed) session on top.
PluginComponent {
    id: root

    readonly property var log: Log.scoped("BluetoothUsage")

    property var store: ({
        version: 1,
        createdAt: 0,
        updatedAt: 0,
        devices: {}
    })
    property bool storeLoaded: false
    property var pendingDisconnects: ({})
    property double lastHeartbeat: 0
    property double lastResetAt: 0
    property double startedAt: Date.now()
    property bool firstTick: true

    readonly property bool trackAllDevices: pluginData.trackAllDevices === true
    readonly property bool notifyOnConnect: pluginData.notifyOnConnect === true
    readonly property bool notifyOnDisconnect: pluginData.notifyOnDisconnect === true

    // A2DP/HFP profiles can drop and reconnect for a few seconds while a
    // headset switches profiles. Anything shorter than this stays one session.
    readonly property int graceSeconds: {
        var value = parseInt(pluginData.graceSeconds);
        if (isNaN(value))
            value = 45;
        return Math.max(5, Math.min(300, value));
    }

    readonly property string stateDir: StandardPaths.writableLocation(StandardPaths.GenericStateLocation) + "/dms"
    readonly property string statePath: stateDir + "/bluetooth-usage.json"

    function blankStore() {
        var now = Date.now();
        return {
            version: 1,
            createdAt: now,
            updatedAt: now,
            devices: {}
        };
    }

    function normalizeRecord(record, address) {
        if (!record || typeof record !== "object")
            record = {};

        record.address = record.address || address;
        record.name = record.name || address;
        record.icon = record.icon || "bluetooth";
        record.totalSeconds = Number(record.totalSeconds) || 0;
        record.days = record.days && typeof record.days === "object" ? record.days : {};
        record.sessions = Array.isArray(record.sessions) ? record.sessions : [];
        record.activeStart = Number(record.activeStart) || 0;
        record.lastSeen = Number(record.lastSeen) || 0;
        record.lastConnected = Number(record.lastConnected) || 0;
        record.lastDisconnected = Number(record.lastDisconnected) || 0;
        record.lastSessionSeconds = Number(record.lastSessionSeconds) || 0;
        record.battery = record.battery === undefined ? -1 : Number(record.battery);
        return record;
    }

    function ingest(text) {
        if (storeLoaded)
            return;

        var parsed = null;
        if (text && text.trim()) {
            try {
                parsed = JSON.parse(text);
            } catch (error) {
                log.warn("Could not parse usage data, starting fresh:", error);
            }
        }

        if (!parsed || typeof parsed !== "object" || !parsed.devices) {
            store = blankStore();
            storeLoaded = true;
            return;
        }

        var devices = {};
        for (var address in parsed.devices) {
            var record = normalizeRecord(parsed.devices[address], address);
            devices[String(address).toUpperCase()] = record;
        }

        store = {
            version: 1,
            createdAt: Number(parsed.createdAt) || Date.now(),
            updatedAt: Number(parsed.updatedAt) || 0,
            devices: devices
        };
        storeLoaded = true;
        log.info("Loaded usage data for", Object.keys(devices).length, "device(s)");
    }

    function deviceKey(device) {
        return String(device && device.address ? device.address : "").toUpperCase();
    }

    function displayName(device) {
        if (!device)
            return "Bluetooth device";
        return device.name || device.deviceName || "Bluetooth device";
    }

    function connectedDevices() {
        var adapter = BluetoothService.adapter;
        if (!adapter || !adapter.devices)
            return [];

        var values = adapter.devices.values || [];
        var result = [];
        for (var i = 0; i < values.length; i++) {
            var device = values[i];
            if (!device || !device.connected)
                continue;
            if (!trackAllDevices && !BluetoothService.isAudioDevice(device))
                continue;
            result.push(device);
        }
        return result;
    }

    function newRecord(device, now) {
        var key = deviceKey(device);
        return normalizeRecord({
            address: key,
            name: displayName(device),
            icon: BluetoothService.getDeviceIcon(device),
            totalSeconds: 0,
            days: {},
            sessions: [],
            activeStart: 0,
            lastSeen: 0,
            lastConnected: 0,
            lastDisconnected: 0,
            lastSessionSeconds: 0,
            battery: device && device.batteryAvailable ? Math.round(device.battery * 100) : -1
        }, key);
    }

    function addToDays(record, start, end) {
        var cursor = start;
        var guard = 0;
        while (cursor < end && guard < 40) {
            var next = BtUsage.nextDayStart(cursor);
            var chunkEnd = Math.min(end, next);
            var seconds = (chunkEnd - cursor) / 1000;
            if (seconds > 0) {
                var key = BtUsage.dateKey(cursor);
                record.days[key] = (record.days[key] || 0) + seconds;
            }
            cursor = chunkEnd;
            guard++;
        }
    }

    function prune(record) {
        // Keep three months of daily buckets and the last 60 sessions.
        var keys = Object.keys(record.days).sort();
        while (keys.length > 100)
            delete record.days[keys.shift()];

        if (record.sessions.length > 60)
            record.sessions = record.sessions.slice(record.sessions.length - 60);
    }

    function closeSession(record, endAt, now) {
        var start = record.activeStart;
        if (!start) {
            record.activeStart = 0;
            return 0;
        }

        var end = Math.max(start, Math.min(endAt || now, now));
        var seconds = Math.round((end - start) / 1000);

        if (seconds > 0) {
            addToDays(record, start, end);
            record.totalSeconds = (record.totalSeconds || 0) + seconds;
            record.lastSessionSeconds = seconds;
            record.sessions.push({
                start: start,
                end: end,
                seconds: seconds
            });
            prune(record);
        } else {
            record.lastSessionSeconds = 0;
        }

        record.activeStart = 0;
        record.lastSeen = end;
        record.lastDisconnected = end;

        if (notifyOnDisconnect && seconds > 0) {
            ToastService.showInfo(I18n.trFor("bluetoothUsage", "Bluetooth disconnected"),
                                  record.name + " \u00b7 " + BtUsage.duration(seconds));
        }

        return seconds;
    }

    function writeNow() {
        if (!storeLoaded)
            return;
        store.updatedAt = Date.now();
        usageFile.setText(JSON.stringify(store, null, 2));
        lastHeartbeat = Date.now();
    }

    function tick() {
        if (!storeLoaded)
            return;

        checkReset();

        var now = Date.now();
        var adapter = BluetoothService.adapter;
        if (!adapter) {
            firstTick = false;
            return;
        }

        var devices = connectedDevices();
        var connectedByKey = {};
        for (var i = 0; i < devices.length; i++)
            connectedByKey[deviceKey(devices[i])] = devices[i];

        var dirty = false;

        // Existing sessions: keep them alive, or close them after the grace
        // period once the device has really disconnected.
        for (var address in store.devices) {
            var record = store.devices[address];
            if (!record || !record.activeStart)
                continue;

            var liveDevice = connectedByKey[address];
            if (liveDevice) {
                record.lastSeen = now;
                record.name = displayName(liveDevice);
                record.icon = BluetoothService.getDeviceIcon(liveDevice);
                if (liveDevice.batteryAvailable)
                    record.battery = Math.round(liveDevice.battery * 100);
                if (pendingDisconnects[address]) {
                    delete pendingDisconnects[address];
                    dirty = true;
                }
            } else {
                if (!pendingDisconnects[address])
                    pendingDisconnects[address] = now;

                if (now - pendingDisconnects[address] >= graceSeconds * 1000) {
                    var endAt = record.lastSeen > 0 ? record.lastSeen : record.activeStart;
                    closeSession(record, endAt, now);
                    delete pendingDisconnects[address];
                    dirty = true;
                }
            }
        }

        // New connections.
        for (var key in connectedByKey) {
            var device = connectedByKey[key];
            var existing = store.devices[key];
            if (!existing) {
                existing = newRecord(device, now);
                store.devices[key] = existing;
                dirty = true;
            }

            if (!existing.activeStart) {
                existing.activeStart = now;
                existing.lastConnected = now;
                existing.lastSeen = now;
                existing.name = displayName(device);
                existing.icon = BluetoothService.getDeviceIcon(device);
                if (device.batteryAvailable)
                    existing.battery = Math.round(device.battery * 100);
                dirty = true;

                if (!firstTick && notifyOnConnect) {
                    ToastService.showInfo(I18n.trFor("bluetoothUsage", "Bluetooth connected"),
                                          existing.name + " \u00b7 tracking session");
                }
            }
        }

        // Heartbeat: lets a later start tell when the device was last seen,
        // even if DMS was restarted or the machine went down mid-session.
        if (now - lastHeartbeat >= 30000) {
            for (var activeAddress in store.devices) {
                if (store.devices[activeAddress].activeStart)
                    store.devices[activeAddress].lastSeen = now;
            }
            lastHeartbeat = now;
            dirty = true;
        }

        if (dirty)
            writeNow();

        firstTick = false;
    }

    function checkReset() {
        var requestedAt = Number(pluginData.resetAt || 0);
        if (requestedAt > startedAt && requestedAt > lastResetAt) {
            lastResetAt = requestedAt;
            clearAll();
        }
    }

    function clearAll() {
        var now = Date.now();
        var devices = {};
        var connected = connectedDevices();
        for (var i = 0; i < connected.length; i++) {
            var record = newRecord(connected[i], now);
            record.activeStart = now;
            record.lastConnected = now;
            record.lastSeen = now;
            devices[deviceKey(connected[i])] = record;
        }

        store = {
            version: 1,
            createdAt: now,
            updatedAt: now,
            devices: devices
        };
        pendingDisconnects = {};
        lastHeartbeat = now;
        writeNow();
        ToastService.showInfo(I18n.trFor("bluetoothUsage", "Bluetooth usage cleared"));
    }

    function statusJson() {
        var now = Date.now();
        var result = {
            updatedAt: store.updatedAt,
            createdAt: store.createdAt,
            todaySeconds: 0,
            devices: []
        };

        for (var address in store.devices) {
            var record = store.devices[address];
            var today = BtUsage.todaySeconds(record, now);
            result.todaySeconds += today;
            result.devices.push({
                address: address,
                name: record.name,
                connected: !!record.activeStart,
                sessionSeconds: Math.round(BtUsage.liveSeconds(record, now)),
                todaySeconds: Math.round(today),
                totalSeconds: Math.round(BtUsage.totalSeconds(record, now)),
                lastConnected: record.lastConnected,
                lastDisconnected: record.lastDisconnected
            });
        }

        result.devices.sort(function (a, b) {
            if (a.connected !== b.connected)
                return a.connected ? -1 : 1;
            return b.lastConnected - a.lastConnected;
        });
        return JSON.stringify(result);
    }

    Timer {
        id: tickTimer
        interval: 2000
        repeat: true
        running: root.storeLoaded
        triggeredOnStart: true
        onTriggered: root.tick()
    }

    FileView {
        id: usageFile
        path: root.statePath
        blockLoading: true
        blockWrites: true
        atomicWrites: true
        watchChanges: false
        printErrors: false
        onLoaded: root.ingest(usageFile.text())
        onLoadFailed: error => {
            if (!root.storeLoaded) {
                root.store = root.blankStore();
                root.storeLoaded = true;
            }
        }
    }

    IpcHandler {
        target: "btUsage"

        function status(): string {
            return root.statusJson();
        }

        function today(): string {
            var status = JSON.parse(root.statusJson());
            return String(Math.round(status.todaySeconds));
        }

        function clear(): string {
            root.clearAll();
            return "cleared";
        }
    }

    Component.onCompleted: {
        if (!storeLoaded) {
            var text = usageFile.text();
            if (text && text.trim()) {
                ingest(text);
            } else {
                store = blankStore();
                storeLoaded = true;
            }
        }
        lastResetAt = Number(pluginData.resetAt || 0);
        log.info("Tracking started", trackAllDevices ? "(all Bluetooth devices)" : "(audio devices only)");
    }

    onPluginDataChanged: checkReset()

    Component.onDestruction: {
        // Leave the session open so a DMS restart does not split it. The
        // heartbeat timestamp is enough to close it correctly later.
        if (!storeLoaded)
            return;
        var now = Date.now();
        for (var address in store.devices) {
            if (store.devices[address].activeStart)
                store.devices[address].lastSeen = now;
        }
        writeNow();
    }
}
