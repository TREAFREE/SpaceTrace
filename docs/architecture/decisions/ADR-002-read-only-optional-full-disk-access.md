# ADR-002: Read-only operation with optional Full Disk Access

## Status

Proposed

Date: 2026-07-18

## Context

SpaceTrace is valuable only if users trust it near sensitive filesystem metadata. macOS protects some folders through Transparency, Consent, and Control (TCC). Ordinary user access can provide meaningful home-directory coverage, while Full Disk Access (FDA) improves visibility into protected locations. FDA also increases the impact of any vulnerability and can create a coercive onboarding experience.

The App Sandbox is a strong defense but is designed around container and user-selected access. A product that observes changes across broad local scopes cannot make whole-volume coverage a P0 feature while relying solely on sandbox extensions. Conversely, requiring FDA at launch would contradict the local-first, least-privilege product promise.

There is no requirement to modify or clean data. Automatic deletion, snapshot thinning, process termination, TCC modification, and privileged mutation are explicitly outside MVP.

## Decision

1. SpaceTrace is **read-only with respect to user and system data**. It reads metadata, writes only its own Application Support/cache/log/update/export locations, and never modifies observed items.
2. FDA remains an optional coverage enhancement. Standard mode must produce useful findings from locations readable by the logged-in user.
3. The directly distributed application is proposed to run without App Sandbox so it can observe ordinary user-readable scopes consistently. It uses Developer ID signing, Hardened Runtime, notarization, library validation, and the smallest possible entitlement set.
4. The app never requests root, installs a privileged helper, modifies TCC, uses a private permission API, or attempts to automate the FDA grant.
5. Access is determined from actual operation results (`EACCES`, `EPERM`, missing metadata, and successful sentinel observations), not from an asserted global “FDA enabled” boolean. UI language calls this coverage evidence.
6. A denial or revocation produces partial/stale coverage. Unknown values never become zero, and inaccessible children never become deletions.
7. FDA education is contextual and dismissible. The user sees what additional categories may become visible, what the security trade-off is, and how to revoke access.
8. Export of full paths is separate from scan access and requires explicit user action; default export is redacted.

## Options considered

| Option | Benefits | Costs / failure modes | Assessment |
| --- | --- | --- | --- |
| Optional FDA, useful standard mode | Least coercive; progressive trust; broader adoption; graceful revocation | Coverage varies and UI must communicate uncertainty | Selected |
| Mandatory FDA on first launch | Simple support model; broadest potential coverage | High trust barrier; larger security blast radius; app becomes unusable when declined | Rejected |
| App Sandbox plus only user-selected folders | Strong process containment; possible Mac App Store path | Cannot deliver broad automatic coverage; repeated selections/bookmark failures; different product | Rejected for current product, possible limited edition later |
| Root LaunchDaemon/privileged helper | Broad access and independent lifecycle | Severe signing/security/update complexity; contradicts least privilege | Rejected |
| Modify/read TCC databases to infer permission | Potentially detailed state | Private/brittle behavior, SIP and trust risk | Rejected |
| Automatic cleanup after diagnosis | Immediate space recovery | Data-loss risk and radically different threat model | Explicitly out of scope |

## Consequences

### Positive

- Users can evaluate value before granting powerful access.
- Permission loss is a normal modeled state rather than an exceptional crash path.
- Read-only behavior sharply limits user-data damage from defects.
- Direct distribution can support broad user-readable scanning without pretending sandbox bookmarks equal whole-disk access.

### Negative and accepted trade-offs

- An unsandboxed app with FDA has a larger potential blast radius than a sandboxed app.
- Findings from two users can have different coverage; support and UI must expose this clearly.
- SpaceTrace cannot authoritatively query a global FDA status and must test effective access carefully.
- Mac App Store distribution may not support the intended experience.

### Guardrails

- No filesystem adapter exposes delete, move, write, chmod, chown, kill, snapshot-thin, or TCC-mutation operations.
- CI performs an entitlement diff and fails on new sensitive entitlements without ADR review.
- Security review covers any new file-content parsing; MVP reads metadata only.
- FDA-specific tests verify mid-scan revocation and ensure no false deletion.
- The application support directory is excluded from scans and uses user-only file modes.
- No change may make FDA mandatory without an explicit PRD change, threat-model review, and superseding ADR.

## Validation plan

1. Run the complete MVP journey on a clean account without FDA and confirm at least the accepted standard-mode categories are useful.
2. Record a protected-tree denial and verify the UI shows partial coverage, not zero or deletion.
3. Grant FDA manually, rerun calibration, and verify coverage expands without a database reset.
4. Revoke FDA during enumeration and verify the scan cannot finalize affected parents as complete.
5. Inspect the release entitlement set, Hardened Runtime, notarization, and Gatekeeper result on a clean Mac.
6. Static-test the filesystem port to ensure mutation operations do not exist in production modules.
7. Review redacted and full-path exports against the privacy specification.

## Revisit triggers

- Standard mode cannot satisfy the PRD's minimum useful experience after usability testing.
- Apple introduces a public, stable permission or scoped filesystem API that changes the trade-off.
- Mac App Store distribution becomes a product requirement.
- A P0 feature requires file-content access, a helper, root, or another sensitive entitlement.
- A security incident or external audit demonstrates that unsandboxed operation is unacceptable.
- FDA becomes mandatory in practice through product copy or feature gating, even if not technically enforced.
