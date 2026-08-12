# Deterministic Attribution Engine

Last verified: 2026-08-13

Chinese companion translation: [deterministic-attribution.zh-CN.md](deterministic-attribution.zh-CN.md).

## Purpose and current boundary

`SpaceTraceAttribution` is the pure, offline classifier behind FR-007. It turns lexical path features and explicit volume context into a conservative storage category. It does not access the filesystem, open file contents, inspect processes, use the network, or decide that data is safe to delete.

This slice implements the engine and the reviewed version-two regression corpus. The immutable historical-finding pipeline freezes the exact catalog/rule decision at each available endpoint, persists it in SQLite, and presents it in the bounded Overview without reclassification. The FR-007/KPI-03 repository-corpus gate is now closed; user-controlled diagnostic export remains unimplemented.

## Result contract

A successful `StorageAttribution` contains:

- one stable category code;
- a stable rule ID and positive rule version;
- `high`, `medium`, or `low` confidence;
- a stable, path-free evidence code.

Unknown confidence cannot be persisted as a successful result. The classifier returns either `classified`, `unknown(noMatchingRule)`, or `unknown(ambiguous)`. Equal winning rules from different categories always become ambiguous; rule order cannot decide the user's result.

## Input and precedence

`AttributionInput` performs lexical normalization only. It collapses repeated separators and `.` components, rejects relative paths, `..`, null bytes, invalid home roots, and path-like bundle identifiers, and derives home-relative components using complete component boundaries. It does not resolve symlinks or infer a volume.

Matching and precedence are deterministic:

1. every configured matcher criterion must match;
2. greater explicit priority wins;
3. at equal priority, more evidence criteria and then more path components win;
4. equal winners in one category use ascending rule ID for stable evidence;
5. equal winners across categories return ambiguous Unknown.

Generic `Library/Caches` and `Library/Logs` rules have lower priority than product-specific rules. Snapshot factors require an explicit platform observation; a directory named “Snapshots” is not evidence.

## Built-in catalog v1

The first catalog contains reviewed component-prefix rules for:

| Category | Initial evidence families |
| --- | --- |
| Developer tools | Xcode DerivedData, CoreSimulator, Xcode cache |
| Virtualization | Docker container/group data, UTM data |
| AI models and caches | Ollama models, Hugging Face cache, LM Studio models |
| Creative caches/render data | Adobe cache/media cache, DaVinci Resolve CacheClip |
| Games | Steam steamapps, Epic, Blizzard |
| Logs and caches | User/system Library Caches and Logs fallbacks |
| Cloud-local data | Mobile Documents, CloudStorage, CloudDocs state |
| Snapshot factors | Explicit local APFS or Time Machine local-snapshot observation |

These categories explain observed storage location or context. They are not ownership proof and are never a cleanup recommendation.

## Fixture evidence and open gate

`attribution-fixtures-v2.json` contains 64 known scenarios—eight for each P0 category—and 32 near-miss/Unknown scenarios. Its separate rule-contract table freezes every built-in rule's ID, rule version, category, confidence, and path-free evidence code; each known case names the exact expected rule rather than only its category. The checked-in suite reports 100% precision, 100% recall, and 100% Unknown accuracy on this synthetic reviewed corpus. It also enforces unique lowercase case IDs, exact catalog coverage, component-boundary/case/home-directory negatives, and explicit snapshot context. Separate tests prove that cross-category ties remain ambiguous and that precision, recall, and Unknown accuracy use distinct denominators. The original v1 corpus remains checked in as historical evidence and is not used to inflate the v2 denominator.

This is regression evidence, not real-user prevalence or accuracy evidence. It satisfies KPI-03's repository gate of at least 60 known paths at no less than 95% precision, plus the stronger eight-per-category review target, without forcing labels onto the 32 Unknown cases. Frozen finding decisions are persisted and presented without silent reinterpretation. Public Beta remains blocked by the separate minimum-OS, manual accessibility/usability, export/redaction, governance, and distribution gates.

## Adding or changing a rule

1. Add a stable lowercase rule ID and evidence code. Never include a user path, username, display text, or localized wording.
2. Use exact path components and the narrowest defensible prefix. Add explicit metadata/context criteria when path evidence is insufficient.
3. Add positive fixtures, component-boundary near misses, and an overlap/ambiguity case before changing the catalog.
4. Run `swift test --package-path Packages/SpaceTraceKit --filter SpaceTraceAttributionTests` and `make verify`.
5. Increment the rule version when its match or explanation meaning changes. Historical results must retain the old identity; silent reinterpretation is not allowed.

Community rule packs, localized evidence wording, replacement/supersession, and explicit recomputation are later governed features, not implicit behavior of catalog v1.
