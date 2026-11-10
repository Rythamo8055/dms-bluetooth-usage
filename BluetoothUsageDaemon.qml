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
        lastWeeklySummary: 0,
        devices: {}
    })
    property bool storeLoaded: false
    property var pendingDisconnects: ({})
    property var playingAddresses: ({})
    property bool audioProbeAvailable: false
    property bool audioProbeInFlight: false
    property double audioProbeStartedAt: 0
    property bool audioSubscribeFailed: false
    property bool trackedConnected: false
    property bool needsTick: false
    property bool probeErrorLogged: false
    property string summaryBody: ""
    property double lastHeartbeat: 0
    property double lastResetAt: 0
    property double startedAt: Date.now()
    property bool firstTick: true

    readonly property bool trackAllDevices: pluginData.trackAllDevices === true
    readonly property bool notifyOnConnect: pluginData.notifyOnConnect === true
    readonly property bool notifyOnDisconnect: pluginData.notifyOnDisconnect === true
    readonly property bool weeklySummaryEnabled: pluginData.weeklySummary !== false
    readonly property int summaryDay: {
        var value = parseInt(pluginData.summaryDay);
        return isNaN(value) ? 1 : Math.max(0, Math.min(6, value));
    }
    readonly property int summaryHour: {
        var value = parseInt(pluginData.summaryHour);
        return isNaN(value) ? 9 : Math.max(0, Math.min(23, value));
    }

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
            lastWeeklySummary: now,
            devices: {}
        };
    }

    function normalizeRecord(record, address) {
        if (!record || typeof record !== "object")
            record = {};

        record.address = address || record.address;
        record.name = record.name || address;
        record.icon = record.icon || "bluetooth";
        record.totalSeconds = Number(record.totalSeconds) || 0;
        record.playingSeconds = Number(record.playingSeconds) || 0;
        record.days = record.days && typeof record.days === "object" ? record.days : {};
        record.playingDays = record.playingDays && typeof record.playingDays === "object" ? record.playingDays : {};
        record.sessions = Array.isArray(record.sessions) ? record.sessions : [];
        record.activeStart = Number(record.activeStart) || 0;
        record.playingStart = Number(record.playingStart) || 0;
        record.lastSeen = Number(record.lastSeen) || 0;
        record.lastPlayingSeen = Number(record.lastPlayingSeen) || 0;
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
            writeNow();
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
            lastWeeklySummary: Number(parsed.lastWeeklySummary) || Date.now(),
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
            playingSeconds: 0,
            days: {},
            playingDays: {},
            sessions: [],
            activeStart: 0,
            playingStart: 0,
            lastSeen: 0,
            lastPlayingSeen: 0,
            lastConnected: 0,
            lastDisconnected: 0,
            lastSessionSeconds: 0,
            battery: device && device.batteryAvailable ? Math.round(device.battery * 100) : -1
        }, key);
    }

    function addToBuckets(buckets, start, end) {
        var cursor = start;
        var guard = 0;
        while (cursor < end && guard < 40) {
            var next = BtUsage.nextDayStart(cursor);
            var chunkEnd = Math.min(end, next);
            var seconds = (chunkEnd - cursor) / 1000;
            if (seconds > 0) {
                var key = BtUsage.dateKey(cursor);
                buckets[key] = (buckets[key] || 0) + seconds;
            }
            cursor = chunkEnd;
            guard++;
        }
    }

    function addToDays(record, start, end) {
        addToBuckets(record.days, start, end);
    }

    function addToPlayingDays(record, start, end) {
        if (!record.playingDays)
            record.playingDays = {};
        addToBuckets(record.playingDays, start, end);
    }

    function prune(record) {
        // Keep three months of daily buckets and the last 60 sessions.
        var keys = Object.keys(record.days).sort();
        while (keys.length > 100)
            delete record.days[keys.shift()];

        var playingKeys = Object.keys(record.playingDays).sort();
        while (playingKeys.length > 100)
            delete record.playingDays[playingKeys.shift()];

        if (record.sessions.length > 60)
            record.sessions = record.sessions.slice(record.sessions.length - 60);
    }

    function closePlaying(record, endAt, now) {
        var start = record.playingStart;
        if (!start) {
            record.playingStart = 0;
            return 0;
        }

        var end = Math.max(start, Math.min(endAt || now, now));
        var seconds = Math.round((end - start) / 1000);
        if (seconds > 0) {
            addToPlayingDays(record, start, end);
            record.playingSeconds = (record.playingSeconds || 0) + seconds;
        }

        record.playingStart = 0;
        record.lastPlayingSeen = end;
        return seconds;
    }

    function closeSession(record, endAt, now, silent) {
        var start = record.activeStart;
        if (!start) {
            record.activeStart = 0;
            return 0;
        }

        var end = Math.max(start, Math.min(endAt || now, now));

        // Playback cannot survive a disconnect; stop the listening interval
        // before closing the connected session.
        if (record.playingStart)
            closePlaying(record, record.lastPlayingSeen || end, now);

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

        if (notifyOnDisconnect && seconds > 0 && !silent) {
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

    // A session that was left open across a shutdown must not count the
    // downtime as connected time. Close it at its last heartbeat and let the
    // normal connection pass open a fresh session if the device is still here.
    function reconcileStaleSessions(now) {
        var dirty = false;
        var threshold = now - graceSeconds * 1000;
        for (var address in store.devices) {
            var record = store.devices[address];
            if (!record || !record.activeStart)
                continue;
            if (pendingDisconnects[address])
                continue;
            var lastSeen = record.lastSeen > 0 ? record.lastSeen : record.activeStart;
            if (lastSeen > 0 && lastSeen < threshold) {
                closeSession(record, lastSeen, now, true);
                dirty = true;
            }
        }
        return dirty;
    }

    function refreshSinks() {
        if (!storeLoaded || !trackedConnected)
            return;
        if (audioProbe.running || audioProbeInFlight)
            return;
        audioProbeInFlight = true;
        audioProbeStartedAt = Date.now();
        audioProbe.running = true;
    }

    function updateNeedsTick() {
        var needed = false;
        for (var address in store.devices) {
            if (store.devices[address].activeStart) {
                needed = true;
                break;
            }
        }
        if (!needed && Object.keys(pendingDisconnects).length > 0)
            needed = true;
        needsTick = needed;
    }

    function tick() {
        if (!storeLoaded)
            return;

        checkReset();

        var now = Date.now();
        var dirty = reconcileStaleSessions(now);
        var adapter = BluetoothService.adapter;
        if (!adapter) {
            if (dirty)
                writeNow();
            updateNeedsTick();
            firstTick = false;
            return;
        }

        var devices = connectedDevices();
        var connectedByKey = {};
        for (var i = 0; i < devices.length; i++)
            connectedByKey[deviceKey(devices[i])] = devices[i];

        var wasTrackedConnected = trackedConnected;
        trackedConnected = Object.keys(connectedByKey).length > 0;
        if (trackedConnected && !wasTrackedConnected)
            refreshSinks();
        else if (!trackedConnected)
            playingAddresses = ({});

        // Existing sessions: keep them alive, or close them after the grace
        // period once the device has really disconnected.
        for (var address in store.devices) {
            var record = store.devices[address];
            if (!record || !record.activeStart)
                continue;

            var liveDevice = connectedByKey[address];
            var isPlaying = audioProbeAvailable && playingAddresses[address] === true;
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

                if (audioProbeAvailable) {
                    if (isPlaying) {
                        if (!record.playingStart) {
                            record.playingStart = now;
                            dirty = true;
                        }
                        record.lastPlayingSeen = now;
                    } else if (record.playingStart) {
                        closePlaying(record, record.lastPlayingSeen || now, now);
                        dirty = true;
                    }
                }
            } else {
                if (record.playingStart) {
                    closePlaying(record, record.lastPlayingSeen || record.lastSeen || now, now);
                    dirty = true;
                }

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

                if (audioProbeAvailable && playingAddresses[key] === true) {
                    existing.playingStart = now;
                    existing.lastPlayingSeen = now;
                }

                if (!firstTick && notifyOnConnect) {
                    ToastService.showInfo(I18n.trFor("bluetoothUsage", "Bluetooth connected"),
                                          existing.name + " \u00b7 tracking session");
                }
            }
        }

        // Heartbeat: lets a later start tell when the device was last seen,
        // even if DMS was restarted or the machine went down mid-session.
        if (now - lastHeartbeat >= 30000) {
            var hasActiveSession = false;
            for (var activeAddress in store.devices) {
                if (store.devices[activeAddress].activeStart) {
                    store.devices[activeAddress].lastSeen = now;
                    hasActiveSession = true;
                }
                if (store.devices[activeAddress].playingStart)
                    store.devices[activeAddress].lastPlayingSeen = now;
            }
            if (hasActiveSession) {
                lastHeartbeat = now;
                dirty = true;
            }
        }

        if (dirty)
            writeNow();

        updateNeedsTick();
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
            lastWeeklySummary: now,
            devices: devices
        };
        pendingDisconnects = {};
        lastHeartbeat = now;
        writeNow();
        needsTick = Object.keys(devices).length > 0;
        ToastService.showInfo(I18n.trFor("bluetoothUsage", "Bluetooth usage cleared"));
    }

    function statusJson() {
        var now = Date.now();
        var result = {
            updatedAt: store.updatedAt,
            createdAt: store.createdAt,
            audioProbeAvailable: root.audioProbeAvailable,
            todaySeconds: 0,
            todayPlayingSeconds: 0,
            devices: []
        };

        for (var address in store.devices) {
            var record = store.devices[address];
            var today = BtUsage.todaySeconds(record, now);
            var playingToday = BtUsage.playingToday(record, now);
            result.todaySeconds += today;
            result.todayPlayingSeconds += playingToday;
            result.devices.push({
                address: address,
                name: record.name,
                connected: !!record.activeStart,
                sessionSeconds: Math.round(BtUsage.liveSeconds(record, now)),
                playingSessionSeconds: Math.round(BtUsage.livePlaying(record, now)),
                todaySeconds: Math.round(today),
                playingTodaySeconds: Math.round(playingToday),
                idleTodaySeconds: Math.round(BtUsage.idleToday(record, now)),
                totalSeconds: Math.round(BtUsage.totalSeconds(record, now)),
                playingTotalSeconds: Math.round(BtUsage.playingTotal(record, now)),
                idleTotalSeconds: Math.round(BtUsage.idleTotal(record, now)),
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

    function handleSinks(text) {
        var data = null;
        try {
            data = JSON.parse(text);
        } catch (error) {
            return;
        }
        if (!data || !Array.isArray(data.sinks) || !Array.isArray(data.sink_inputs))
            return;

        var addressBySink = {};
        for (var i = 0; i < data.sinks.length; i++) {
            var sink = data.sinks[i];
            if (!sink)
                continue;
            var properties = sink.properties || {};
            var sinkName = String(sink.name || "");
            var bus = properties["device.bus"] || "";
            if (bus !== "bluetooth" && sinkName.indexOf("bluez") !== 0)
                continue;

            var address = String(properties["api.bluez5.address"] || properties["device.string"] || "").toUpperCase();
            if (!address) {
                var match = sinkName.match(/bluez_output\.([0-9a-fA-F_]+)/);
                if (match)
                    address = match[1].replace(/_/g, ":").toUpperCase();
            }
            if (address)
                addressBySink[sink.index] = address;
        }

        var playing = {};
        for (var j = 0; j < data.sink_inputs.length; j++) {
            var input = data.sink_inputs[j];
            if (!input || input.corked === true || input.mute === true)
                continue;
            var playingAddress = addressBySink[input.sink];
            if (playingAddress)
                playing[playingAddress] = true;
        }

        playingAddresses = playing;
        audioProbeAvailable = true;
        probeErrorLogged = false;
    }

    // ------------------------------------------------------------------
    // Weekly summary
    // ------------------------------------------------------------------

    function lastScheduledAt(now) {
        var day = summaryDay;
        var hour = summaryHour;
        var date = new Date(now);
        date.setHours(hour, 0, 0, 0);
        var diff = (date.getDay() - day + 7) % 7;
        date.setDate(date.getDate() - diff);
        if (date.getTime() > now)
            date.setDate(date.getDate() - 7);
        return date.getTime();
    }

    function weekSummary(now) {
        var connected = 0;
        var playing = 0;
        var topName = "";
        var topSeconds = 0;
        var todayStart = BtUsage.dayStart(now);

        for (var address in store.devices) {
            var record = store.devices[address];
            if (!record)
                continue;

            var deviceConnected = 0;
            var devicePlaying = 0;
            for (var offset = 0; offset < 7; offset++) {
                var day = new Date(todayStart);
                day.setDate(day.getDate() - offset);
                var key = BtUsage.dateKey(day.getTime());
                deviceConnected += record.days ? (record.days[key] || 0) : 0;
                devicePlaying += record.playingDays ? (record.playingDays[key] || 0) : 0;
            }
            deviceConnected += BtUsage.liveToday(record, now);
            devicePlaying += BtUsage.livePlayingToday(record, now);

            connected += deviceConnected;
            playing += devicePlaying;
            if (deviceConnected > topSeconds) {
                topSeconds = deviceConnected;
                topName = record.name;
            }
        }

        return {
            connected: connected,
            playing: playing,
            idle: Math.max(0, connected - playing),
            topName: topName,
            topSeconds: topSeconds
        };
    }

    function summaryText(now) {
        var summary = weekSummary(now);
        if (summary.connected < 60)
            return "No Bluetooth usage recorded in the last 7 days.";

        var lines = [
            "Last 7 days",
            "Connected: " + BtUsage.duration(summary.connected),
            "Listening: " + BtUsage.duration(summary.playing),
            "Idle: " + BtUsage.duration(summary.idle)
        ];
        if (summary.topName)
            lines.push("Top device: " + summary.topName + " (" + BtUsage.duration(summary.topSeconds) + ")");
        return lines.join("\n");
    }

    function sendSummary(body) {
        if (!body || summaryProcess.running)
            return false;
        summaryBody = body;
        summaryProcess.running = true;
        return true;
    }

    function checkWeeklySummary() {
        if (!storeLoaded || !weeklySummaryEnabled || summaryProcess.running)
            return;

        var now = Date.now();
        var scheduled = lastScheduledAt(now);
        var last = Number(store.lastWeeklySummary) || 0;
        if (scheduled <= last)
            return;

        var summary = weekSummary(now);
        store.lastWeeklySummary = now;
        writeNow();

        if (summary.connected >= 60)
            sendSummary(summaryText(now));
    }

    Timer {
        id: tickTimer
        interval: 2000
        repeat: true
        running: root.storeLoaded && root.needsTick
        onTriggered: root.tick()
    }

    // Kick the first evaluation once the store is loaded; after that,
    // BluetoothService signals drive connect/disconnect and the tick timer
    // only runs while a session or a disconnect grace period is alive.
    Timer {
        id: startupTickTimer
        interval: 700
        repeat: false
        running: root.storeLoaded
        onTriggered: root.tick()
    }

    Connections {
        target: BluetoothService
        function onConnectedChanged() { root.tick(); }
        function onHasConnectedAudioDeviceChanged() { root.tick(); }
        function onAdapterChanged() { root.tick(); }
    }

    // One `pactl -f json list` call covers both sinks and sink-inputs. A
    // Bluetooth sink is "listening" only when an uncorked, unmuted stream is
    // routed to it. The probe runs on connect and on pactl events, not on a
    // permanent poll; `pactl subscribe` is only alive while a device is here.
    Timer {
        id: audioRefreshTimer
        interval: 350
        repeat: false
        onTriggered: root.refreshSinks()
    }

    Timer {
        id: audioFallbackTimer
        interval: 5000
        repeat: true
        running: root.storeLoaded && root.trackedConnected && root.audioSubscribeFailed
        onTriggered: root.refreshSinks()
    }

    Timer {
        id: audioWatchdogTimer
        interval: 5000
        repeat: true
        running: root.trackedConnected
        onTriggered: {
            if (root.audioProbeInFlight && root.audioProbeStartedAt > 0
                    && Date.now() - root.audioProbeStartedAt > 12000) {
                root.audioProbeInFlight = false;
                audioProbe.running = false;
                root.refreshSinks();
            }
        }
    }

    Process {
        id: audioEvents
        command: ["pactl", "subscribe"]
        running: root.storeLoaded && root.trackedConnected
        stdout: SplitParser {
            splitMarker: "\n"
            onRead: line => {
                // Ignore client events caused by our own probe/subscribe
                // clients; only stream/sink changes matter for listening state.
                if (line.indexOf("sink-input") !== -1 || line.indexOf("on sink") !== -1)
                    audioRefreshTimer.restart();
            }
        }
        stderr: StdioCollector {}
        onStarted: root.audioSubscribeFailed = false
        onExited: (exitCode, exitStatus) => {
            if (root.trackedConnected)
                root.audioSubscribeFailed = true;
        }
    }

    Process {
        id: audioProbe
        command: ["pactl", "-f", "json", "list"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: root.handleSinks(text)
        }
        stderr: StdioCollector {}
        onExited: (exitCode, exitStatus) => {
            root.audioProbeInFlight = false;
            if (exitCode !== 0 && !root.probeErrorLogged) {
                root.probeErrorLogged = true;
                root.log.warn("pactl is unavailable; listening time will not be recorded");
            }
        }
    }

    Timer {
        id: weeklyStartupTimer
        interval: 2500
        repeat: false
        running: root.storeLoaded
        onTriggered: root.checkWeeklySummary()
    }

    Timer {
        id: weeklyTimer
        interval: 60000
        repeat: true
        running: root.storeLoaded
        onTriggered: root.checkWeeklySummary()
    }

    Process {
        id: summaryProcess
        command: ["dms", "notify", "-a", "Bluetooth Usage", "-i", "audio-headset",
                  "Bluetooth weekly summary", root.summaryBody]
        running: false
        stderr: StdioCollector {}
        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0) {
                ToastService.showInfo(I18n.trFor("bluetoothUsage", "Bluetooth weekly summary"),
                                      root.summaryBody);
            }
        }
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
                root.writeNow();
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

        function summary(): string {
            var body = root.summaryText(Date.now());
            if (root.sendSummary(body)) {
                root.store.lastWeeklySummary = Date.now();
                root.writeNow();
            }
            return body;
        }

        function preview(): string {
            return root.summaryText(Date.now());
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
                writeNow();
            }
        }
        lastResetAt = Number(pluginData.resetAt || 0);
        log.info("Tracking started", trackAllDevices ? "(all Bluetooth devices)" : "(audio devices only)");
    }

    onPluginDataChanged: {
        checkReset();
        checkWeeklySummary();
        if (storeLoaded)
            tick();
    }

    Component.onDestruction: {
        // Leave the session open so a DMS restart does not split it. The
        // heartbeat timestamp is enough to close it correctly later.
        if (!storeLoaded)
            return;
        var now = Date.now();
        for (var address in store.devices) {
            if (store.devices[address].activeStart)
                store.devices[address].lastSeen = now;
            if (store.devices[address].playingStart)
                store.devices[address].lastPlayingSeen = now;
        }
        writeNow();
    }
}
