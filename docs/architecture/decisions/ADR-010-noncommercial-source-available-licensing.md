# ADR-010: Noncommercial source-available licensing and contributor rights

## Status

Accepted

Date: 2026-08-14

Chinese companion translation: [ADR-010-noncommercial-source-available-licensing.zh-CN.md](ADR-010-noncommercial-source-available-licensing.zh-CN.md). This English document is the product and engineering source of truth. It records the maintainer's licensing decision, but it is not legal advice and does not replace the controlling license or contributor agreement.

## Context

SpaceTrace publishes its source and accepts pull requests, but the maintainer does not authorize ordinary recipients to use SpaceTrace or modified versions commercially. MIT was therefore rejected. Leaving the repository without a license would not meet the desired collaboration model: recipients could view and fork the public repository through GitHub, but they would not receive a clear general right to use, change, and share the code.

The maintainer also wants to preserve the option to commercialize SpaceTrace later. A public noncommercial license does not by itself give the maintainer commercial relicensing rights to copyright owned by an external contributor. The repository therefore needs two separate grants: a public noncommercial license for recipients and a contributor agreement that grants the Project Owner additional rights while leaving contributor ownership intact.

## Decision

1. SpaceTrace is distributed under the unmodified official [PolyForm Noncommercial License 1.0.0](../../../LICENSE.md), SPDX identifier `PolyForm-Noncommercial-1.0.0`.
2. The public license permits noncommercial use, modification, and distribution. It does not license commercial use by ordinary recipients. Fair-use and other rights arising directly under law are unaffected.
3. SpaceTrace describes itself as **source-available**, not “open source” in the OSI sense, because the commercial-use restriction does not satisfy the Open Source Definition.
4. The release toolchain freezes the official license text by SHA-256 and emits the exact SPDX identifier in both `licenseDeclared` and `licenseConcluded`. The DMG installation notice and third-party notices disclose the noncommercial boundary and the official license URL.
5. Pull requests are welcome, but no external Contribution may be merged unless every contributor affirmatively accepts the versioned [SpaceTrace Contributor License Agreement](../../../CONTRIBUTOR_LICENSE_AGREEMENT.md).
6. Contributors retain copyright ownership. The CLA gives the Project Owner a separate worldwide, non-exclusive, perpetual, irrevocable, royalty-free copyright and patent grant, including sublicensing and commercial/proprietary distribution rights. It does not expand the public recipient's PolyForm rights.
7. The Project Owner is identified for the current contribution workflow as the person or legal entity controlling the GitHub account `TREAFREE` and owning `TREAFREE/SpaceTrace`. Before a material commercial transaction, that legal person or entity must be identified consistently in contracts and Project records and should obtain jurisdiction-specific legal review.
8. No Contributor License Agreement is inferred from discussion alone. Acceptance requires the affirmative CLA checkbox and submission recorded in the pull request. Maintainers must preserve that record and must not merge a contribution whose author lacks authority or rejects the CLA.
9. Third-party code remains governed by its own license. It may be incorporated only after compatibility, notice, provenance, and SBOM review; the SpaceTrace CLA cannot cure incompatible third-party rights.

## Options considered

| Option | Benefits | Costs / failure modes | Assessment |
| --- | --- | --- | --- |
| PolyForm Noncommercial 1.0.0 plus CLA | Clear noncommercial collaboration; preserves maintainer commercial option; contributor retains ownership | Not OSI open source; CLA adds contribution friction and needs legal review | Selected |
| MIT | Familiar and OSI-approved; minimal contribution friction | Permits anyone to commercialize modified copies, contrary to the owner decision | Rejected |
| No license | No accidental broad grant | Does not clearly permit noncommercial use, modification, or sharing; unsuitable for the requested collaboration model | Rejected |
| PolyForm Noncommercial without CLA | Clear public restriction; simple repository policy | External contributions cannot safely be relicensed commercially without later individual permission or rewrite | Rejected |
| Copyright assignment | Strongest centralized commercial control | Transfers contributor ownership and creates substantially greater legal and community friction | Rejected |

## Consequences

### Positive

- Noncommercial users can use, modify, and share SpaceTrace under explicit terms.
- Ordinary recipients cannot rely on the Project license for commercial use.
- The maintainer can commercialize solely owned code and, after valid CLA acceptance, accepted external Contributions.
- SPDX, notices, README, PR workflow, and release verification share one machine-tested identifier.

### Negative and accepted trade-offs

- SpaceTrace cannot accurately market itself as OSI-approved open source.
- Some contributors may decline the CLA, and their work cannot be merged.
- A checkbox and repository-defined owner are practical evidence, not a substitute for jurisdiction-specific legal advice or a legally named commercial counterparty.
- A future license change for externally contributed code is limited by the exact rights validly granted by each contributor.

### Guardrails

- Never edit the official license text to add project-specific clauses; place operational explanations in README, notices, this ADR, or the CLA.
- Never describe PolyForm as permitting commercial use, sublicensing by ordinary recipients, or OSI open-source use.
- Never represent a submitted PR as CLA-covered unless the affirmative acceptance is retained with the GitHub contribution record.
- Do not accept copied third-party code merely because its submitter checked the CLA.
- Any CLA identity, scope, or acceptance-flow change requires legal and maintainer review plus updated automated contracts.

## Validation plan

1. Verify `LICENSE.md` byte-for-byte through the frozen official SHA-256.
2. Verify README, CONTRIBUTING, the PR template, SPDX, notices, DMG instructions, and release-readiness inputs use the exact approved identifier and do not retain MIT/`NOASSERTION` status claims.
3. Run the contribution-licensing contract to prove contributor ownership, Project Owner commercial rights, public-recipient restriction, and affirmative PR acceptance remain present.
4. Run packaging tests and inspect the mounted read-only DMG for the exact license notice and official URL.
5. Before merging an external PR, verify every commit author has accepted the same CLA version and preserve the pull-request record.
6. Before commercial distribution containing external Contributions, obtain legal review of contributor acceptance records and the Project Owner's legal identity.

## Revisit triggers

- The Project Owner changes legal identity, repository ownership, or commercial distribution entity.
- SpaceTrace adopts an OSI-approved license, a different source-available license, a paid commercial license, or an app-store distribution agreement.
- A contributor challenges CLA validity or lacks authority to make the grant.
- The Project begins accepting organization-owned Contributions at material scale.
- A jurisdiction-specific review requires a governing-law, signature, privacy, or record-retention change.
