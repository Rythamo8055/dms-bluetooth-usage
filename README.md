# Bluetooth Usage for DankMaterialShell

A DMS plugin that tracks how long your Bluetooth audio devices stay connected.
Built for TWS earbuds, but works with any headset or speaker.

![Bluetooth Usage popout](screenshot.png)

## Features

- **Live session time** in the DankBar: icon + current connection duration.
- **Popout details**: today, all-time, last session, battery, and per-device history.
- **7-day chart** aggregated across all tracked devices.
- **Survives restarts**: sessions are stored in
  `~/.local/state/dms/bluetooth-usage.json`, not in memory.
- **Reconnect grace period**: short A2DP/HFP dropouts are merged into one session.
- **Optional toasts** on connect/disconnect and optional battery readout.
- **IPC**: `dms ipc call btUsage status`, `today`, or `clear`.

## How it works

DMS already exposes BlueZ through `BluetoothService`. The plugin adds two surfaces:

- `BluetoothUsageDaemon.qml` polls the adapter every 2 seconds, diffs the set of
  connected devices, and closes/opens sessions. A heartbeat lets it recover the
  correct end time after a DMS restart or a power loss.
- `BluetoothUsageWidget.qml` reads the same JSON file and adds the currently
  running session on top for live display.

No extra system packages are required. Only `bluez` (already used by DMS) is needed.

## Install (local)

```bash
git clone <this-repo> ~/dms-bluetooth-usage
ln -s ~/dms-bluetooth-usage ~/.config/dms/plugins/bluetoothUsage
dms ipc call plugin-scan rescan
```

Then enable **Bluetooth Usage** in DMS Settings → Plugins and add the widget to
your bar from Settings → Bar → Widgets.

If the plugin does not appear after copying files, restart the shell:

```bash
systemctl --user restart dms
```

## Notes and limitations

- BlueZ does not keep a connection history, so tracking starts when the plugin
  is first enabled. Previous listening time cannot be reconstructed.
- "Usage" here means *connected time*. A paused earbud still counts as connected.
  If you want "audio actually playing" time instead, that would need a PipeWire
  stream monitor.
- Sessions shorter than the poll interval (2 s) are not recorded.
- Multi-point connections: each connected device gets its own session.
- Battery is whatever BlueZ exposes; many TWS buds report only one side.

## IPC

```bash
dms ipc call btUsage status   # JSON: active sessions, today, totals per device
dms ipc call btUsage today    # today's total seconds
dms ipc call btUsage clear    # wipe all stats
```

## License

MIT
