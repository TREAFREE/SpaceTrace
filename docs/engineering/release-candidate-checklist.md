# Ad-hoc Release Candidate Checklist

Status: **Packaging contract implemented; public distribution not qualified**

Last updated: 2026-08-13

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
| `SpaceTrace-<version>.dmg` | Read-only compressed tester image containing `SpaceTrace.app`, an Applications link, the third-party notices, and a bilingual trust warning |
| `SpaceTrace-<version>.manifest.json` | Commit, version, build environment, Bundle ID, deployment target, architecture, entitlements, signing truth, and artifact hashes |
| `SpaceTrace-<version>.sha256` | SHA-256 entries for the DMG, manifest, SPDX document, and notices |
| `SpaceTrace-<version>.spdx.json` | Deterministic SPDX 2.3 source/dependency and provenance inventory |
| `SpaceTrace-<version>.third-party-notices.txt` | Exact bundled-dependency notice and project-license boundary; also included in the DMG |

The packager fails closed if the source tree is dirty, the version is invalid or absent, the output already exists, the Release build fails, or the final bundle differs from these invariants:

- Bundle ID `com.TREAFREE.SpaceTrace`;
- Apple Silicon `arm64` only;
- `LSMinimumSystemVersion = 15.6`;
- App Sandbox, user-selected read/write, and app-scoped bookmarks are the exact
  entitlement set. Read/write exists only for the exact diagnostic-export file
  chosen in `NSSavePanel`; watched-directory bookmarks remain explicitly
  read-only;
- ad-hoc signature, no Team ID, Hardened Runtime present;
- manifest fields `developerId = false` and `notarized = false`;
- no remote Swift package, bundled framework/dylib, or non-system Mach-O
  dependency. Final binary linkage is restricted to `/System/Library` and
  `/usr/lib`.

## Artifact verification

From the output directory:

```bash
shasum -a 256 -c SpaceTrace-0.1.0-rc.1.sha256
codesign --verify --deep --strict --verbose=2 SpaceTrace-0.1.0-rc.1.app
codesign -dvvv --entitlements :- SpaceTrace-0.1.0-rc.1.app
hdiutil verify SpaceTrace-0.1.0-rc.1.dmg
plutil -extract spdxVersion raw -o - SpaceTrace-0.1.0-rc.1.spdx.json
plutil -extract packages.0.licenseDeclared raw -o - SpaceTrace-0.1.0-rc.1.spdx.json
spctl --assess --type execute --verbose=4 SpaceTrace-0.1.0-rc.1.app
```

The first six checks must succeed; the SPDX values must be `SPDX-2.3` and
`NOASSERTION`. `spctl` is expected to reject this ad-hoc, unnotarized artifact.
A rejection confirms the disclosed trust boundary; it is not a packaging
failure. An unexpected acceptance must be investigated for a host-local
Gatekeeper exception and must not be generalized to other Macs.

The SPDX document is a source/provenance and dependency inventory, not a
vulnerability attestation. The current graph contains no external Swift
package or bundled third-party library; Apple frameworks, the system Swift
runtime, and system `libsqlite3` are platform-provided. `NOASSERTION` is
intentional: metadata generation does not approve a project license on the
owner's behalf.

The automated contract is:

```bash
make package-release-candidate-test VERSION=0.1.0-rc.1
```

## Tester installation and first launch

1. Download the DMG, manifest, checksum, SPDX document, and notices from the same GitHub Release.
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
| Fresh copy from mounted DMG | App launches only after the disclosed per-app Gatekeeper exception; no fabricated history | Read-only mount, copy, quarantine, and expected Gatekeeper rejection passed for `0.1.0-rc.3`; clean-account **Open Anyway** launch remains open |
| Same-build quit and restart | Same bundle identity restores valid bookmarks without another picker | Process restart passed under a disposable identity; packaged bookmark continuity remains open |
| Replace Applications copy with a separately built RC | App launches; existing bookmark either restores exactly or presents explicit reauthorization | Independent-binary process replacement passed; packaged bookmark continuity remains open and must not be assumed from ad-hoc signing |
| Stale or revoked grant | No silent refresh or scope widening; user must select again | Deterministic fixture passed; genuine RC condition open |
| Permission denied | Existing verified state is preserved or access is shown as unavailable; no scan starts from incomplete capability | Open for packaged RC |
| External volume absent and same Volume UUID returns | Unavailable state while absent; exact authorization resumes when the same identity returns | Earlier signed-sandbox smoke passed; new RC row open |
| Same-name replacement with a different Volume UUID | Old authorization does not transfer | Native lifecycle passed; packaged UI row open |
| Database/schema replacement | Migration backup/recovery behavior matches released-schema fixtures; no silent rebuild | Deterministic tests passed; packaged upgrade row open |

### Current-host candidate evidence (2026-08-13)

Two independent `0.1.0-rc.3` artifacts were built on macOS 26.6.1 with Xcode 26.1.1 from clean commit `d4f6cde5ffd328e21156b084fe761eb13aa09699`. Both packaging runs passed signature, exact-entitlement, architecture, deployment-target, DMG, manifest, and checksum verification. Their independent executable SHA-256 values were `6f24fa09d1b02c6d96605f0043afbd053385a2504dc40e73a35bbba6351bb359` and `bd00c70c98cec6d4a7237a98f731b333ae946eb6aece583cdd7cdc51a9eba725`; the primary DMG SHA-256 was `781fcacc98c9e53513876a524349541142bb02fd1c864eb9b451219745b84368`. Each manifest recorded its own values and made no byte-identical claim.

The primary DMG mounted read-only and exposed exactly `SpaceTrace.app`, the `/Applications` symlink, and `READ-ME-FIRST.txt`. A copied App carrying a synthetic download-quarantine attribute still passed strict code-sign verification. `spctl` returned 3 and `rejected`; `syspolicy_check distribution` returned 70 and independently reported an ad-hoc signature plus a missing notarization ticket. The executable and `Info.plist` both recorded macOS 15.6 as their minimum. These checks prove the declared artifact and trust boundary on the current host; they do not replace a clean-account **Open Anyway** launch or macOS 15.6 runtime qualification.

The Apple-identity-signed Xcode sandbox runner completed all 14 authorization/history/finding/export UI scenarios. The diagnostic-export case opened the real `NSSavePanel`, confirmed a user-selected destination, read the resulting JSON from disk, and verified the 2 MiB bound, redacted path mode, and no-upload declaration. That case also passed three consecutive focused repetitions. This qualifies the current-host signed-sandbox save path; it does not claim that a quarantined ad-hoc RC has completed the manual Gatekeeper exception on a clean account.

Using the first App and then the independently built replacement under one disposable Bundle ID, fresh launch, graceful same-build restart, and replacement launch all passed. No directory was selected. macOS containermanager privacy denied both direct deletion and the system `trash` operation for the approximately 32 KiB disposable container, so cleanup is recorded as blocked rather than passed. The exact current-host residual is:

```text
~/Library/Containers/com.TREAFREE.SpaceTrace.RCQualification.run20260812183820p22237
```

Removing it requires a separate, explicit user-authorized Full Disk Access action. It contains qualification data only; no monitored directory was modified.

If a replacement build requires directory reselection, the GitHub Release notes must state that plainly before testers install it.

## Removal and rollback

- Quit SpaceTrace and move only `SpaceTrace.app` to Trash to uninstall the application. This does not delete monitored files.
- The sandbox container may retain bookmarks, history, and settings for a future reinstall. A tester who explicitly wants a complete reset may remove the SpaceTrace container through an owner-reviewed manual procedure after confirming the exact Bundle ID and granting the tool used for removal the required macOS privacy access. The release artifact must not delete it automatically, alter containermanager metadata, or ask for broad disk access during normal use.
- Rollback must use a previously checksummed artifact. Schema compatibility and bookmark behavior must be tested before calling rollback supported.
- Removing an authorization inside SpaceTrace releases that grant; it never deletes the selected directory or its contents.

## Public-release blockers

This tester channel does not close Developer ID signing, notarization/stapling, a quarantined clean-account **Open Anyway** launch, macOS 15.6 runtime qualification, bookmark continuity across an independently built replacement, the complete permission/replacement matrix, ADR-003/ADR-004/ADR-006 review, project-license approval, manual accessibility/usability review, or the explicit release decision gate. The SBOM/notices generation contract is implemented, but `NOASSERTION` deliberately keeps that owner decision open.
