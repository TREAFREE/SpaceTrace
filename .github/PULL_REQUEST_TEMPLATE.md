## Summary

<!-- What user/developer problem does this solve? Keep the first paragraph release-note ready. -->

Closes #

## Scope

**Change type:** <!-- feat / fix / perf / refactor / test / docs / build / ci / security -->

**Risk:** <!-- Low / Medium / High; explain below -->

**In scope:**

- <!-- item -->

**Out of scope:**

- <!-- item -->

## Behavior and acceptance evidence

<!-- Map each issue acceptance criterion to a test, screenshot, benchmark, or reproducible manual result. -->

| Acceptance criterion | Evidence |
|---|---|
|  |  |

## Design

<!-- Link RFC/ADR when required. Explain important alternatives and failure behavior. -->

- RFC/ADR: <!-- N/A or link -->
- Rollout/feature flag: <!-- N/A or details -->
- Rollback/forward-fix: <!-- N/A or details -->

## Privacy, security, and permissions

<!-- Answer every row. “No change” is acceptable; blank is not. -->

| Area | Impact |
|---|---|
| File metadata/content access |  |
| Persisted fields and retention |  |
| Logs and diagnostic export |  |
| Entitlements/system permissions |  |
| Network/update behavior |  |
| Dependencies/supply chain |  |

## Testing

- [ ] Unit tests
- [ ] Integration tests
- [ ] Permission denied/revoked/recovered tests
- [ ] N-1/N-2 migration tests (schema change)
- [ ] Performance/energy tests
- [ ] UI/accessibility smoke tests
- [ ] Not applicable items are explained below

Commands and results:

```text

```

## Performance evidence

<!-- Required for scanner, database, event pipeline, query, or background behavior changes. Include device/OS, fixture scale, before/after p50/p95, memory and DB size. -->

| Metric | Before | After | Budget |
|---|---:|---:|---:|
|  |  |  |  |

## UI evidence

<!-- Add before/after images or video for visual changes. Verify VoiceOver/keyboard and non-color status. Remove if N/A. -->

## Migration and compatibility

<!-- The accepted minimum is macOS 15.6 on Apple Silicon. Note any OS, architecture, database, settings, appcast, or downgrade impact. -->

## Author checklist

- [ ] I linked an issue, or explained why this is an exempt small change.
- [ ] The PR is <= 400 non-generated lines and <= 15 files, or includes a review map and split rationale.
- [ ] I reviewed the complete diff, including generated files, lockfiles, entitlements, logs, and error paths.
- [ ] The change is read-only toward user files and treats inaccessible data as unknown, or has an approved RFC.
- [ ] I did not add public paths, filenames, volume names, credentials, real user fixtures, or raw diagnostic data.
- [ ] New behavior includes failure, cancellation, permission degradation, and upgrade tests where applicable.
- [ ] SwiftFormat, SwiftLint strict, Debug/Release build, and relevant tests pass on the latest commit.
- [ ] User docs, `CHANGELOG.md`, localization, RFC/ADR, and threat model are updated where required.
- [ ] I documented rollout, rollback/forward-fix, and any process exception with owner and expiry.

## Reviewer focus

<!-- Point reviewers to the riskiest files/invariants and give a suggested review order. -->

1. <!-- Start with the riskiest invariant or file. -->

## Exceptions / follow-ups

<!-- Link every deferred item. An exception must name the rule, risk, compensating control, approver, owner, and expiry <= 7 days unless the process specifies otherwise. -->
