# ADR-007: User-initiated diagnostic export with a narrow save capability

## Status

Accepted

Date: 2026-08-13

Chinese companion translation: [ADR-007-user-initiated-diagnostic-export.zh-CN.md](ADR-007-user-initiated-diagnostic-export.zh-CN.md). This English document is the engineering source of truth.

## Context

SpaceTrace needs a support artifact that a user can inspect and save without uploading data. FR-014 requires a preview, default path redaction, a separate confirmation for full paths, and interruption-safe cancellation. The sandboxed app previously declared only `com.apple.security.files.user-selected.read-only`, which cannot authorize writing the file selected through `NSSavePanel`.

Apple's user-selected read/write entitlement is coarse: it can authorize mutation of a user-selected location. Enabling it therefore increases the theoretical blast radius even though SpaceTrace only needs to create one export file. That expansion must not weaken the product rule that observed files and directories are read-only.

## Decision

1. The sandboxed app declares exactly App Sandbox, app-scoped bookmarks, and `com.apple.security.files.user-selected.read-write`.
2. Watched-directory acquisition remains explicitly read-only. `SecurityScopedWatchedScopeCatalog` creates bookmarks with `.securityScopeAllowOnlyReadAccess`, and no production filesystem port exposes write, delete, move, permission, hydration, or cleanup operations for observed data.
3. The write entitlement is used only after a user opens `NSSavePanel` from the Diagnostic Export page and chooses the exact destination file. The application never chooses a destination silently.
4. Every export shows a section/count preview before the save panel. The document includes bounded app/OS/architecture metadata, coverage state, typed path-free health events, and at most 100 explicitly selected historical findings. It never includes file contents, bookmark bytes, a network destination, or an automatic upload action.
5. Redaction is the default. It replaces the home root, watched roots, and remaining path components with inert labels or 96-bit tokens derived from an export-specific 256-bit random salt. The salt is never written, so tokens cannot be correlated across exports or reversed through a persistent dictionary.
6. Full paths require a warning and confirmation bound to one export UUID. Saving, cancelling, failing, or starting a later export invalidates that authorization.
7. A prepared document is limited to 2 MiB. It is first synchronized to a private Application Support staging directory with mode `0700` and file mode `0600`, then atomically committed to the selected destination. Cancellation and pre-commit failure remove the partial file and preserve an existing destination. Startup recovery removes only UUID-named regular `.partial` files; it does not follow symbolic links or delete unknown entries.
8. The export is JSON schema version 1 with deterministic key ordering. It contains `includesFileContents = false`, `uploadsAutomatically = false`, the chosen path mode, frozen classification rule/catalog evidence, and typed finding validity. No production import or upload surface is created by this decision.
9. Release packaging fails closed unless the exact three-entitlement set is present. A change to the entitlement set, export limits, redaction algorithm, upload boundary, or watched-directory access mode requires ADR and security review.

## Options considered

| Option | Benefits | Costs / failure modes | Assessment |
| --- | --- | --- | --- |
| Save-panel file export with guarded read/write entitlement | Native user choice; ordinary JSON file; works in the sandbox | Coarse entitlement is broader than one file; requires strict code and release gates | Selected |
| Keep read-only entitlement and copy through an unsandboxed helper | Keeps main entitlement unchanged | Adds a privileged trust boundary, IPC, signing, update, and cleanup complexity | Rejected |
| Put export only inside Application Support | No entitlement expansion | Users cannot conveniently inspect or share the artifact; conflicts with FR-014 | Rejected |
| Automatic support upload | Convenient support workflow | Introduces network, consent, retention, authentication, and breach risks | Rejected |
| Export raw paths by default | Maximum debugging detail | Violates minimization and exposes personal/project names | Rejected |

## Consequences

### Positive

- Users control when, what, and where a diagnostic artifact is written.
- The default artifact is useful while preventing stable cross-export path correlation.
- Cancellation, write failure, and relaunch have typed and testable cleanup behavior.
- Support can inspect exact versions, coverage, health codes, and frozen rule evidence without receiving file contents.

### Negative and accepted trade-offs

- The sandbox entitlement can grant more write authority than the implementation intends; code review and API shape are part of the security boundary.
- Full-path export remains sensitive even with explicit confirmation.
- An ad-hoc build still lacks publisher verification and notarization; export safety does not qualify public distribution.
- A JSON file saved elsewhere is governed by the user's destination permissions and backup/sync configuration after the write completes.

### Guardrails

- Monitoring code accepts only read-only bookmark evidence and has no reference to the export writer.
- Export code contains no `URLSession`, sharing service, shell, Quick Look, or file-content enumeration.
- UI and errors may display the selected output's filename, never log or persist its full path.
- The private staging directory is excluded from scans and privacy-safe diagnostics.
- Tests cover authorization mismatch, token stability/isolation, bounded selection, exact bytes, modes, cancellation, failure preservation, symlink-safe recovery, and no-upload fields.

## Validation plan

1. Run application, platform, strict-concurrency, privacy, and Release build gates.
2. Inspect source and signed-app entitlements; require the exact three-key set and reject both the obsolete read-only key and any additional key.
3. In a signed sandbox build, select a watched directory, restart, revoke, and restore it; verify the bookmark remains read-only and monitoring never mutates content.
4. Export redacted JSON, inspect all fields, and prove username, watched path components, bookmark bytes, and the random salt are absent.
5. Confirm full-path mode once, cancel, start another export, and verify a second confirmation is required.
6. Cancel during staging, simulate destination failure, leave a controlled partial across launch, and verify cleanup and destination preservation.
7. Run VoiceOver, keyboard-only, Reduce Motion, Increase Contrast, and large-text review on the preview, warning, selection, progress, error, and success states.
8. Repeat fresh-install, quarantine, replacement, macOS 15.6, and DMG verification before authorizing a GitHub prerelease.

## Revisit triggers

- Apple offers a narrower sandbox API for user-selected single-file creation.
- Export needs compression, attachments, file contents, sharing services, or network upload.
- A security review finds a path from watched-directory capability to mutation.
- The export schema or redaction algorithm needs backward-compatible consumption.
- Mac App Store distribution or an unsandboxed distribution profile is selected.
