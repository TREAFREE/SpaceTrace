# Release Readiness Gate

Status: **Implemented fail-closed ad-hoc Public Beta gate; current release remains NO-GO**

Last updated: 2026-08-14

Chinese companion translation: [release-readiness-gate.zh-CN.md](release-readiness-gate.zh-CN.md). This English document remains the engineering source of truth.

## Purpose and trust boundary

The release-readiness gate prevents a locally valid DMG from being mistaken for a qualified public release. It is read-only: it never creates a tag, PR, GitHub Release, branch rule, license, or trust exception. Version 1 intentionally supports only the maintainer-approved `adhoc-public-beta` distribution path. A future Developer ID/notarized release requires a separately reviewed schema and notarization/stapling verification; it cannot be asserted through this contract.

The gate validates two things:

1. the exact candidate files still match their manifest, checksums, source commit, signature truth, sandbox contract, architecture, deployment target, SPDX license, and read-only DMG contents;
2. every external/manual release gate has a path-free passing evidence digest and an explicit final GO decision.

A digest is a binding reference, not proof that the referenced review was performed correctly. The maintainer must inspect each evidence report before writing `passed:<sha256>`. The verifier rejects missing, malformed, failed, or unbound declarations but cannot make a human review true.

## Command

Run only from a clean `main` worktree whose `HEAD` exactly equals the fetched `origin/main` and the candidate manifest's `sourceCommit`:

```bash
make verify-release-readiness \
  QUALIFICATION=/absolute/path/release-qualification-v1.json \
  ARTIFACTS=/absolute/path/SpaceTrace-0.1.0-beta.1
```

Exit behavior is stable:

| Exit | Meaning |
|---:|---|
| `0` | `release readiness: GO`; the machine-verifiable contract is complete |
| `1` | `release readiness: NO-GO (<category>)`; at least one release invariant is absent or contradictory |
| `64` | Command usage is invalid |

Output deliberately contains only a typed category, never an input path or evidence content.

## Qualification v1 contract

The input is a regular, non-symlink JSON file of at most 64 KiB. It is a flat object with exactly these keys; unknown, missing, duplicate, or wrongly typed fields fail closed.

| Key | Required value |
|---|---|
| `schemaVersion` | integer `1` |
| `releaseVersion` | exact Semantic Versioning string and artifact filename version |
| `sourceCommit` | 40-character lowercase Git SHA matching manifest, local `HEAD`, and `origin/main` |
| `manifestSha256` | SHA-256 of the candidate manifest |
| `checksumSha256` | SHA-256 of the four-entry checksum file |
| `licenseIdentifier` | exactly `PolyForm-Noncommercial-1.0.0`; it must equal both SPDX package declarations and the hash-frozen repository license |
| `distributionMode` | exactly `adhoc-public-beta` in v1 |
| `distributionRiskAccepted` | boolean `true`, recording the maintainer decision made on 2026-08-14 |
| `artifactVerification` | `passed:<sha256>` |
| `repositoryIntegration` | `passed:<sha256>` |
| `minimumOSQualification` | `passed:<sha256>` for the macOS 15.6 P0 matrix |
| `currentOSQualification` | `passed:<sha256>` for the current-stable-macOS P0 matrix |
| `cleanAccountGatekeeper` | `passed:<sha256>` for quarantined DMG, per-app **Open Anyway**, and post-trust launch |
| `replacementContinuity` | `passed:<sha256>` for independently built replacement, bookmark, and database continuity |
| `permissionsAndVolumes` | `passed:<sha256>` for denial, revocation, stale grant, absent/returning/replaced volume, and reauthorization |
| `accessibilityReview` | `passed:<sha256>` for keyboard, VoiceOver, Reduce Motion, Increase Contrast, and text review |
| `usabilityResearch` | `passed:<sha256>` for the PRD formative-session/KPI record |
| `privacyOfflineReview` | `passed:<sha256>` for diagnostics, redaction, no destructive operation, and no unsolicited network activity |
| `governanceDisposition` | `passed:<sha256>` for release-relevant ADR and exception review |
| `severityReview` | `passed:<sha256>` proving zero open Sev-0/Sev-1 defects at the decision time |
| `finalReleaseDecision` | `go:<sha256>` binding the explicit maintainer release decision |

Each referenced evidence report must itself name the release version and source commit, state the observed outcome, remain free of raw user paths/secrets, and be retained with the release record. Reusing an unrelated digest merely satisfies syntax and is a review failure.

## Artifact verification

The artifact directory must be a regular directory containing exactly the six files defined by the RC packaging contract. The verifier independently checks:

- manifest and checksum hashes bound by the qualification file;
- exactly four expected checksum entries and `shasum -a 256 -c` success;
- manifest schema, version, clean-source claim, source commit, Bundle ID, macOS 15.6 deployment target, arm64-only architecture, filenames, and embedded hashes;
- SPDX 2.3 version plus exact `licenseDeclared`/`licenseConcluded = PolyForm-Noncommercial-1.0.0`, repository-license hash, and notices match;
- strict code-sign validity, ad-hoc/no-Team-ID truth, and Hardened Runtime;
- exact three sandbox entitlements;
- executable hash, arm64 slice, Info.plist identity, no bundled framework/dylib, and system-only dynamic linkage;
- DMG verification, read-only mount, exact four mounted entries, `/Applications` link, notices equality, and mounted App code signature.
- bilingual mounted install guidance byte-identical to a fresh version/source-bound generator output, including checksum, per-app Gatekeeper exception, manual-update, rollback, and no-deletion boundaries.

The verifier also bounds the qualification, manifest, checksum, SPDX, notices, and DMG sizes before parsing or hashing them. It refuses symlink substitution at every top-level input boundary.

## Automated contract

The TDD contract builds and ad-hoc signs a tiny synthetic arm64 App, creates and mounts a temporary read-only DMG, and covers valid input plus missing/unknown/duplicate fields, type confusion, failed evidence, NO-GO decision, source/license/distribution mismatch, unexpected/symlinked artifacts, checksum/executable tampering, dirty/wrong/stale repository integration, malformed JSON, and symlinked qualification input:

```bash
make release-readiness-test
```

The test uses only disposable temporary data and removes it on exit. It does not download a macOS runtime, Xcode, package, or signing identity.

## Current expected result

No qualification JSON is checked in because the remaining evidence must not be fabricated. The retained historical rc.7 is expected to fail this gate: it was built from a feature-branch commit, predates the approved license and therefore has `NOASSERTION`, and the macOS 15.6, clean-account, packaged replacement/permission, manual accessibility/usability, governance, and final-release receipts do not yet exist.

The maintainer has accepted the ad-hoc Public Beta risk boundary and ADR-010's PolyForm Noncommercial 1.0.0 plus CLA decision. The repository-license gate is closed, but until every other evidence receipt exists and the final DMG is rebuilt from protected `main` with the approved metadata, the correct result remains **NO-GO**.
