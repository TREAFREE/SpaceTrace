# Ad-hoc Release Candidate Checklist

Status: **Packaging contract implemented; public distribution not qualified**

Last updated: 2026-08-10

Chinese companion translation: [release-candidate-checklist.zh-CN.md](release-candidate-checklist.zh-CN.md). This English document remains the engineering source of truth.

## Purpose and boundary

This checklist creates an inspectable SpaceTrace tester artifact when no Developer ID certificate is available. The application is ad-hoc signed with Hardened Runtime, remains sandboxed, and is packaged in a read-only compressed DMG. It is **not notarized**, Gatekeeper cannot verify its publisher, and it must not be described as a stable or Apple-verified release.

The packaging result is source-and-contract reproducible: the manifest binds the artifact to a clean Git commit, version, build environment, entitlements, architecture, deployment target, and checksums. UDZO/HFS+ image metadata can differ between runs, so byte-for-byte identical DMG hashes are not claimed.

## Maintainer build

Prerequisites:

- Apple Silicon Mac with the repository's supported Xcode toolchain;
- a clean Git worktree at the intended immutable commit;
- no existing output directory;
- an explicit Semantic Versioning identifier such as `0.1.0-rc.1`.

Run:

```bash
make package-release-candidate \
  VERSION=0.1.0-rc.1 \
  OUTPUT=/private/tmp/SpaceTrace-0.1.0-rc.1
```

The prerelease/build suffix belongs to the release manifest and filenames. The numeric SemVer core becomes `CFBundleShortVersionString`; the deterministic Git commit count becomes `CFBundleVersion`.

## Exact artifact contract

The new output directory contains exactly:

| Artifact | Purpose |
|---|---|
| `SpaceTrace-<version>.app` | Local inspection and qualification bundle; ad-hoc signed with Hardened Runtime |
| `SpaceTrace-<version>.dmg` | Read-only compressed tester image containing `SpaceTrace.app`, an Applications link, and a bilingual trust warning |
| `SpaceTrace-<version>.manifest.json` | Commit, version, build environment, Bundle ID, deployment target, architecture, entitlements, signing truth, and artifact hashes |
| `SpaceTrace-<version>.sha256` | SHA-256 entries for the DMG and manifest |

The packager fails closed if the source tree is dirty, the version is invalid or absent, the output already exists, the Release build fails, or the final bundle differs from these invariants:

- Bundle ID `com.TREAFREE.SpaceTrace`;
- Apple Silicon `arm64` only;
- `LSMinimumSystemVersion = 15.6`;
- App Sandbox, read-only user-selected files, and app-scoped bookmarks are the exact entitlement set;
- ad-hoc signature, no Team ID, Hardened Runtime present;
- manifest fields `developerId = false` and `notarized = false`.

## Artifact verification

From the output directory:

```bash
shasum -a 256 -c SpaceTrace-0.1.0-rc.1.sha256
codesign --verify --deep --strict --verbose=2 SpaceTrace-0.1.0-rc.1.app
codesign -dvvv --entitlements :- SpaceTrace-0.1.0-rc.1.app
hdiutil verify SpaceTrace-0.1.0-rc.1.dmg
spctl --assess --type execute --verbose=4 SpaceTrace-0.1.0-rc.1.app
```

The first four checks must succeed. `spctl` is expected to reject this ad-hoc, unnotarized artifact. A rejection confirms the disclosed trust boundary; it is not a packaging failure. An unexpected acceptance must be investigated for a host-local Gatekeeper exception and must not be generalized to other Macs.

The automated contract is:

```bash
make package-release-candidate-test VERSION=0.1.0-rc.1
```

## Tester installation and first launch

1. Download the DMG, manifest, and checksum from the same GitHub Release.
2. Verify the SHA-256 and confirm that the manifest's `sourceCommit` is the intended public commit.
3. Open the DMG and drag SpaceTrace to Applications.
4. Try to open SpaceTrace normally. Gatekeeper is expected to block the first attempt.
5. Only if the tester trusts the commit and checksum, open **System Settings > Privacy & Security**, locate the blocked SpaceTrace message, choose **Open Anyway**, and confirm the one-app exception.
6. Never disable Gatekeeper globally and never use a recursive quarantine-removal command as the supported installation path.

The first launch must present an unconfigured, evidence-honest state. SpaceTrace accesses only directories the user explicitly selects through the system picker.

## Replacement and permission matrix

Every distinct RC build must execute and record these rows. A previous ad-hoc smoke does not qualify a new DMG.

The non-interactive launch/replacement subset uses a disposable Bundle ID and attempts to move only its exact matching temporary sandbox container to Trash:

```bash
make qualify-release-candidate \
  PRIMARY_APP=/absolute/path/to/first/SpaceTrace-0.1.0-rc.1.app \
  REPLACEMENT_APP=/absolute/path/to/second/SpaceTrace-0.1.0-rc.1.app
```

It separately reports fresh launch, graceful same-build restart, and independent-binary replacement launch. Container removal is fail-closed: if macOS container privacy denies Terminal access, the command returns `container-cleanup-blocked-by-macos-privacy`, prints the exact residual path, and never changes container metadata or broadens the deletion target. The flow deliberately does not select a directory, so it cannot qualify bookmark continuity, denial, stale authorization, or external-volume behavior.

| Row | Expected result | Current qualification |
|---|---|---|
| Fresh copy from mounted DMG | App launches only after the disclosed per-app Gatekeeper exception; no fabricated history | Open |
| Same-build quit and restart | Same bundle identity restores valid bookmarks without another picker | Open for packaged RC |
| Replace Applications copy with a separately built RC | App launches; existing bookmark either restores exactly or presents explicit reauthorization | Open; never assume ad-hoc designated-requirement continuity |
| Stale or revoked grant | No silent refresh or scope widening; user must select again | Deterministic fixture passed; genuine RC condition open |
| Permission denied | Existing verified state is preserved or access is shown as unavailable; no scan starts from incomplete capability | Open for packaged RC |
| External volume absent and same Volume UUID returns | Unavailable state while absent; exact authorization resumes when the same identity returns | Earlier signed-sandbox smoke passed; new RC row open |
| Same-name replacement with a different Volume UUID | Old authorization does not transfer | Native lifecycle passed; packaged UI row open |
| Database/schema replacement | Migration backup/recovery behavior matches released-schema fixtures; no silent rebuild | Deterministic tests passed; packaged upgrade row open |

### Current-host non-interactive evidence (2026-08-10)

Two independent `0.1.0-rc.1` artifacts were built from clean commit `f2119be3fe0ed05e98ef5ec3656e6f7ccbe1d860`. Both packaging runs passed signature, entitlement, architecture, deployment-target, DMG, manifest, and checksum verification. As expected, their executable and DMG hashes differed; each manifest recorded its own values and made no byte-identical claim. `spctl` returned 3 and `rejected` for the ad-hoc unnotarized App.

Using the first App and then the independently built replacement under one disposable Bundle ID, fresh launch, graceful same-build restart, and replacement launch all passed. No directory was selected. macOS containermanager privacy denied both direct deletion and the system `trash` operation for the approximately 32 KiB disposable container, so cleanup is recorded as blocked rather than passed. The exact current-host residual is:

```text
~/Library/Containers/com.TREAFREE.SpaceTrace.RCQualification.run20260810152354p52734
```

Removing it requires a separate, explicit user-authorized Full Disk Access action. It contains qualification data only; no monitored directory was modified.

If a replacement build requires directory reselection, the GitHub Release notes must state that plainly before testers install it.

## Removal and rollback

- Quit SpaceTrace and move only `SpaceTrace.app` to Trash to uninstall the application. This does not delete monitored files.
- The sandbox container may retain bookmarks, history, and settings for a future reinstall. A tester who explicitly wants a complete reset may remove the SpaceTrace container through an owner-reviewed manual procedure after confirming the exact Bundle ID and granting the tool used for removal the required macOS privacy access. The release artifact must not delete it automatically, alter containermanager metadata, or ask for broad disk access during normal use.
- Rollback must use a previously checksummed artifact. Schema compatibility and bookmark behavior must be tested before calling rollback supported.
- Removing an authorization inside SpaceTrace releases that grant; it never deletes the selected directory or its contents.

## Public-release blockers

This tester channel does not close Developer ID signing, notarization/stapling, a quarantined clean-Mac download test, macOS 15.6 runtime qualification, the complete replacement matrix, ADR-003/ADR-004 review, or the explicit release decision gate.
