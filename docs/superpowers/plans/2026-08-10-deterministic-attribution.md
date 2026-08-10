# SpaceTrace Deterministic Attribution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a conservative, offline, deterministic attribution engine that maps normalized storage paths and explicit volume context to versioned, explainable categories while preserving Unknown for unsupported or conflicting evidence.

**Architecture:** Introduce a platform-independent `SpaceTraceAttribution` target that depends only on `SpaceTraceDomain`. Domain owns the durable attribution value contract; the attribution target owns lexical path normalization, validated rule catalogs, deterministic precedence, ambiguity handling, built-in P0 rules, and fixture evaluation. The engine performs no filesystem I/O, reads no file contents, does not inspect processes, and returns evidence codes rather than user paths.

**Tech Stack:** Swift 6 package tooling in Swift 5 language mode, Swift Testing, `Codable` JSON fixtures, existing architecture boundary and verification scripts.

## Global Constraints

- Classification must be deterministic for the same normalized input and catalog version.
- Unknown and ambiguous are first-class outcomes; the engine must never force a category.
- Rules operate on exact path-component boundaries or explicit context, never substring guesses.
- Renamed home directories must not change home-relative classifications.
- Evidence stored in an attribution must be stable, path-free, and tied to a rule ID and rule version.
- Generic cache/log rules must never outrank a more specific product rule.
- Snapshot attribution requires an explicit platform observation; a path name alone is insufficient.
- No filesystem I/O, file-content inspection, process inspection, network access, shell command, SwiftUI, AppKit, or persistence dependency is allowed in `SpaceTraceAttribution`.
- The initial fixture corpus is a regression and precision foundation. It must not be represented as user-research evidence or real-world macOS 15.6 qualification.
- Each task follows red-green-refactor, ends with fresh focused verification, `make verify`, documentation updates, and a scoped Chinese commit.

---

## File Structure

- `Packages/SpaceTraceKit/Sources/SpaceTraceDomain/Attribution.swift`: durable attribution category, confidence, identity, evidence, and successful value invariants.
- `Packages/SpaceTraceKit/Sources/SpaceTraceAttribution/AttributionInput.swift`: lexical absolute/home-relative path features and explicit non-path context.
- `Packages/SpaceTraceKit/Sources/SpaceTraceAttribution/AttributionRule.swift`: validated versioned rule and catalog contracts.
- `Packages/SpaceTraceKit/Sources/SpaceTraceAttribution/DeterministicAttributionClassifier.swift`: matching, precedence, Unknown, and ambiguity resolution.
- `Packages/SpaceTraceKit/Sources/SpaceTraceAttribution/BuiltInAttributionCatalog.swift`: reviewed P0 built-in rules.
- `Packages/SpaceTraceKit/Sources/SpaceTraceAttribution/AttributionFixtureEvaluator.swift`: fixture metrics without hidden thresholds.
- `Packages/SpaceTraceKit/Tests/SpaceTraceDomainTests/AttributionTests.swift`: durable-value validation and Codable behavior.
- `Packages/SpaceTraceKit/Tests/SpaceTraceAttributionTests/*.swift`: normalization, catalog validation, precedence, ambiguity, and corpus metrics.
- `Packages/SpaceTraceKit/Tests/SpaceTraceAttributionTests/Fixtures/attribution-fixtures-v1.json`: versioned positive, negative, ambiguity, renamed-home, cloud, and snapshot cases.
- `docs/engineering/deterministic-attribution*.md`: English and Chinese rule/evidence/privacy/extension guide.

### Task 1: Establish Durable Attribution Contracts

**Files:**
- Modify: `Packages/SpaceTraceKit/Package.swift`
- Create: `Packages/SpaceTraceKit/Sources/SpaceTraceDomain/Attribution.swift`
- Create: `Packages/SpaceTraceKit/Tests/SpaceTraceDomainTests/AttributionTests.swift`

**Interfaces:**
- Produces `StorageAttributionCategory`, `AttributionConfidence`, `AttributionRuleID`, `AttributionRuleVersion`, `AttributionEvidenceCode`, and `StorageAttribution`.
- A successful attribution always contains a non-empty stable rule ID/evidence code, a positive rule version, and a non-Unknown confidence.

- [x] **Step 1: Write failing domain-contract tests**

Cover all category raw values, invalid blank IDs/evidence, non-positive rule versions, durable Codable round trips, and decoding rejection for invalid persisted values.

- [x] **Step 2: Run the focused test and confirm the contract is missing**

Run: `swift test --package-path Packages/SpaceTraceKit --filter AttributionTests`

Expected: FAIL because the durable attribution types do not exist.

- [x] **Step 3: Implement the smallest validated domain contract**

Keep the module Foundation-free and use typed throwing initializers consistent with `ScopeID` and `Observation`.

- [x] **Step 4: Verify and commit**

Run the focused tests, `make verify`, and `git diff --check`.

Commit: `建立确定性分类领域契约`

### Task 2: Normalize Inputs Without Filesystem I/O

**Files:**
- Modify: `Packages/SpaceTraceKit/Package.swift`
- Create: `Packages/SpaceTraceKit/Sources/SpaceTraceAttribution/AttributionInput.swift`
- Create: `Packages/SpaceTraceKit/Tests/SpaceTraceAttributionTests/AttributionInputTests.swift`

**Interfaces:**
- `AttributionInput.init(absolutePath:homeDirectory:bundleIdentifier:volumeContext:)` validates and lexically decomposes paths.
- Produces absolute components plus optional home-relative components; repeated separators and `.` are normalized, while `..`, relative paths, and invalid home containment are rejected.

- [ ] **Step 1: Write failing normalization tests**

Cover root paths, repeated separators, component-boundary home matching, renamed home directories, Unicode preservation, relative paths, and traversal rejection.

- [ ] **Step 2: Run the focused tests and confirm the target/API is missing**

Run: `swift test --package-path Packages/SpaceTraceKit --filter AttributionInputTests`

Expected: FAIL because `SpaceTraceAttribution` and `AttributionInput` do not exist.

- [ ] **Step 3: Implement lexical normalization and explicit context**

Add `AttributionVolumeContext` with an explicit snapshot-factor observation flag. Do not resolve symlinks, access the filesystem, or infer a volume from a path.

- [ ] **Step 4: Verify and commit**

Run focused tests, architecture checks, `make verify`, and `git diff --check`.

Commit: `实现分类输入的纯词法规范化`

### Task 3: Add Validated Versioned Rules and Deterministic Resolution

**Files:**
- Create: `Packages/SpaceTraceKit/Sources/SpaceTraceAttribution/AttributionRule.swift`
- Create: `Packages/SpaceTraceKit/Sources/SpaceTraceAttribution/DeterministicAttributionClassifier.swift`
- Create: `Packages/SpaceTraceKit/Tests/SpaceTraceAttributionTests/AttributionRuleTests.swift`
- Create: `Packages/SpaceTraceKit/Tests/SpaceTraceAttributionTests/DeterministicAttributionClassifierTests.swift`

**Interfaces:**
- `AttributionRuleCatalog` rejects duplicate IDs and empty catalogs.
- `DeterministicAttributionClassifier.classify(_:)` returns `.classified`, `.unknown(.noMatchingRule)`, or `.unknown(.ambiguous(ruleIDs:))`.
- Resolution order is priority descending, specificity descending, then rule ID ascending only for stable ordering. Equal-winning rules from different categories produce ambiguity rather than a guessed category.

- [ ] **Step 1: Write failing rule-validation and precedence tests**

Cover exact component matching, more-specific-over-generic behavior, stable ordering, duplicate IDs, empty patterns, no match, same-category tie, and cross-category ambiguity.

- [ ] **Step 2: Run focused tests and confirm failure**

Run: `swift test --package-path Packages/SpaceTraceKit --filter AttributionRuleTests` and `swift test --package-path Packages/SpaceTraceKit --filter DeterministicAttributionClassifierTests`.

- [ ] **Step 3: Implement validated rules and fail-closed resolution**

Keep all matching pure and bounded. Successful output copies the exact rule identity, version, confidence, and path-free evidence code into `StorageAttribution`.

- [ ] **Step 4: Verify and commit**

Run focused tests, strict concurrency, `make verify`, and `git diff --check`.

Commit: `实现版本化分类规则与冲突降级`

### Task 4: Build the Initial P0 Rule Corpus and Metric Gate

**Files:**
- Create: `Packages/SpaceTraceKit/Sources/SpaceTraceAttribution/BuiltInAttributionCatalog.swift`
- Create: `Packages/SpaceTraceKit/Sources/SpaceTraceAttribution/AttributionFixtureEvaluator.swift`
- Create: `Packages/SpaceTraceKit/Tests/SpaceTraceAttributionTests/BuiltInAttributionCatalogTests.swift`
- Create: `Packages/SpaceTraceKit/Tests/SpaceTraceAttributionTests/AttributionFixtureCorpusTests.swift`
- Create: `Packages/SpaceTraceKit/Tests/SpaceTraceAttributionTests/Fixtures/attribution-fixtures-v1.json`

**Interfaces:**
- Built-in catalog version `1` covers exact evidence for Xcode/Simulator, Docker/local VM, AI model/cache, creative cache/render, games, generic logs/caches, local cloud data, and explicit snapshot-factor context.
- Fixture evaluator reports known precision overall/per category and ambiguity-to-Unknown accuracy. It fails closed on malformed fixtures and never logs input paths.

- [ ] **Step 1: Add a failing versioned fixture suite**

Commit independent expected outputs for positives, near-miss negatives, overlapping specific/generic paths, renamed-home paths, cloud placeholders, and explicit/no-explicit snapshot evidence.

- [ ] **Step 2: Confirm built-in rules and evaluator are missing**

Run: `swift test --package-path Packages/SpaceTraceKit --filter AttributionFixtureCorpusTests`.

- [ ] **Step 3: Implement reviewed built-in rules and metrics**

Generic rules use lower priority than product-specific rules. Snapshot rules match context only. The evaluator exposes counts and ratios; release gating thresholds remain documented and explicit.

- [ ] **Step 4: Verify and commit**

Run the complete attribution suite, `make verify`, and `git diff --check`.

Commit: `建立首版分类规则语料与精度门禁`

### Task 5: Document the Boundary and Reconcile Project Status

**Files:**
- Modify: `README.md`
- Modify: `docs/README.md`
- Create: `docs/engineering/deterministic-attribution.md`
- Create: `docs/engineering/deterministic-attribution.zh-CN.md`
- Modify: `docs/engineering/implementation-status.md`
- Modify: `docs/engineering/implementation-status.zh-CN.md`
- Modify: `docs/product/product-roadmap.md`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Documents rule governance, evidence semantics, Unknown/ambiguity behavior, fixture extension, privacy boundary, current precision evidence, and remaining application/persistence/UI integration.

- [ ] **Step 1: Write English and Chinese engineering documentation**

Include a contributor workflow for adding a rule and its positive, negative, and ambiguous fixtures. State that a category is an explanation, not a deletion recommendation.

- [ ] **Step 2: Reconcile roadmap and implementation status**

Mark the classifier engine/corpus complete only to the extent proven. Keep finding generation, persistence, historical wording, UI projection, move/deletion semantics, export, real-user review, and macOS 15.6 runtime evidence open.

- [ ] **Step 3: Final verification and commit**

Run:

```bash
swift test --package-path Packages/SpaceTraceKit --filter SpaceTraceAttributionTests
make verify
git diff --check
```

Review all local documentation links and scan committed fixtures for personal paths or secrets.

Commit: `完成确定性分类文档与阶段收口`

## Self-Review

- Spec coverage: categories, stable identity/version/confidence/evidence, deterministic precedence, Unknown, ambiguity, renamed-home behavior, cloud/snapshot boundaries, and fixture metrics each have an owned task.
- Placeholder audit: every source, test, fixture, documentation file, public type, focused command, and commit boundary is named; no implementation step depends on an unspecified adapter.
- Type consistency: the classifier always returns the domain `StorageAttribution`; unknown/ambiguous outcomes are classifier results and are never persisted as fake successful categories.
- Privacy: raw input paths exist only in-memory at the call boundary and synthetic test fixtures; successful evidence is a stable path-free code.
- Scope boundary: application orchestration, finding persistence, historical recomputation UI, move/delete findings, export, and release publication are intentionally separate plans.
