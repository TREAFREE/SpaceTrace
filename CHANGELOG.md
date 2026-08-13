# Changelog

All notable user-visible changes are recorded in this file.

## Unreleased

### Added

- Add a read-only, fail-closed ad-hoc Public Beta readiness gate that binds the exact six release artifacts to clean `main`/`origin/main`, source and checksum hashes, an approved non-`NOASSERTION` license, the accepted distribution-risk decision, and a path-free repository-integration receipt plus every minimum-OS, current-OS, Gatekeeper, replacement, permission, accessibility, usability, privacy, governance, severity, and final-GO receipt. Its disposable signed-App/read-only-DMG contract covers 23 positive and adversarial cases.
- Add deterministic SPDX 2.3 and third-party-notices release metadata, final
  Mach-O dependency auditing, manifest hash binding, four-file checksum
  verification, and a six-artifact RC contract. The current build graph has no
  external Swift package or bundled third-party library; project licensing
  remains `NOASSERTION` pending owner approval.
- Add a previewed, user-initiated diagnostic JSON export with default
  per-export path tokenization, per-export full-path confirmation, bounded
  finding selection, no upload surface, cancellation-safe atomic writes, and
  startup cleanup of owned partial files. The sandbox now carries
  user-selected read/write only for the exact save-panel destination; watched
  directory bookmarks remain explicitly read-only.
- Expand the reviewed attribution corpus to 64 known scenarios (eight per P0 category) and 32 Unknown near misses, with exact rule ID/version/confidence/evidence contracts and 100% repository precision, recall, and Unknown accuracy.
- Add a bounded historical-finding Overview backed by current-effective and immutable audit reads, with separate evidence-invalidated records, frozen classification evidence, exact logical/allocated semantics, complete-evidence time ranges, typed History Off/baseline-unavailable states, and explicit destructive confirmation.
- Add schema-v12 append-only reconciliation revisions and registered linear correcting projections, followed by the additive schema-v13 versioned original/corrected finding identity and target-specific invalidation contract. Terminal current-effective and immutable audit queries, durable reconciliation readiness, retention/recovery, diagnostics, released v13 fixtures, the Overview, and a real current-host 5 GiB gap-to-calibration qualification are included. The fail-closed repeated matrix subsequently passed 20 of 20 current-host trials against the 19-of-20 release threshold.
- Connect the production complete-scan path to atomic paired logical/allocated schema-v11 frames, frozen classification, APFS directory object/reuse qualification, complete-parent explicit-disappearance reconciliation, immediate projection, and launch-time pending-work recovery. Real Foundation scans now project growth, same-volume APFS moves, and observed disappearance; unproved missing rows remain missing evidence.
- Add a bounded, cancellation-aware application projector that drains newly registered schema-v11 work after commit, resumes persisted work at launch, rejects missing frames and non-advancing repositories, and is verified through the real SQLite queue.
- Add the schema-v11 immutable local history ledger: atomic paired observation frames, stable-evidence endpoints, deterministic projection checkpoints/findings, evidence-invalidated retractions, persisted History Off, ordered graph retention, v10/v11 recovery canaries, cumulative privacy enforcement, and passing current-host 500k/1M repository gates.
- Add a pure immutable historical-finding projection with exact endpoint states, explicit absence, coverage-aware growth/decrease/appearance/disappearance, four-parent stable-identity move proof, non-overlapping positive ranking, frozen classifier decisions, deterministic UTF-8 ordering, and fail-closed v1 Codable contracts.
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

### Release decision — NO-GO retained; evidence refreshed 2026-08-14

- **Public Beta: NO-GO.** No tag, GitHub Release, or artifact upload is authorized by this record.
- **Local engineering RC generation: CONDITIONAL GO.** Maintainers may generate `0.1.0-rc.7` ad-hoc artifacts to continue controlled testing. They are not Apple-verified, are expected to be rejected by Gatekeeper, and are limited to Apple Silicon with a declared—not runtime-qualified—macOS 15.6 minimum.
- The current-host 25-hour ad-hoc endurance run and its Activity Monitor/thermal evidence passed. The current-host controlled UI runner passed fifteen authorization/history/finding/export scenarios; the real signed-sandbox save panel wrote a bounded redacted JSON export and passed three consecutive repetitions.
- The retained `rc.7` package from pushed commit `a3b8b45` passed strict signing, exact-entitlement, final dependency audit, arm64, deployment-target, read-only DMG, manifest, four-entry checksum, SPDX/notices, and quarantined-copy integrity checks. Gatekeeper returned 3 and distribution policy returned 70 for the disclosed ad-hoc and missing-notary reasons. Non-quarantined `rc.6 → rc.7` and `rc.7 → rc.6` process replacement rows passed; they selected no directory and do not qualify bookmark or schema rollback. Exact disposable-container cleanup remained blocked by macOS privacy and is not counted as passed. The non-interactive qualifier refuses quarantined inputs before launch so the clean-account **Open Anyway** gate cannot be mistaken for a process failure.
- On 2026-08-14 the maintainer accepted an ad-hoc, unnotarized, manual-download Public Beta with explicit Gatekeeper warnings and no automatic updater, and rejected MIT. Public blockers remain: macOS 15.6 runtime; genuine bookmark/permission/replacement matrices; manual assistive-technology review of the implemented finding/reconciliation/export UI; ADR-003/004/006/008/009 approval; clean-account Gatekeeper-exception launch and rollback; an approved non-MIT project license; and required usability evidence. The versioned correction implementation/current-host 20-of-20 5 GiB matrix, FR-007/KPI-03 corpus, FR-014 implementation/current-host signed-sandbox export, deterministic SBOM/notices generation, and Beta distribution-policy decision are closed.

### Draft tester notes — not published

- Architecture: Apple Silicon `arm64` only. The project and RC manifest declare macOS 15.6+, but no public compatibility claim may be made until the app runs through its complete P0 lifecycle on macOS 15.6.
- Permissions: SpaceTrace remains sandboxed; monitored directories use explicit read-only bookmarks for locations the user chooses. User-selected write access is used only for a diagnostic file the user explicitly chooses to save. Removing a grant never deletes files.
- Installation: the current RC is ad-hoc signed and not notarized. A trusted tester must verify the SHA-256 and source commit, then may use the per-app **System Settings > Privacy & Security > Open Anyway** exception. Do not disable Gatekeeper globally.
- Data: bookmarks, settings, and history live in the SpaceTrace sandbox container. Deleting the App does not automatically delete monitored files or container data; complete container removal requires a separate exact-path, user-authorized action.
- Updates and rollback: manual replacement is the only current mechanism. Cross-build bookmark continuity, schema downgrade, and rollback are not qualified; release notes must warn that directory reselection may be required and must not promise rollback.
