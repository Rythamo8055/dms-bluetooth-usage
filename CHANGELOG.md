# Changelog

All notable changes to Bluetooth Usage are documented here.

## 1.1.1 — 2026-11-10

### Fixed

- Listening detection no longer polls `pactl` while no Bluetooth audio device is
  connected. The daemon now uses `pactl subscribe` and refreshes only on relevant
  stream/sink events, with a throttled fallback.
- The state file is no longer rewritten every 30 seconds when no session is open.
- The bar's one-second live timer only runs while a device is connected.
- Open sessions left behind by a shutdown are closed at their last heartbeat
  instead of counting the whole downtime as connected/listening time.
- Replaced hard-coded pixel sizes with Theme tokens and the raw `Flickable` with
  `DFlickable`.

## 1.1.0 — 2026-11-10

### Added

- Separate **listening time** tracking, based on uncorked audio streams routed to
  the device's Bluetooth sink.
- **Idle time** (connected but not playing).
- Connected vs. listening breakdown in the popout, device cards and the 7-day
  chart (dual bar).
- Live `listening` / `idle` indicator in the DankBar.
- **Weekly summary notification**, configurable day/time, with connected,
  listening, idle and top-device totals.
- `btUsage preview` and `btUsage summary` IPC commands.
- "Send weekly summary now" button in settings.

### Changed

- Weekly summary delivery uses the built-in `dms notify` command.
- Data file schema extended with `playingSeconds`, `playingDays`,
  `playingStart`, `lastPlayingSeen` and `lastWeeklySummary`.

## 1.0.0 — 2026-11-10

### Added

- Initial release.
- Composite DMS plugin: tracking daemon + DankBar widget with popout.
- Per-device connection sessions, today/all-time totals, last session and battery.
- 7-day connected-time chart.
- Reconnect grace period and optional connect/disconnect toasts.
- Restart-safe local state and IPC status/today/clear commands.
