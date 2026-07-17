# Test Plan: Scope

- Owner:
- Reviewers:
- Target milestone:
- Related requirements:
- Related risks:

## Scope

Describe the behavior and supported environment covered by this plan.

## Out of scope

List behaviors, OS versions, devices, volumes, or failure modes not covered.

## Test matrix

| Area | Scenario | Level | Fixture/environment | Expected result | Requirement |
|---|---|---|---|---|---|

## Compatibility matrix

| macOS | Hardware | File system/source | Permission state | Required result |
|---|---|---|---|---|

## Performance budgets

| Metric | Workload | Budget | Measurement method |
|---|---|---|---|

## Privacy and security checks

- Verify logs and exported diagnostics do not include raw paths unless explicitly included by the user.
- Verify permission denial and revocation produce bounded, truthful coverage gaps.
- Verify fixtures contain no personal data.

## Entry criteria

- Required design and implementation state before execution.

## Exit criteria

- Required pass rate, blocker policy, performance results, and residual-risk approval.

## Results

Complete after execution with evidence links, deviations, and accepted residual risk.
