# SpaceTrace Immutable Historical Findings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the immutable, coverage-aware comparison and finding projection contracts required to turn two trustworthy directory observation frames into explainable growth, decrease, appearance, disappearance, and determinable-move findings without parent/child double counting.

**Architecture:** `SpaceTraceDomain` owns immutable observation endpoints, explicit present/absent/unknown state, monotonic compatibility, and typed comparison outcomes. `SpaceTraceAttribution` owns a versioned classification decision wrapper. `SpaceTraceApplication` owns the directory tree projection, move-collapse policy, exclusive-contribution ranking, and immutable finding drafts. SQLite v11, production scanner identity, UI, retention, and supersession persistence are separate follow-on stages that consume these public seams.

**Tech Stack:** Swift 6 package tooling in Swift 5 language mode, Swift Testing, Codable value contracts, existing modular package and repository verification scripts.

## Global Constraints

- The minimum deployment target remains macOS 15.6.
- FSEvents is only an invalidation hint and can never create a byte finding by itself.
- The first baseline is descriptive; a causal finding requires two immutable endpoints with strictly increasing commit sequences.
- Unknown and partial evidence are not zero. They produce a typed incomparable/suppressed result, never a fabricated delta or deletion.
- Measurement compatibility includes scope, persistent volume identity, mount generation, coverage epoch, metric, path semantics, measurement semantics, subject identity, and monotonic ordering. It does not depend on the classifier catalog version.
- Absence is explicit evidence tied to a complete parent endpoint. A missing row alone is not deletion evidence.
- A move requires a stable filesystem-object identity, the same volume and mount generation, two present endpoints, different locations, and complete source/destination frames. Name, size, time proximity, and FSEvents rename flags are insufficient.
- Parent/child ranking uses exclusive contribution: parent inclusive delta minus the change in its immediate directory children. Confirmed moves and non-positive contributions never enter positive-growth Top 10.
- Finding drafts freeze source endpoint IDs, algorithm/ranking versions, catalog version, classified or Unknown state, exact rule ID/version/confidence/evidence, metric, coverage, and observation endpoint times.
- Raw paths, display names, opaque object identities, path keys, and finding timelines are Sensitive local data. They must not enter Release logs, evidence codes, or default diagnostics.
- Historical correction is append-only through a later `supersedesFindingID` persistence contract; this stage does not update or silently reinterpret an earlier finding.
- Current Public Beta and GitHub Release status remains NO-GO until persistence, UI, corpus, export, macOS 15.6, accessibility, signing/notarization or explicit risk acceptance, and packaging gates close.
- Each implementation slice follows red-green, fresh focused verification, architecture verification, `make verify`, `git diff --check`, a scoped Chinese commit, and push.

---

## File Structure

- `docs/architecture/decisions/ADR-006-immutable-observations-and-findings.md`: English decision for endpoint immutability, compatibility, explicit absence, move proof, ranking, and supersession.
- `docs/architecture/decisions/ADR-006-immutable-observations-and-findings.zh-CN.md`: complete Chinese companion.
- `Packages/SpaceTraceKit/Sources/SpaceTraceDomain/ObservationEndpoint.swift`: durable endpoint identity, compatibility context, presence state, and validation.
- `Packages/SpaceTraceKit/Sources/SpaceTraceDomain/StorageChange.swift`: pure endpoint comparator and typed comparable/incomparable results.
- `Packages/SpaceTraceKit/Sources/SpaceTraceAttribution/VersionedAttributionDecision.swift`: catalog-versioned classified/Unknown result.
- `Packages/SpaceTraceKit/Sources/SpaceTraceApplication/History/HistoricalFinding.swift`: immutable finding draft, evidence endpoints, change kind, algorithm versions, and rank contribution.
- `Packages/SpaceTraceKit/Sources/SpaceTraceApplication/History/HistoricalFindingGenerator.swift`: validated observation-frame comparison, move collapse, exclusive contribution, suppression summary, and stable Top 10.
- Mirrored tests under `Packages/SpaceTraceKit/Tests/*Tests/` verify only these public seams.

### Task 1: Record the Architecture Decision Before Schema Work

**Files:**
- Create: `docs/architecture/decisions/ADR-006-immutable-observations-and-findings.md`
- Create: `docs/architecture/decisions/ADR-006-immutable-observations-and-findings.zh-CN.md`
- Modify: `docs/architecture/decisions/README.md`
- Modify: `docs/architecture/technical-architecture.md`

**Interfaces:**
- Produces a Proposed ADR whose implementation contract separates measurement compatibility from classification, defines explicit absence and move proof, fixes exclusive ranking and binary tie order, and requires append-only supersession.
- Corrects the architecture text that currently treats classifier schema as a byte-measurement compatibility key.

- [x] **Step 1: Add the English and Chinese ADR with concrete invariants**

The ADR must define the exact compatibility tuple, endpoint state machine, move proof, `exclusiveDelta = inclusiveDelta - childFlowDelta`, stable sorting keys, path sensitivity, and the next SQLite v11 obligations. It must explicitly reject rename-by-heuristic and in-place finding rewrite.

- [x] **Step 2: Reconcile the architecture overview and ADR index**

Replace “classifier schema” in measurement compatibility with path and measurement semantics. State that classification is frozen after a compatible change is produced and that a catalog upgrade does not cut byte-measurement continuity.

- [x] **Step 3: Verify documentation consistency**

Run:

```bash
rg -n "classifier schema|explicit absence|exclusive|supersed|stable.*identity" docs/architecture docs/product
git diff --check
```

Commit: `确立不可变观测与历史发现架构`

### Task 2: Add Immutable Endpoint and Comparison Domain Contracts

**Files:**
- Create: `Packages/SpaceTraceKit/Sources/SpaceTraceDomain/ObservationEndpoint.swift`
- Create: `Packages/SpaceTraceKit/Sources/SpaceTraceDomain/StorageChange.swift`
- Create: `Packages/SpaceTraceKit/Tests/SpaceTraceDomainTests/ObservationEndpointTests.swift`
- Create: `Packages/SpaceTraceKit/Tests/SpaceTraceDomainTests/StorageChangeTests.swift`

**Interfaces:**
- Produces `ObservationEndpointID`, `ObservationCommitSequence`, `ObservationSemanticsVersion`, `ObservationVolumeID`, `ObservationMountGenerationID`, `ObservationCoverageEpochID`, `ObservationLocationID`, `ObservationSubjectIdentityBasis`, `ParentAbsenceReference`, `ObservationEndpointState`, and `ObservationEndpoint`.
- Produces `StorageChangeKind`, `StorageChange`, `ObservationIncomparability`, `ObservationComparisonCorruption`, `ObservationComparisonOutcome`, and `ObservationEndpoint.compare(from:)`.

The public comparison seam is:

```swift
public extension ObservationEndpoint {
    func compare(from baseline: ObservationEndpoint) -> ObservationComparisonOutcome
}

public enum ObservationComparisonOutcome: Sendable, Equatable {
    case comparable(StorageChange)
    case incomparable(ObservationIncomparability)
    case corrupt(ObservationComparisonCorruption)
}
```

- [x] **Step 1: Write a failing endpoint-validation test**

Test stable-code validation, positive sequence/version validation, present/partial/unknown byte invariants, explicit absence parent evidence, and Codable revalidation through the public initializers.

- [x] **Step 2: Run the endpoint tests and confirm RED**

Run: `swift test --package-path Packages/SpaceTraceKit --filter ObservationEndpointTests`

Expected: FAIL because the endpoint contract does not exist.

- [x] **Step 3: Implement the smallest immutable endpoint contract**

Use value types only and no Foundation import. `unknown` carries no bytes; `absent` carries an unresolved parent endpoint reference; partial present bytes remain measurable but incomparable. Reject self-referential absence, but defer same-frame complete-direct-parent validation to Task 4.

- [x] **Step 4: Write one failing comparison behavior at a time**

Cover complete growth/decrease/unchanged, appearance/disappearance candidates, stable-identity relocation candidates, path-identity location change rejection, scope/volume/mount/coverage-epoch/metric/path-semantics/measurement-semantics mismatch, endpoint-ID reuse, partial/unknown endpoints, non-increasing sequence, wall-clock rollback with increasing sequence, and malicious Codable payloads.

- [x] **Step 5: Implement typed comparison without throwing for expected evidence gaps**

`StorageChange` retains both endpoint IDs, both locations, optional endpoint bytes, signed inclusive delta, metric, commit sequences, and wall-clock instants. Candidate names prevent unvalidated parent or identity evidence from becoming a causal claim. Centralized Codable revalidation rejects corrupt construction; evidence insufficiency returns `.incomparable`, while immutable endpoint-ID reuse returns distinct `.corrupt` evidence before compatibility checks.

- [x] **Step 6: Verify and commit**

Run:

```bash
swift test --package-path Packages/SpaceTraceKit --filter ObservationEndpointTests
swift test --package-path Packages/SpaceTraceKit --filter StorageChangeTests
swift test --package-path Packages/SpaceTraceKit -Xswiftc -strict-concurrency=complete
make verify
git diff --check
```

Commit: `建立不可变观测端点与比较契约`

### Task 3: Freeze Versioned Classification Decisions

**Files:**
- Modify: `Packages/SpaceTraceKit/Sources/SpaceTraceDomain/Attribution.swift`
- Modify: `Packages/SpaceTraceKit/Sources/SpaceTraceAttribution/AttributionRule.swift`
- Modify: `Packages/SpaceTraceKit/Sources/SpaceTraceAttribution/DeterministicAttributionClassifier.swift`
- Modify: `Packages/SpaceTraceKit/Sources/SpaceTraceAttribution/BuiltInAttributionCatalog.swift`
- Create: `Packages/SpaceTraceKit/Sources/SpaceTraceAttribution/VersionedAttributionDecision.swift`
- Modify: `Packages/SpaceTraceKit/Tests/SpaceTraceDomainTests/AttributionTests.swift`
- Modify: `Packages/SpaceTraceKit/Tests/SpaceTraceAttributionTests/*.swift`

**Interfaces:**
- Produces a distinct positive `AttributionCatalogVersion`; rule and catalog versions can evolve independently.
- Produces `VersionedAttributionDecision(catalogVersion:result:)` and `DeterministicAttributionClassifier.classifyVersioned(_:)`.
- `AttributionClassificationResult` and `AttributionUnknownReason` become Codable so persistence can freeze classified, no-match, and ambiguous decisions without inventing a category.

- [x] **Step 1: Write failing catalog/decision durability tests**

Verify invalid catalog versions, classified round trip, no-match round trip, sorted ambiguous rule IDs, and preservation of both catalog and winning rule version.

- [x] **Step 2: Confirm RED with focused attribution tests**

Run: `swift test --package-path Packages/SpaceTraceKit --filter AttributionTests` and `swift test --package-path Packages/SpaceTraceKit --filter VersionedAttributionDecisionTests`.

- [x] **Step 3: Implement distinct catalog identity and versioned decisions**

Keep the existing `classify(_:)` source-compatible. `classifyVersioned(_:)` wraps that exact deterministic result with `catalog.version`; it performs no second classification and never logs input paths.

- [x] **Step 4: Verify all attribution fixtures and commit**

Run:

```bash
swift test --package-path Packages/SpaceTraceKit --filter SpaceTraceAttributionTests
make verify
git diff --check
```

Commit: `冻结历史分类决策及目录版本`

### Task 4: Generate Immutable Findings and Non-Overlapping Rankings

**Files:**
- Modify: `Packages/SpaceTraceKit/Package.swift`
- Create: `Packages/SpaceTraceKit/Sources/SpaceTraceApplication/History/HistoricalFinding.swift`
- Create: `Packages/SpaceTraceKit/Sources/SpaceTraceApplication/History/HistoricalFindingGenerator.swift`
- Create: `Packages/SpaceTraceKit/Tests/SpaceTraceApplicationTests/HistoricalFindingModelTests.swift`
- Create: `Packages/SpaceTraceKit/Tests/SpaceTraceApplicationTests/HistoricalFindingGeneratorTests.swift`

**Interfaces:**
- `SpaceTraceApplication` gains the one-way dependency on `SpaceTraceAttribution` already described by the architecture.
- Produces `HistoricalFindingObservationFrame`, `HistoricalFindingNode`, `HistoricalFindingDraft`, `HistoricalFindingKind`, `HistoricalFindingEvidence`, `HistoricalFindingBatch`, `HistoricalFindingSuppressionSummary`, and `HistoricalFindingGenerator`.

The public TDD seam is:

```swift
public struct HistoricalFindingGenerator: Sendable {
    public func generate(
        baseline: HistoricalFindingObservationFrame,
        comparison: HistoricalFindingObservationFrame,
        positiveLimit: Int = 10
    ) throws -> HistoricalFindingGenerationResult
}
```

- [ ] **Step 1: Write failing frame/model validation tests**

Reject empty frames, duplicate subject/endpoint/location identities, nodes outside the root, missing/cyclic parents, inconsistent scope/sequence context, present nodes without classification, absent nodes whose proof does not reference a complete parent in the same frame, invalid display names, and limits outside `1...100`.

- [ ] **Step 2: Implement only the validated public models**

Paths and display names stay in Application. Domain remains path-text independent. Finding evidence stores both endpoint IDs, both catalog decisions when present, algorithm version `1`, ranking policy version `1`, and complete coverage.

- [ ] **Step 3: Add red-green vertical slices for each finding behavior**

Add and pass, in order:

1. two complete same-location endpoints produce growth/decrease while an unchanged pair produces no finding;
2. explicit absent→present and present→absent produce appearance/disappearance; a missing counterpart or unknown/partial endpoint is suppressed;
3. stable identity plus changed location produces one move, while path identity, cross mount, or incomplete proof cannot;
4. a moved parent consumes implicit descendant moves, and a confirmed move never also becomes source disappearance/destination appearance;
5. parent `inclusiveDelta` minus immediate-child flow produces `rankingContribution`, so a 5 GiB child change is never reported as 10 GiB across parent and child;
6. moved, zero, and negative drafts are excluded from ranked positives;
7. more than ten positives return ten by bytes descending, comparison sequence descending, scope ID binary ascending, reporting location ID binary ascending, then deterministic finding key;
8. rule/catalog upgrades do not make measurements incomparable, while each draft freezes the exact endpoint classification decision.

- [ ] **Step 4: Add adversarial/property-style cases**

Cover opposite parent/child deltas, child reparenting, integer boundaries, duplicate stable identity, Unicode/case-distinct paths, wall-clock rollback, missing child frame evidence, and input-order permutations producing byte-for-byte equal output.

- [ ] **Step 5: Verify and commit**

Run:

```bash
swift test --package-path Packages/SpaceTraceKit --filter HistoricalFinding
swift test --package-path Packages/SpaceTraceKit -Xswiftc -strict-concurrency=complete
make verify
git diff --check
```

Commit: `实现覆盖感知的历史发现与非重叠排名`

### Task 5: Document the Proven Boundary and Plan SQLite v11

**Files:**
- Create: `docs/engineering/immutable-historical-findings.md`
- Create: `docs/engineering/immutable-historical-findings.zh-CN.md`
- Modify: `docs/README.md`
- Modify: `docs/engineering/directory-history-overview.md`
- Modify: `docs/engineering/directory-history-overview.zh-CN.md`
- Modify: `docs/engineering/deterministic-attribution.md`
- Modify: `docs/engineering/deterministic-attribution.zh-CN.md`
- Modify: `docs/engineering/implementation-status.md`
- Modify: `docs/engineering/implementation-status.zh-CN.md`
- Modify: `docs/product/product-roadmap.md`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Documents exact finding semantics, time/metric wording, move proof, Unknown behavior, exclusive ranking, sensitive fields, and stable tie order.
- Records that production endpoint persistence, scanner directory identity, append-only supersession, SQLite v11 golden fixtures, retention, Overview/menu-bar UI, corpus expansion, export, and real macOS 15.6 qualification remain release blocking.

- [ ] **Step 1: Write matching English and Chinese engineering guides**

Include worked parent/child and move examples. Explicitly state that an observed disappearance is not proof of user deletion and no finding is a cleanup recommendation.

- [ ] **Step 2: Reconcile status without overstating completion**

Mark only the pure endpoint/finding projection as implemented. Keep current Public Beta/GitHub Release NO-GO and enumerate the next persistence stage: append-only observation frames, opaque stable identity evidence, explicit absence rows, projection checkpoint, immutable finding/supersession tables, schema-v11 migration/golden fixtures, and crash-idempotence.

- [ ] **Step 3: Run final phase verification and privacy review**

Run:

```bash
swift test --package-path Packages/SpaceTraceKit --filter HistoricalFinding
swift test --package-path Packages/SpaceTraceKit --filter SpaceTraceAttributionTests
make verify
git diff --check
rg -n "/Users/|mayue|2261996970@qq.com" Packages/SpaceTraceKit docs --glob '!docs/research/**'
```

Review every changed requirement/status statement and every fixture for real paths, usernames, secrets, or release claims.

Commit: `完成不可变历史发现文档与阶段收口`

## Self-Review

- Spec coverage: two-endpoint causality, explicit absence, Unknown-not-zero, complete-parent deletion, stable-identity move, non-overlapping Top 10, deterministic ties, metric/coverage/time fields, source endpoint references, versioned classification, and historical immutability each have an owned task.
- Placeholder audit: every source, test, document, public seam, focused command, commit boundary, and follow-on boundary is named; no step asks an implementer to invent an unspecified error policy.
- Type consistency: Domain comparison is classifier-independent; Application drafts freeze `VersionedAttributionDecision`; raw path/display text never enters Domain evidence or attribution evidence codes.
- Correction consistency: this stage creates immutable drafts only. The next SQLite plan must assign durable IDs and append `supersedesFindingID`; it must never UPDATE historical wording.
- Privacy consistency: opaque file identities and path keys remain Sensitive even when hashed. Tests use synthetic `/Fixtures/...` paths only, and logging/export remain out of scope.
- Scope boundary: production scanner identity, immutable endpoint ledger, SQLite v11, crash recovery, persistence benchmark, UI, retention, export, and release publication are intentionally not claimed by this plan.
