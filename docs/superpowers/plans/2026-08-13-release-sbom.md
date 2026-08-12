# Release SBOM and Notices Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a deterministic SPDX 2.3 SBOM and an exact third-party notices inventory to every SpaceTrace release-candidate artifact without claiming an unapproved project license.

**Architecture:** A standalone release-metadata generator validates that the repository has no remote Swift package dependency, emits an SPDX JSON document with `licenseDeclared = NOASSERTION`, and emits a plain-text inventory of platform-provided runtime dependencies. The existing fail-closed packager audits the final Mach-O linkage, adds both files to the checksummed release set, and copies the notices into the DMG. The packaging contract test is the public behavior seam.

**Tech Stack:** zsh, Git, `plutil`, `otool`, `shasum`, Xcode release builds, HFS+/UDZO DMG packaging.

## Global Constraints

- The minimum deployment target remains macOS 15.6 and the artifact remains arm64-only.
- No network access or new package dependency is allowed during SBOM generation.
- The SBOM must say `NOASSERTION` until the repository owner approves a project license; generating metadata must not make that legal decision.
- System frameworks, `/usr/lib` libraries, and the system Swift runtime are inventoried as platform-provided and are not represented as bundled third-party packages.
- Any remote Swift package, bundled framework/dylib, non-system Mach-O dependency, malformed version/commit, or output collision must fail closed.
- The DMG remains ad-hoc signed, not notarized, read-only, and explicit about Gatekeeper risk.
- No generated artifact may contain raw user paths, bookmarks, observation identities, or diagnostic history.

---

### Task 1: Freeze the generator contract with a failing release-packaging test

**Files:**
- Modify: `Scripts/test-release-candidate-packaging.sh`
- Create: `Scripts/generate-release-metadata.sh`

**Interfaces:**
- Consumes: `--version <semver> --commit <40-hex> --sbom <new-file> --notices <new-file>`.
- Produces: one SPDX 2.3 JSON document and one deterministic UTF-8 notices document, or a nonzero fail-closed exit.

- [ ] **Step 1: Extend the expected artifact set before implementing generation**

Add `SpaceTrace-$version.spdx.json` and `SpaceTrace-$version.third-party-notices.txt` to `expected_entries`, require both paths to exist, and assert these literal fields:

```zsh
[[ $(plutil -extract spdxVersion raw -o - "$sbom_path") == SPDX-2.3 ]]
[[ $(plutil -extract dataLicense raw -o - "$sbom_path") == CC0-1.0 ]]
[[ $(plutil -extract packages.0.versionInfo raw -o - "$sbom_path") == "$version" ]]
[[ $(plutil -extract packages.0.licenseDeclared raw -o - "$sbom_path") == NOASSERTION ]]
[[ $(plutil -extract packages.0.filesAnalyzed raw -o - "$sbom_path") == false ]]
grep -Fq 'No third-party libraries are embedded in SpaceTrace.app.' "$notices_path"
```

- [ ] **Step 2: Confirm RED**

Run:

```bash
make package-release-candidate-test VERSION=0.1.0-rc.sbom-red
```

Expected: fail because the two new artifacts do not exist; no output survives the test trap.

- [ ] **Step 3: Implement the minimal standalone generator**

The script must validate a clean local package graph before writing either file:

```zsh
[[ ! -e Packages/SpaceTraceKit/Package.resolved ]]
! grep -Eq '\.package[[:space:]]*\(' Packages/SpaceTraceKit/Package.swift
! grep -Eq 'XCRemoteSwiftPackageReference|repositoryURL[[:space:]]*=' \
    SpaceTrace.xcodeproj/project.pbxproj
```

Build an XML plist with `plutil`, convert it to JSON, and atomically rename it to the requested SBOM path. The SPDX package contains exactly one described package, `SpaceTrace`, with a deterministic namespace derived from version plus commit, a commit-timestamp `creationInfo.created`, `downloadLocation` bound to the GitHub commit, one purl external reference, `filesAnalyzed = false`, and `licenseDeclared/licenseConcluded/copyrightText = NOASSERTION`. Write notices through a private staging file and atomically rename it only after all validation succeeds.

- [ ] **Step 4: Add generator negative tests at the script seam**

The packaging test must call the generator directly and prove rejection of an invalid version, a non-40-hex commit, an existing SBOM output, and an existing notices output. Each probe writes only beneath its disposable test root.

- [ ] **Step 5: Run the focused contract**

Run the generator against the clean current commit and verify `plutil -lint`, exact SPDX fields, absence of the repository absolute path, and byte-identical output from two independent disposable directories.

### Task 2: Integrate metadata and final Mach-O dependency auditing into the RC packager

**Files:**
- Modify: `Scripts/package-release-candidate.sh`
- Modify: `Scripts/test-release-candidate-packaging.sh`
- Modify: `Makefile`

**Interfaces:**
- Consumes: the final signed `SpaceTrace.app` and the Task 1 generator.
- Produces: an exact six-artifact output set whose checksum file covers DMG, manifest, SBOM, and notices.

- [ ] **Step 1: Add a failing linkage-policy assertion to the packaging test**

After packaging, enumerate the app with `find` and assert that it contains no embedded `.framework` or `.dylib`. Parse `otool -L` and require every dependency to start with `/System/Library/` or `/usr/lib/`.

- [ ] **Step 2: Generate and stage release metadata only after the final app passes signature checks**

Invoke:

```zsh
"$script_directory/generate-release-metadata.sh" \
    --version "$version" \
    --commit "$commit" \
    --sbom "$sbom_path" \
    --notices "$notices_path"
```

Copy the notices file into the DMG root as `THIRD-PARTY-NOTICES.txt`; do not copy the SBOM into the application bundle or DMG.

- [ ] **Step 3: Freeze manifest and checksum references**

Add manifest keys `artifacts.sbom`, `artifacts.sbomSha256`, `artifacts.thirdPartyNotices`, and `artifacts.thirdPartyNoticesSha256`. Include DMG, manifest, SBOM, and notices in the checksum file, keep the checksum file self-excluded, require exactly six top-level artifacts, and set all non-app artifacts to mode `0644`.

- [ ] **Step 4: Verify the complete packaging contract**

Run:

```bash
make package-release-candidate-test VERSION=0.1.0-rc.sbom
```

Expected: invalid/dirty/existing-output probes fail; the positive build reports `release candidate packaging contract: PASS`; all four checksum entries verify.

### Task 3: Document the legal boundary and release evidence

**Files:**
- Modify: `docs/engineering/release-candidate-checklist.md`
- Modify: `docs/engineering/release-candidate-checklist.zh-CN.md`
- Modify: `docs/product/product-roadmap.md`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: the exact six-artifact contract and passing Task 2 evidence.
- Produces: synchronized English/Chinese tester guidance and an honest remaining license gate.

- [ ] **Step 1: Update the artifact tables and verification commands**

List the SPDX and notices artifacts, state that the SBOM is source/provenance inventory rather than vulnerability attestation, and add `plutil -lint`, `plutil -extract packages.0.licenseDeclared`, and checksum verification to both checklists.

- [ ] **Step 2: Record the exact non-claim**

State in both languages that no external Swift package or bundled third-party library was found and system libraries are platform-provided, while `NOASSERTION` deliberately keeps the project-license approval gate open.

- [ ] **Step 3: Run release-document gates**

Run:

```bash
git diff --check
./Scripts/check-architecture.sh
./Scripts/check-historical-ledger-privacy.sh
make package-release-candidate-test VERSION=0.1.0-rc.sbom-docs
```

Expected: all commands pass; English and Chinese checklist headings remain structurally aligned.

- [ ] **Step 4: Commit and push**

Commit the generator, tests, packager, Makefile, and docs with the Chinese message `加入可复现发布 SBOM 与依赖清单`, then push the current branch. The project license remains an explicit owner decision after this commit.

## Self-Review

- Spec coverage: generation, negative validation, final-binary linkage, manifest/checksum binding, DMG notices, bilingual documentation, and legal non-claim each have a task.
- Placeholder scan: the plan contains no implementation placeholder; `NOASSERTION` is the required SPDX value, not unfinished text.
- Type/interface consistency: all tasks use the same four generator arguments and the same versioned SBOM/notices filenames.

