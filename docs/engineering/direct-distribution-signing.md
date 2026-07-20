# Direct DMG Distribution and Code Signing

Status: **Pre-release policy; public distribution is not yet qualified**

Last updated: 2026-07-20

Chinese companion translation: [direct-distribution-signing.zh-CN.md](direct-distribution-signing.zh-CN.md). This English document remains the engineering source of truth.

## Current decision

SpaceTrace may use an ad-hoc-signed DMG for a small, explicitly trusted tester group while the maintainer has no paid Apple Developer Program membership. This is a testing channel, not a Gatekeeper-trusted public release.

GitHub hosting does not identify the developer to macOS. A user can usually override the unidentified/not-notarized warning after attempting to open the app by using **System Settings > Privacy & Security > Open Anyway**. Apple warns that this bypass removes an important protection, so SpaceTrace must never describe the flow as normal verification or as equivalent to notarization.

Do not ask users to disable Gatekeeper globally or recursively remove quarantine attributes. The supported manual exception in System Settings is narrower and leaves the rest of Gatekeeper enabled.

## What paid membership changes

Apple issues Developer ID certificates only to Apple Developer Program or Enterprise Program members. The public direct-distribution path is:

1. archive a Release build with Hardened Runtime and the reviewed sandbox entitlements;
2. sign the app and nested executable code with a Developer ID Application certificate;
3. create the DMG;
4. submit the deliverable to Apple's notary service and staple the ticket;
5. verify signatures, notarization, quarantine launch, update compatibility, and minimum-OS behavior before publishing.

An ad-hoc or local development signature is not accepted for notarization. The standard Apple Developer Program membership is currently USD 99 per membership year, subject to regional pricing; eligible organizations can request a fee waiver.

## Controls for an unpaid tester build

- Build from a tagged, reproducible commit; publish the commit SHA and SHA-256 checksum beside the DMG.
- Keep App Sandbox, read-only user-selected file access, app-scoped bookmarks, and Hardened Runtime enabled.
- Ad-hoc sign the final app bundle after all files are assembled, then verify it with `codesign` and test it from a freshly downloaded, quarantined DMG.
- Explain the exact **Open Anyway** steps and that macOS cannot verify the publisher or notarization status.
- Never call the artifact “signed and notarized” or “Apple verified.”
- Treat every new downloaded build as a fresh qualification case.

## SpaceTrace-specific release risk

The current sandbox qualification proves permission restoration after restarting the same ad-hoc-signed binary. It does not yet prove that app-scoped security bookmarks survive replacement by a separately built ad-hoc-signed version. Before any tester DMG, run an update matrix covering fresh install, same-build restart, replacement build, stale bookmark, explicit revocation, external-volume return, and reauthorization. If identity continuity is not stable, the release notes must say that an update can require the user to choose the directory again.

## Official references

- Apple Developer, [Developer ID certificate](https://developer.apple.com/help/glossary/developer-id-certificate/)
- Apple Developer, [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- Apple Support, [Open a Mac app from an unknown developer](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac)
- Apple Developer, [Program enrollment](https://developer.apple.com/programs/enroll/)
