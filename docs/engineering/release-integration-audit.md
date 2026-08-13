# Release Integration Audit

Status: **Local DMG candidate verified; GitHub release integration incomplete**

Last updated: 2026-08-14

Chinese companion translation: [release-integration-audit.zh-CN.md](release-integration-audit.zh-CN.md). This English document remains the engineering source of truth.

## Purpose and boundary

This audit separates three states that must not be conflated:

1. a locally built artifact that satisfies the packaging contract;
2. a release candidate integrated into the protected repository and CI flow;
3. a public GitHub Release that satisfies the product, platform, privacy, and distribution gates.

The retained `0.1.0-rc.7` DMG is in the first state. It is not a public release authorization. This document is a dated snapshot of repository and GitHub state; every dynamic check must be repeated immediately before a release decision.

## Evidence snapshot

The following evidence was refreshed on 2026-08-14:

| Area | Observed state | Release meaning |
|---|---|---|
| Repository | `TREAFREE/SpaceTrace` is public; default branch is `main` | Public visibility does not itself approve a binary release |
| Candidate branch | `agent/native-fsevents-integration` is 0 commits behind and 85 commits ahead of `origin/main` | The candidate implementation is not integrated into the release branch |
| Pull request | No PR exists from the candidate branch to `main` | Review, required checks, and merge evidence do not exist |
| GitHub Actions | No workflow run exists for the candidate branch | CI is configured for pull requests and pushes to `main`; the local `make verify` result cannot substitute for GitHub-hosted evidence |
| Branch protection | GitHub reports `main` as unprotected | This conflicts with the development-process requirement that `main` reject direct and force pushes |
| Project license | GitHub reports no detected license and the repository contains no `LICENSE`/`COPYING` file | The PRD's MIT value remains an assumption, not owner approval |
| Distribution identity | No Developer ID Application identity is available; the candidate is ad-hoc signed and not notarized | It may only become an explicitly risk-accepted pre-release Beta, never a stable or Apple-verified release |
| Local artifact | `0.1.0-rc.7` passed the checksum, manifest, SPDX, exact-entitlement, Hardened Runtime, arm64, macOS 15.6 deployment-target, strict code-sign, and DMG checks | The bytes and disclosed trust boundary are inspectable; runtime/support gates remain open |

The retained rc.7 manifest binds its bytes to source commit `a3b8b45ca6f9dad752a9b750422b343d71c04dc8`. Later documentation commits do not invalidate that artifact, but the final downloadable DMG must be rebuilt from the exact `main` commit selected for the release. A tag or Release must never reuse rc.7 while claiming a different source commit.

## Required integration order

The release path is intentionally fail-closed:

1. **Owner decisions**
   - approve a concrete project license and add the matching repository metadata;
   - choose Developer ID signing/notarization, or record explicit maintainer acceptance of an ad-hoc, unnotarized Public Beta with no automatic updater;
   - review the still-Proposed release-relevant ADRs and record the accepted or deferred boundary.
2. **Pull request and CI**
   - open a PR from `agent/native-fsevents-integration` to `main`;
   - run the full GitHub `Verify` workflow from a full-history checkout;
   - resolve failures without bypassing privacy, migration-integrity, signing, or update checks;
   - perform the documented independent review or high-risk single-maintainer substitute.
3. **Protected integration**
   - enable branch protection for `main` before treating it as a release source;
   - require the repository verification check and prohibit force pushes/direct release mutations;
   - merge through the reviewed path and confirm the resulting `main` commit.
4. **Release-source rebuild**
   - check out the exact clean `main` commit intended for the tag;
   - rerun `make verify` and the release-only manual/real-machine qualifications;
   - build a new versioned DMG; do not rename or republish rc.7;
   - independently verify checksums, manifest source commit, SBOM, notices, signature truth, deployment target, architecture, mounted contents, and Gatekeeper/notarization state.
5. **Runtime and human qualification**
   - pass the P0 matrix on both macOS 15.6 and the then-current stable macOS on Apple Silicon;
   - complete a quarantined clean-account first launch and the exact per-app trust flow if the Beta remains ad-hoc;
   - complete fresh install, same-version overwrite, independently built replacement, bookmark restoration, denial, revocation, stale authorization, external-volume return, same-name/different-UUID, sleep/wake, event-gap, migration/recovery, retention, and clear-history rows;
   - complete keyboard, VoiceOver, Reduce Motion, Increase Contrast, usability, diagnostic-redaction, and offline/no-unsolicited-network review;
   - record the PRD KPI evidence, including at least six formative sessions and no repeated blocking issue.
6. **Release decision and publication**
   - confirm zero open Sev-0/Sev-1 defects and review all accepted exceptions;
   - create a signed `vX.Y.Z` tag that points to the qualified `main` commit and has passed the release workflow;
   - publish the DMG, manifest, checksum file, SPDX document, third-party notices, source/tag link, exact support matrix, installation instructions, and signing/notarization disclosure together;
   - download the published assets into a clean directory and re-run checksum, mounted-content, and installation verification before announcing availability.

## Current open gates

| Gate | Current evidence | Required closure |
|---|---|---|
| License | `licenseInfo = null`; no license file; SPDX uses `NOASSERTION` | Owner selects/approves the license; repository metadata, notices, and SPDX are regenerated consistently |
| Repository integration | Feature branch is 85 commits ahead; no PR or GitHub Actions run | Reviewed PR, green hosted CI, protected `main`, merge commit identified |
| Minimum OS | Deployment target is 15.6; current build host is newer | Physical or virtual macOS 15.6 P0 runtime matrix |
| Current stable OS | Current-host automated and signed-sandbox evidence exists | Repeat the release-source artifact matrix on the then-current stable macOS |
| Gatekeeper | Expected rejection of ad-hoc rc.7 is proven | Clean-account, quarantined DMG **Open Anyway** flow and post-trust launch |
| Replacement | rc.6/rc.7 process replacement passed under disposable identities | Packaged bookmark and database continuity across independently built release-source candidates |
| Permissions and volumes | Deterministic/native fixtures and earlier signed-sandbox smokes exist | Complete genuine packaged UI matrix for denial, revocation, stale grants, and volume identity changes |
| Accessibility and usability | Automated UI coverage exists | Manual VoiceOver/keyboard/visual-accessibility review plus at least six formative sessions |
| Governance | ADR-003, ADR-004, ADR-006, ADR-008, and ADR-009 remain Proposed | Maintainer review and explicit release disposition |
| Distribution policy | Ad-hoc warning/checksums are implemented | Developer ID/notarization, or recorded maintainer risk acceptance for a clearly labeled Public Beta |

## Prohibited shortcuts

- Do not create a tag from the feature branch or from an unverified local commit.
- Do not publish rc.7 after merging while presenting it as built from the merge result.
- Do not label an ad-hoc/unnotarized build as stable, verified by Apple, or frictionless to install.
- Do not add MIT or any other license merely because the PRD lists it as an assumption.
- Do not disable Gatekeeper globally, strip quarantine recursively, or automate the user's trust decision.
- Do not interpret deployment-target metadata or newer-host tests as macOS 15.6 runtime qualification.
- Do not weaken privacy, corruption-recovery, or release checks to make the status appear green.

## Decision record required from the maintainer

Before the next release-producing step, the maintainer must record:

1. the approved project license;
2. authorization to open the integration PR and the intended reviewer/exception path;
3. whether the next public artifact will wait for Developer ID/notarization or proceed as an explicitly risk-accepted ad-hoc Public Beta;
4. the machines or virtual machines that will provide macOS 15.6 and clean-account evidence;
5. who owns the final manual accessibility, usability, and publication verification.

Until those decisions and external qualifications are complete, the correct release decision remains **NO-GO**, even though a locally inspectable DMG exists.
