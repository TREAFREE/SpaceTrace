# Changelog

All notable user-visible changes are recorded in this file.

## Unreleased

### Added

- Add a bounded, cancellation-aware application projector that resumes persisted schema-v11 work at launch, rejects missing frames and non-advancing repositories, and is verified through the real SQLite queue. Production paired finalization still remains release blocking.
- Add the schema-v11 immutable local history ledger: atomic paired observation frames, stable-evidence endpoints, deterministic projection checkpoints/findings, evidence-invalidated retractions, persisted History Off, ordered graph retention, v10/v11 recovery canaries, cumulative privacy enforcement, and passing current-host 500k/1M repository gates. Production scanner/paired-finalization/UI integration and public-release gates remain open.
- Add a pure immutable historical-finding projection with exact endpoint states, explicit absence, coverage-aware growth/decrease/appearance/disappearance, four-parent stable-identity move proof, non-overlapping positive ranking, frozen classifier decisions, deterministic UTF-8 ordering, and fail-closed v1 Codable contracts. Production scanner/paired-finalization wiring and finding UI remain release blocking.
- Add a pure offline deterministic attribution module with validated versioned rules, path-free evidence codes, stable precedence, cross-category ambiguity fallback, eight initial P0 category families, and a versioned precision/recall/Unknown regression corpus.
- Add fail-closed ad-hoc Release Candidate packaging with clean-commit provenance, exact sandbox-entitlement checks, Hardened Runtime, a read-only compressed DMG, JSON truth manifest, SHA-256 verification, and bilingual install/removal guidance.
- Add a native macOS application shell with an accessible sidebar, an honest overview readiness state, and the existing directory-permission journey as a dedicated destination.
- Add a system `MenuBarExtra` for lightweight permission health, reopening the main window, bounded retry when a volume is unavailable, and normal application quit.
- Add immediate startup/wake/system-time-change capacity sampling, sleep-aware deferral, and system-scheduled daily history retention.
- Show current startup-volume availability and a fail-closed 24-hour change in the menu bar, with explicit collecting, stale, gap, clock, volume-identity, and unavailable states.
- Add a minimal, accessible directory-authorization screen backed by the macOS system folder picker.
- Show explicit authorized, unavailable, stale/reauthorization-required, unconfigured, and failed permission states.
- Allow users to replace or remove a watched-directory grant without deleting monitored files or historical measurements.
- Add deterministic authorization coordinator, view-model, sandbox entitlement, and UI smoke coverage plus an English/Chinese qualification protocol.

### Release decision — NO-GO retained; evidence refreshed 2026-08-12

- **Public Beta: NO-GO.** No tag, GitHub Release, or artifact upload is authorized by this record.
- **Local engineering RC generation: CONDITIONAL GO.** Maintainers may generate `0.1.0-rc.1` ad-hoc artifacts to continue controlled testing. They are not Apple-verified, are expected to be rejected by Gatekeeper, and are limited to Apple Silicon with a declared—not runtime-qualified—macOS 15.6 minimum.
- The current-host 25-hour ad-hoc endurance run and its Activity Monitor/thermal evidence passed. The current-host controlled UI runner passed eight authorization/history scenarios and key accessibility-tree assertions.
- Public blockers remain: production scanner→paired-v11/projector and finding/History-Off UI integration; a future approved replacement/supersession model; production stable-identity qualification; classification-corpus expansion and user-controlled export/redaction; macOS 15.6 runtime; genuine permission/replacement matrices; manual assistive-technology review; ADR-003/004/006 approval; clean quarantine install/rollback; Developer ID/notarization or explicit unsigned-risk acceptance; approved license/notices/SBOM; and required usability evidence.

### Draft tester notes — not published

- Architecture: Apple Silicon `arm64` only. The project and RC manifest declare macOS 15.6+, but no public compatibility claim may be made until the app runs through its complete P0 lifecycle on macOS 15.6.
- Permissions: SpaceTrace remains sandboxed and requests read-only access only to directories the user explicitly chooses. Removing a grant never deletes files.
- Installation: the current RC is ad-hoc signed and not notarized. A trusted tester must verify the SHA-256 and source commit, then may use the per-app **System Settings > Privacy & Security > Open Anyway** exception. Do not disable Gatekeeper globally.
- Data: bookmarks, settings, and history live in the SpaceTrace sandbox container. Deleting the App does not automatically delete monitored files or container data; complete container removal requires a separate exact-path, user-authorized action.
- Updates and rollback: manual replacement is the only current mechanism. Cross-build bookmark continuity, schema downgrade, and rollback are not qualified; release notes must warn that directory reselection may be required and must not promise rollback.
