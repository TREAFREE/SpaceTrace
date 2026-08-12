# Immutable, Coverage-Aware Historical Findings

Status: production complete-scan → paired SQLite v11 → projector path implemented; release qualification incomplete

Last reviewed: 2026-08-13

Chinese companion translation: [immutable-historical-findings.zh-CN.md](immutable-historical-findings.zh-CN.md).

Related decision: [ADR-006](../architecture/decisions/ADR-006-immutable-observations-and-findings.md)

## Purpose and current boundary

SpaceTrace can now compare two validated immutable directory observation frames and produce deterministic finding drafts for growth, decrease, appearance, disappearance, and a strictly proven move. It can also derive a positive-growth ranking without counting the same parent/child flow twice.

The pure projection is now backed by a production complete-scan path. The scanner emits directory-only logical/allocated measurements, complete direct-child coverage, frozen versioned classification, and APFS object-number/birth-time evidence from the same traversal. Before a later frame is committed, a pure Application reconciler adds only topmost absent endpoints previously observed as complete when their unchanged current direct parent has complete measurement and direct-child enumeration. Apple states that APFS does not support directory hard links, so those APFS directory objects can carry unique link-set evidence; unsupported filesystems remain path-based and move-ineligible. One SQLite transaction then publishes current truth plus paired v11 frames and registers projection work; the projector drains after commit and resumes at launch. Real Foundation integration proves growth, same-volume move, and disappearance. The Overview now reads bounded current-effective and immutable audit records, separates evidence-invalidated entries, preserves frozen classification evidence, exposes History Off/baseline-unavailable states, and labels the exact metric, complete evidence, and observation range. The menu bar remains the separate bounded 24-hour volume status defined by FR-009. This does not make legacy hourly/daily history audit-grade. Replacement/supersession, classification-corpus expansion and independent review, explicit user-controlled export/redaction evidence, manual assistive-technology review, and real macOS 15.6 qualification remain release blockers.

The link-set policy follows Apple's [APFS compatibility guide](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/APFS_Guide/FAQ/FAQ.html), and a controlled APFS disk-image test verifies that rename preserves stable object identity while a Foundation directory-link attempt never shares that identity. Directory `st_nlink` is not used as uniqueness proof.

FSEvents remains an invalidation hint. No event flag, filename, timestamp, or pair of opposite byte deltas can create a finding by itself.

## Ownership across the three model layers

| Layer | Owns | Deliberately does not own |
| --- | --- | --- |
| Domain endpoint | One node at one commit sequence; scope, volume, mount generation, coverage epoch, subject identity and basis, opaque location, metric, semantics versions, observation time, and explicit `present`/`absent`/`unknown` state | Path text, tree topology, classification, move proof across a frame, or ranking |
| Application observation frame | One canonical rooted directory tree; paths and display names; direct-parent topology; direct-child enumeration coverage; frozen classification; optional stable-object qualification | Durable SQLite identity, supersession, UI wording, or cleanup policy |
| Application projection result | Deterministic finding drafts from two frames—kind, endpoint IDs, frozen explanation evidence, inclusive delta, optional non-overlapping ranking contribution, and algorithm/ranking versions—plus stable ranked keys and a typed suppression summary | Ownership of the authoritative endpoint rows, persistence lifetime, or permission to mutate user data |

The flow is one-way:

```text
immutable endpoints
      |
      v
validated baseline/comparison frames
      |
      v
pure endpoint comparison + frame-level proof
      |
      v
immutable finding drafts + stable ranked keys + suppression summary
```

A draft copies the sensitive explanation fields needed to present what was observed, but references the authoritative baseline and comparison observations by endpoint ID. It does not embed an authoritative frame ledger. The follow-on persistence transaction must resolve those IDs to immutable endpoint rows and owning frames; a draft with an orphan or cross-frame reference must never be committed.

## Frame admission and evidence states

`HistoricalFindingObservationFrame` admits only a non-empty, canonical rooted directory tree. Within one frame:

- endpoint, subject, opaque location, and binary path identities are unique;
- every node has the same scope, persistent volume, mount generation, coverage epoch, metric, path/measurement semantics, and commit sequence;
- every non-root node has an available direct parent at its actual component-wise parent path;
- directory metrics are logical or allocated bytes, never volume-available bytes;
- a present node has a frozen versioned classification decision;
- an absent or unknown node has no classification and has unknown direct-child coverage;
- endpoint measurement coverage and immediate-child enumeration coverage remain separate facts.

Commit sequence, not wall-clock time, establishes order. A comparison frame must have a strictly greater sequence. UTC observation times remain evidence for display and audit, but they may repeat or move backward after clock correction and are never a ranking key.

### Metric wording and limits

- `logical` is the aggregate of visible/apparent file lengths under the scanner's declared semantics. It is not physical disk use and can overstate sparse, cloned, placeholder, or multiply linked content.
- `allocated` is the aggregate of metadata-reported allocated blocks observable to the scanner, with only the scanner's documented within-run hard-link deduplication. It is not unique APFS ownership, exact clone attribution, snapshot consumption, purgeable capacity, or guaranteed reclaimable space.
- Directory finding frames reject `volumeAvailable`. Volume-wide available capacity and its reconciliation remain a separate model and must not be mixed into directory child-flow arithmetic.
- Snapshot-related observations and estimates are outside finding metric v1. If introduced later, the UI and accessibility value must distinguish an estimate programmatically and visually from measured bytes.

The future UI must keep the metric label and coverage caveat visible. Neither metric may be relabeled as Apple “System Data,” exact physical ownership, or “space you can safely reclaim.”

### Explicit absence is evidence, not a missing row

An `absent` endpoint contains a `ParentAbsenceReference`. Frame validation resolves that reference to the same frame and accepts it only when it identifies the node's complete, present, direct parent and that parent's immediate-child enumeration is complete.

This distinction prevents false deletion claims:

- complete parent enumeration plus an explicit absent endpoint may support an appearance/disappearance transition;
- a missing endpoint row is merely missing evidence;
- partial measurement, incomplete child enumeration, permission revocation, an unmounted volume, a new coverage epoch, or an `unknown` endpoint is never converted to zero or absence.

Expected evidence gaps are counted in the typed suppression summary. Corrupt immutable endpoint-ID reuse and checked-arithmetic overflow remain errors instead of being hidden as ordinary suppression.

## Finding semantics

| Finding | Required evidence | Meaning and wording limit |
| --- | --- | --- |
| `growth` | Same subject and location, compatible complete present endpoints, positive inclusive delta | More bytes were observed between two endpoints; it does not identify the creating process or exact event time |
| `decrease` | Same subject and location, compatible complete present endpoints, negative inclusive delta | Fewer bytes were observed; it is not proof of user deletion or reclaimable space |
| `appearance` | Explicit absent baseline and complete present comparison, with validated parent absence proof | The directory was absent in one complete observation and present in the later one |
| `disappearance` | Complete present baseline and explicit absent comparison, with validated parent absence proof | The directory was present in one complete observation and absent in the later one; it is not proof of who removed it |
| `move` | Two complete present endpoints plus every move-proof condition below | The same qualified filesystem object was observed at a different location on the same mounted volume generation |

An unchanged comparison emits no finding. Unknown, partial, incompatible, or unmatched evidence emits no causal finding. The first complete frame is descriptive only because it has no earlier immutable endpoint to compare.

Classification runs after byte compatibility. At each available endpoint, a classified decision freezes category, confidence, rule ID/version, catalog version, and path-free evidence code; no-match freezes its exact Unknown reason; ambiguity freezes the competing rule IDs in canonical order. A later catalog upgrade neither breaks measurement continuity nor silently reinterprets an earlier draft. The classifier contract is detailed in [Deterministic Storage Attribution](deterministic-attribution.md).

## Move proof and subtree collapse

A relocation candidate becomes `move` only when all of these conditions hold:

1. both endpoints are present, complete, and compatible;
2. the scope, persistent volume, mount generation, coverage epoch, metric, subject, and stable-object identity basis match;
3. source and destination opaque location IDs differ;
4. the same stable filesystem-object token is present on both sides;
5. the reuse guard matches: either a non-empty generation token, or nanosecond birth time together with node kind;
6. link status is explicitly `unique` in both frames, never `ambiguous` or `unknown`;
7. the source parent and destination parent are each present in both frames, covering all four logical parent corners (source/destination × baseline/comparison; two corners may resolve to the same parent), and every relevant parent has complete endpoint and direct-child coverage;
8. if a relevant parent itself moved, that parent move was already proven.

This policy favors precision over recall. Cross-volume or cross-mount changes are never moves. Missing stable identity, mismatched reuse guards, ambiguous links, incomplete parent evidence, path-only identity, or one unavailable side suppresses the move claim. SpaceTrace does not use content hashing and does not read file contents.

The watched root has no parent inside its frame, so it cannot satisfy the four-parent proof. Root replacement, remount, and external-volume return belong to the watched-scope, Disk Arbitration, and mount-generation lifecycle. They create a new baseline or an explicit evidence gap, not a root move finding.

When a proven ancestor moves, an unchanged descendant that keeps the same direct-parent relationship and binary relative suffix is an implicit facet of that ancestor move and is collapsed. A descendant with its own byte change becomes a growth/decrease draft whose movement context references the ancestor move. An independently reparented or renamed descendant is not silently consumed.

## Inclusive and non-overlapping contribution

For one compatible node and metric:

```text
inclusiveDelta(node) = comparison(node) - baseline(node)

childFlowDelta(node)
  = sum(comparison immediate-directory-child bytes)
  - sum(baseline immediate-directory-child bytes)

exclusiveDelta(node) = inclusiveDelta(node) - childFlowDelta(node)
```

All additions and subtractions are checked. Overflow fails generation. An exclusive contribution is available only when both direct-child lists are complete and every immediate child has a complete measurement (an explicit absent child contributes zero). SpaceTrace never subtracts a partial child set.

### Worked parent/child example

| Node | Baseline | Comparison | Inclusive delta | Child flow | Exclusive contribution |
| --- | ---: | ---: | ---: | ---: | ---: |
| Parent | 20 GiB | 25 GiB | +5 GiB | +5 GiB | 0 GiB |
| Immediate child | 8 GiB | 13 GiB | +5 GiB | 0 GiB | +5 GiB |

The positive ranking reports 5 GiB once through the child. It does not present the parent and child as 10 GiB of independent growth.

A top-level explicit appearance—one not already covered by an ancestor appearance—uses its positive inclusive delta once as the branch's non-overlapping contribution; unmatched descendants are collapsed under it. This is the appearance counterpart of exclusive contribution when no comparable baseline child endpoints exist.

Only `growth` and top-level `appearance` drafts with a positive non-overlapping contribution are eligible for the positive list. A move, disappearance, zero/negative contribution, or decrease is ineligible. Kind eligibility is checked independently from the sign: for example, if a parent decreases by 10 GiB while its children decrease by 30 GiB, the calculated exclusive value is +20 GiB, but the finding remains a `decrease` and must not enter positive-growth Top 10.

## Stable output and ranking order

Version 1 ranks eligible drafts by:

1. non-overlapping ranking bytes descending;
2. comparison commit sequence descending;
3. scope ID by raw UTF-8 bytes ascending;
4. reporting opaque location ID by raw UTF-8 bytes ascending;
5. structured finding key ascending.

The finding key is derived from algorithm version, ranking-policy version, both endpoint IDs, finding kind, and the frozen catalog versions. Binary UTF-8 comparison is intentional: case-distinct and canonically equivalent-but-byte-distinct filesystem names remain distinct. Localized paths, localized display names, classification wording, Swift `Hasher`, input order, SQLite row order, and wall-clock time cannot break a tie.

The retained finding array and suppression reason arrays are also canonicalized. The result records how many positive findings were truncated beyond the configured `1...100` limit.

## Fail-closed Codable v1 boundary

The current Codable surface is a strict version-1 durable interchange contract, not a permissive JSON ingestion API. `HistoricalFindingGenerationResult` is the complete top-level envelope; subordinate values are canonical components, not independent causal records. Decode and encode revalidate every invariant that can be derived from the payload itself. The implementation rejects, among other cases:

- unknown fields or unknown discriminants;
- explicit `null` where canonical form requires an absent optional key;
- contradictory present/absent/classification combinations;
- reused endpoint IDs, invalid paths, invalid topology, and any causal draft with non-increasing sequences; a non-increasing frame pair is accepted only as an empty batch with one typed frame-level suppression;
- keys that cannot be recomputed from their draft evidence;
- mismatched metrics, algorithm versions, ranking-policy versions, or catalog versions;
- duplicate or non-canonically ordered findings/reasons;
- ranked keys that are missing, ineligible, out of order, or beyond the limit;
- a suppression/truncation summary that contradicts the retained batch.

Path-free suppression/collapse counts deliberately do not copy every suppressed endpoint into the result. Their exact causal count therefore cannot be proven from the compact result alone. The v11 commit boundary must resolve both frame ledgers and recompute or referentially validate the complete projection before accepting it; merely decoding JSON is never authorization to persist a result.

This fail-closed rule prevents a future producer from smuggling silently ignored evidence into an immutable v1 payload. Future format evolution requires an explicit schema/version compatibility policy and migration; it must not rely on Swift's default behavior of ignoring unknown keyed fields.

## Privacy and product-language boundary

Raw paths, display names, opaque location IDs, stable object tokens, birth times used as reuse guards, timelines, and frozen classification decisions are Sensitive local data. Hashing does not make these fields safe for telemetry. They must not enter Release logs, analytics, evidence codes, crash titles, or default diagnostics. Tests and documentation use synthetic paths only.

The projection remains metadata-only and local. A finding explains two observations; it does not establish ownership, intent, process attribution, exact event time, recoverability, or safe deletion. In particular:

- “disappearance” must not be relabeled as “the user deleted this”;
- “decrease” must not be relabeled as “space you can reclaim”;
- a category is not a cleanup recommendation;
- no finding authorizes deletion, cleanup, quarantine, or any other mutation.

## Implemented production boundary and remaining gates

The existing schema-v10 hourly/daily read model cannot be retroactively treated as immutable finding evidence. The production pipeline now writes a first descriptive v11 baseline and registers deterministic work only after a later compatible complete frame. SQLite reloads the authoritative frames and regenerates the compact result before committing a projection.

The implemented boundary includes:

1. append-only paired logical/allocated frames, parent topology, both coverage dimensions, frozen classification, immutable commit sequences, and database-enforced endpoint/frame references;
2. atomic complete-scan finalization that publishes current truth and registers deterministic projection work, with History Off remaining path-history-free;
3. idempotent immediate and launch-time projection, evidence-invalidated retraction, ordered retention, released v10/v11 fixtures, typed recovery, and current-host 500,000/1,000,000-row gates.

The implemented production evidence boundary additionally includes:

1. topmost present-to-absent reconciliation against the immediately preceding logical frame, with unchanged-parent, complete-measurement, complete-direct-child, path/location, and prior-endpoint checks;
2. APFS-only stable subjects derived from volume identity, object number, and nanosecond birth time, with unique link status based on the platform filesystem invariant;
3. real temporary-directory growth/rename/delete projection and opt-in APFS image rename/remount/replacement qualification.

The remaining finding gates are:

1. add an approved replacement/supersession model; v11 supports evidence invalidation only and has no successor link;
2. complete manual keyboard, VoiceOver, contrast, larger-text, and uncertainty-language review of the implemented Overview on macOS 15.6 and current stable macOS;
3. expand the independently reviewed classification corpus to the FR-007 gate of at least 60 known cases while preserving Unknown/ambiguity evidence;
4. implement explicit user-controlled export with preview, cancellation, interruption recovery, path/token redaction tests, and no automatic upload, satisfying FR-014;
5. complete signed-sandbox restart/revocation/external-volume, clean quarantine, macOS 15.6, distribution-trust, and maintainer-acceptance gates.

Until those gates close, ADR-006 remains Proposed and this feature is not a Public Beta or GitHub Release readiness claim.

## Verification surface

The focused contract suite is:

```bash
swift test --package-path Packages/SpaceTraceKit --filter HistoricalFinding
```

Repository completion still requires strict-concurrency verification, `make verify`, `git diff --check`, and a privacy scan. Those checks cover the production paired-v11, explicit-disappearance, stable-APFS-move, and automated Overview slices but do not substitute for unfinished signed-sandbox/minimum-OS qualification, manual UI review, classification-corpus, export, or distribution gates above.
