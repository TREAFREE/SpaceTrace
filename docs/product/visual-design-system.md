# SpaceTrace Visual Design System

Status: **Implemented foundation**

Last verified: 2026-08-10

Chinese companion translation: [visual-design-system.zh-CN.md](visual-design-system.zh-CN.md).

## Product character

SpaceTrace should feel precise, calm, private, and native to macOS. Visual polish must
strengthen evidence hierarchy rather than make incomplete data appear more certain.

The design follows four rules:

1. evidence and operational state are more prominent than decoration;
2. complete, partial, unavailable, and failed states always retain text or symbols in
   addition to color;
3. system materials and semantic colors adapt to appearance and increased contrast;
4. the macOS 15.6 deployment floor takes precedence over macOS 26-only effects.

## Typography

SpaceTrace uses the system font stack. This preserves Chinese fallback quality,
Dynamic Type behavior, VoiceOver pronunciation, and the platform's text rendering.
No bundled third-party font is required.

| Role | SwiftUI token | Use |
| --- | --- | --- |
| Hero | `Font.spaceTraceHero` | One page-level product statement |
| Section | `Font.spaceTraceSectionTitle` | Major cards and operational states |
| Card | `Font.spaceTraceCardTitle` | Local status and row headings |
| Metric | `Font.spaceTraceMetric` | Byte values and comparable numeric evidence |
| Body/caption | Native semantic styles | Explanation, provenance, and caveats |

Hero and structural headings use the rounded system design. Body text remains in the
default system design for long-form readability. Metrics use monospaced digits so
capacity changes do not visually jump as values update.

## Color and material

- The adaptive accent is deep evidence blue in Light Mode and brighter cyan-blue in
  Dark Mode.
- Page backgrounds use a restrained accent wash over the system window background.
- Primary panels use `regularMaterial`; nested evidence surfaces use the system
  control background.
- Borders become stronger when Increase Contrast is enabled.
- Green, orange, and red retain their semantic status meanings and are never the only
  carrier of information.

The implementation lives in
`SpaceTrace/SpaceTraceDesign.swift`. Overview, authorization, history, and menu-bar
views consume the same tokens instead of defining independent card systems.

## Application icon

The icon combines three storage layers with a continuous orbital trace. It contains no
text, trademarked character, or destructive-cleanup metaphor. The master is an
original generated bitmap, then locally chroma-keyed, alpha-validated, and resized with
the macOS asset matrix from 16 px through 1024 px.

Generation specification:

> Premium native macOS utility icon for a privacy-first storage-change tracer; one
> midnight-navy rounded tile; a simple electric-blue/cyan orbital trace around three
> stacked storage contours; calm, precise, recognizable at 16 px; no text, letters,
> Apple logo, Finder face, watermark, or extra object.

The checked-in master and derived sizes are in
`SpaceTrace/Assets.xcassets/AppIcon.appiconset`.

## Accessibility and compatibility

- Typography uses semantic text styles rather than fixed point sizes.
- Decorative symbols and gradients are hidden from VoiceOver.
- Related status content uses container-first grouping without hiding actionable
  controls.
- Controls retain labels, identifiers, keyboard shortcuts, and hover help.
- Materials and semantic colors adapt to Light/Dark Mode and system contrast.
- No `.glassEffect()` or other macOS 26-only API is used.

## Verification

On 2026-07-31:

- the authorized overview was rendered in a separate ad-hoc signed sandbox bundle at
  the default 1080 × 720 window size and visually inspected for hierarchy, clipping,
  and chart layout;
- the 1024 px, 128 px, and 32 px icon outputs were visually inspected; all ten asset
  slots have the expected pixel dimensions and alpha channels;
- application unit tests passed;
- `make verify` passed, including architecture checks, 244 package tests in 37 suites,
  strict concurrency, application tests, and Debug/Release builds;
- the UI-test rerun on that date was blocked before test initialization because the
  host runner could not establish an automation session. It remains historical blocked
  evidence and is not retroactively reported as a pass.

On 2026-08-10, Xcode 26.1.1 successfully launched the real macOS UI runner and the
App Sandbox application using local ad-hoc “Sign to Run Locally” signatures. All eight
controlled `DirectoryAuthorizationUITests` scenarios passed on macOS 26.5.2, including
authorized, stale, unavailable-volume, multi-scope, no-fabricated-history, and
unconfigured states. Focused accessibility assertions prove that the primary directory
action and authorized-scope replacement/removal actions have stable names and are
hittable, while the status detail and the read-only/no-deletion privacy boundary are
present in the macOS accessibility value tree.

This is automated current-host fixture evidence. It does not claim a manual VoiceOver
speech review, Full Keyboard Access traversal, increased-contrast/reduced-motion/larger-
text visual review, a stable Apple signing identity, real Powerbox/bookmark behavior, or
macOS 15.6 runtime qualification. Those remain release-matrix gates.
