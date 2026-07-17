# ADR-005: Isolated optional system-command adapter

## Status

Proposed

Date: 2026-07-18

## Context

Public Foundation/CoreServices APIs provide the MVP's required volume, path, event, and metadata observations. Some useful optional context—such as local Time Machine snapshot inventory—may be exposed more conveniently by Apple-supplied command-line tools. Command output and behavior can change between macOS releases, can be localized or malformed, and may tempt the product into unsupported or destructive operations.

The non-negotiable architecture rule is that no private API, undocumented database, or brittle command output can be the only implementation path for a P0 requirement. SpaceTrace is read-only and must not evolve into a cleanup command launcher.

## Decision

1. P0 scanning, history, coverage, and attribution must work without executing a subprocess.
2. Any Apple-supplied command used for optional enrichment is accessed only through a typed `SystemCommandAdapter` implementing a narrow application-owned port.
3. The adapter invokes an allowlisted absolute executable path directly with an argument array. It never invokes `/bin/sh`, login shells, command strings, pipes, redirection, globbing, or user-provided executable paths.
4. Every invocation has a fixed timeout, output byte limit, cancellation/termination policy, sanitized environment, and captured exit status. Prefer structured/plist output where the tool supports it.
5. Parsers are versioned by data-source schema, fixture-first, fuzzed, and OS-qualified. Unknown output produces `unavailable`/`parseFailed`, never a guessed value.
6. Only explicitly enumerated read-only subcommands are allowed. Destructive variants—including snapshot deletion/thinning, disk repair/erase, permission changes, or process termination—have no adapter API.
7. Command results are evidence with source, OS version, timestamp, parser version, and confidence. Failure degrades only the optional enrichment.
8. No command integration ships until its privacy, security, performance, and supported-OS fixtures pass review.

## Options considered

| Option | Benefits | Costs / failure modes | Assessment |
| --- | --- | --- | --- |
| Optional isolated adapter | Adds context while containing brittle behavior and preserving core | Requires parser governance and OS fixtures | Selected |
| No subprocesses ever | Smallest attack/maintenance surface | May omit valuable snapshot context exposed by system tools | Valid deployment profile; core must support it |
| Shell scripts embedded in app | Fast prototyping | Injection, quoting, localization, environment, and observability risk | Rejected |
| Commands as P0 source of truth | May expose otherwise unavailable values | Output instability can break core product on OS update | Rejected |
| Private framework/database access | Richer system internals | Review, compatibility, security, and trust risk | Rejected |
| Destructive cleanup commands | Immediate remediation | Violates read-only product and risks data loss | Rejected |

## Consequences

### Positive

- Optional macOS context can be added without contaminating the domain or scanner.
- A tool/output change becomes a bounded adapter failure, not loss of core functionality.
- Direct execution and allowlists sharply reduce injection risk.
- The API surface itself prevents destructive command use.

### Negative and accepted trade-offs

- Each supported macOS version needs recorded fixtures and periodic revalidation.
- Optional context may show “unavailable” after an OS update until the parser is qualified.
- Subprocess launch has performance and signing-review implications.
- Some useful command output may remain intentionally unsupported.

### Initial scope

No command is automatically approved by this ADR. Candidate adapters such as read-only local-snapshot inventory require their own small source review. The core architecture must ship and pass acceptance with the adapter disabled.

## Validation plan

For each proposed command source:

1. document the exact absolute binary, allowlisted arguments, source ownership, supported OS versions, and data semantics;
2. capture success, empty, permission-denied, localized, truncated, malformed, timeout, nonzero-exit, and future-field fixtures before implementing the parser;
3. fuzz parser input and enforce output/depth/count limits;
4. test that user paths are passed only as individual arguments and cannot alter executable/arguments;
5. test cancellation and child termination without blocking the main actor;
6. run on oldest/current supported macOS in a disposable environment;
7. verify disabling/removing the adapter leaves all P0 acceptance tests green;
8. search production code and entitlements for unapproved process/shell invocation.

## Revisit triggers

- Apple publishes a stable public framework that supersedes a command source.
- A command removes structured output, changes semantics, or repeatedly breaks across supported OS releases.
- Product proposes making command-derived data P0 or action-enabling.
- A security review prohibits subprocesses for FDA-enabled applications.
- Product proposes any mutation or destructive command.
- The adapter expands beyond a small allowlist or requires elevated privileges.
