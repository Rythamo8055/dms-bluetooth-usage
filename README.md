# Bluetooth Usage for DankMaterialShell

A DMS plugin that tracks how long your Bluetooth audio devices stay connected.
Built for TWS earbuds, but works with any headset or speaker.

![Bluetooth Usage popout](screenshot.png)

## Features

- **Live session time** in the DankBar: icon + current connection duration.
- **Actual listening time** tracked separately from connected time. A device can
  be connected for 2 hours but only actually playing audio for 20 minutes.
- **Popout details**: today and all-time for both connected and listening time,
  idle time, last session, battery, and per-device history.
- **Dual 7-day chart**: total connected time with the listening portion filled in.
- **Weekly summary notification**: connected, listening and idle time for the
  last 7 days plus your top device. Configurable day and time.
- **Survives restarts**: sessions are stored in
  `~/.local/state/dms/bluetooth-usage.json`, not in memory.
- **Reconnect grace period**: short A2DP/HFP dropouts are merged into one session.
- **Optional toasts** on connect/disconnect and optional battery readout.
- **IPC**: `dms ipc call btUsage status`, `today`, `preview`, `summary`, `clear`.

## How it works

DMS already exposes BlueZ through `BluetoothService`. The plugin adds two surfaces:

- `BluetoothUsageDaemon.qml` polls the adapter every 2 seconds, diffs the set of
  connected devices, and closes/opens sessions. A heartbeat lets it recover the
  correct end time after a DMS restart or a power loss.
- Listening time is sampled from `pactl -f json list`: a Bluetooth sink counts as
  playing only while an uncorked, unmuted stream is routed to it. This means
  paused media is not counted as listening.
- `BluetoothUsageWidget.qml` reads the same JSON file and adds the currently
  running session on top for live display.

Requirements: `bluez` (used by DMS), `pactl` (PipeWire/PulseAudio) and
`notify-send` (for the weekly summary). All are normally present on Fedora.

## Install (local)

```bash
git clone <this-repo> ~/dms-bluetooth-usage
ln -s ~/dms-bluetooth-usage ~/.config/dms/plugins/bluetoothUsage
dms ipc call plugin-scan scan
```

Then enable **Bluetooth Usage** in DMS Settings → Plugins and add the widget to
your bar from Settings → Bar → Widgets.

If the plugin does not appear after copying files, restart the shell:

```bash
systemctl --user restart dms
```

## Settings

- Track all Bluetooth devices (not just headsets/speakers)
- Show battery in the bar
- Show listening time in the bar
- Hide the bar widget while disconnected
- Notifications on connect/disconnect
- Reconnect grace period
- Weekly summary: on/off, day, and time
- Send a weekly summary immediately (for testing)
- Clear all statistics

## Notes and limitations

- BlueZ does not keep a connection history, so tracking starts when the plugin
  is first enabled. Previous listening time cannot be reconstructed.
- "Connected" means the Bluetooth link is up. "Listening" means an uncorked,
  unmuted audio stream is routed to that device's Bluetooth sink. A stream that
  is running but outputting silence still counts as listening.
- Sessions shorter than the poll interval (2 s) are not recorded.
- Multi-point connections: each connected device gets its own session.
- Battery is whatever BlueZ exposes; many TWS buds report only one side.
- The weekly summary is delivered through the DMS notification daemon, so it
  also appears in the notification history.

## IPC

```bash
dms ipc call btUsage status   # JSON: active sessions, today, totals per device
dms ipc call btUsage today    # today's connected total in seconds
dms ipc call btUsage preview  # print this week's summary text
dms ipc call btUsage summary  # send the weekly summary notification now
dms ipc call btUsage clear    # wipe all stats
```

## License

MIT
