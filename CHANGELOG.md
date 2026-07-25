# Changelog

All notable user-visible changes are recorded in this file.

## Unreleased

### Added

- Add a native macOS application shell with an accessible sidebar, an honest overview readiness state, and the existing directory-permission journey as a dedicated destination.
- Add a system `MenuBarExtra` for lightweight permission health, reopening the main window, bounded retry when a volume is unavailable, and normal application quit.
- Add immediate startup/wake/system-time-change capacity sampling, sleep-aware deferral, and system-scheduled daily history retention.
- Show current startup-volume availability and a fail-closed 24-hour change in the menu bar, with explicit collecting, stale, gap, clock, volume-identity, and unavailable states.
- Add a minimal, accessible directory-authorization screen backed by the macOS system folder picker.
- Show explicit authorized, unavailable, stale/reauthorization-required, unconfigured, and failed permission states.
- Allow users to replace or remove a watched-directory grant without deleting monitored files or historical measurements.
- Add deterministic authorization coordinator, view-model, sandbox entitlement, and UI smoke coverage plus an English/Chinese qualification protocol.
