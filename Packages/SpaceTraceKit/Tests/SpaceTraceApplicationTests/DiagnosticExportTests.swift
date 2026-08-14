import Foundation
@testable import SpaceTraceApplication
import SpaceTraceDomain
import Testing

struct DiagnosticExportTests {
    @Test("Preview freezes sections, selection, privacy mode, and no-upload boundary")
    func previewsExactExportSurface() throws {
        let fixture = try makeFixture()
        let preview = try DiagnosticExportBuilder().preview(
            source: fixture.source,
            exportID: fixture.exportID,
            selectedFindingIDs: [fixture.findingID],
            pathMode: .redacted(homeDirectory: "/Fixtures/Homes/alex")
        )

        #expect(preview.exportID == fixture.exportID)
        #expect(preview.pathMode == .redacted)
        #expect(preview.sections == [
            DiagnosticExportPreviewSection(kind: .system, itemCount: 1),
            DiagnosticExportPreviewSection(kind: .coverage, itemCount: 1),
            DiagnosticExportPreviewSection(kind: .healthEvents, itemCount: 1),
            DiagnosticExportPreviewSection(kind: .selectedFindings, itemCount: 1),
        ])
        #expect(preview.includesFileContents == false)
        #expect(preview.uploadsAutomatically == false)
    }

    @Test("Default export removes paths, names, scope IDs, and keeps tokens stable only inside one export")
    func redactsPrivateEvidence() throws {
        let fixture = try makeFixture()
        let prepared = try DiagnosticExportBuilder().prepare(
            source: fixture.source,
            exportID: fixture.exportID,
            selectedFindingIDs: [fixture.findingID],
            pathMode: .redacted(homeDirectory: "/Fixtures/Homes/alex"),
            redactionSalt: Data(repeating: 0x42, count: 32)
        )
        let text = try #require(String(data: prepared.data, encoding: .utf8))
        let document = try JSONDecoder().decode(
            DiagnosticExportDocument.self,
            from: prepared.data
        )
        let finding = try #require(document.findings.first)

        #expect(text.contains("alex") == false)
        #expect(text.contains("Secret Project") == false)
        #expect(text.contains("Private Cache") == false)
        #expect(text.contains("scope-private") == false)
        #expect(finding.baselinePath.hasPrefix("$HOME/"))
        #expect(finding.baselinePath == finding.comparisonPath)
        #expect(finding.baselineDisplayName == finding.comparisonDisplayName)
        #expect(document.privacy.pathMode == .redacted)
        #expect(document.privacy.includesFileContents == false)
        #expect(document.privacy.uploadsAutomatically == false)
        #expect(document.redactionSalt == nil)
    }

    @Test("Full paths require a fresh authorization bound to this export")
    func rawPathsRequireBoundAuthorization() throws {
        let fixture = try makeFixture()
        let otherID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

        #expect(throws: DiagnosticExportError.rawPathAuthorizationMismatch) {
            _ = try DiagnosticExportBuilder().prepare(
                source: fixture.source,
                exportID: fixture.exportID,
                selectedFindingIDs: [fixture.findingID],
                pathMode: .fullPaths(
                    authorization: .confirmed(for: otherID)
                )
            )
        }

        let prepared = try DiagnosticExportBuilder().prepare(
            source: fixture.source,
            exportID: fixture.exportID,
            selectedFindingIDs: [fixture.findingID],
            pathMode: .fullPaths(
                authorization: .confirmed(for: fixture.exportID)
            )
        )
        let document = try JSONDecoder().decode(
            DiagnosticExportDocument.self,
            from: prepared.data
        )
        #expect(document.privacy.pathMode == .fullPaths)
        #expect(document.findings.first?.comparisonPath == fixture.rawPath)
        #expect(document.findings.first?.comparisonDisplayName == "Private Cache")
    }

    @Test("The bundle carries exact metadata, coverage, health, and frozen rule evidence")
    func preservesRequiredPathFreeEvidence() throws {
        let fixture = try makeFixture()
        let document = try JSONDecoder().decode(
            DiagnosticExportDocument.self,
            from: DiagnosticExportBuilder().prepare(
                source: fixture.source,
                exportID: fixture.exportID,
                selectedFindingIDs: [fixture.findingID],
                pathMode: .redacted(homeDirectory: "/Fixtures/Homes/alex"),
                redactionSalt: Data(repeating: 0x24, count: 32)
            ).data
        )
        let finding = try #require(document.findings.first)

        #expect(document.schemaVersion == 1)
        #expect(document.system.appVersion == "0.1.0 (42)")
        #expect(document.system.osVersion == "macOS fixture")
        #expect(document.system.architecture == "arm64")
        #expect(document.coverage.map(\.availability) == [.available])
        #expect(document.healthEvents.map(\.code) == ["event_stream_recovered"])
        #expect(finding.classification.kind == .classified)
        #expect(finding.classification.category == .developerTools)
        #expect(finding.classification.confidence == .high)
        #expect(finding.classification.ruleID == "developer.xcode.cache")
        #expect(finding.classification.ruleVersion == 3)
        #expect(finding.classification.catalogVersion == 7)
        #expect(finding.classification.evidenceCode == "home.library.caches.xcode")
    }

    @Test("Selection rejects duplicates, unknown IDs, and unbounded finding counts")
    func validatesSelectionAndBounds() throws {
        let fixture = try makeFixture()
        let missing = try HistoricalFindingRecordID(999)
        #expect(throws: DiagnosticExportError.duplicateFindingSelection) {
            _ = try DiagnosticExportBuilder().preview(
                source: fixture.source,
                exportID: fixture.exportID,
                selectedFindingIDs: [fixture.findingID, fixture.findingID],
                pathMode: .redacted(homeDirectory: nil)
            )
        }
        #expect(throws: DiagnosticExportError.unknownFindingSelection) {
            _ = try DiagnosticExportBuilder().preview(
                source: fixture.source,
                exportID: fixture.exportID,
                selectedFindingIDs: [missing],
                pathMode: .redacted(homeDirectory: nil)
            )
        }
        #expect(throws: DiagnosticExportError.tooManySelectedFindings) {
            _ = try DiagnosticExportBuilder().preview(
                source: fixture.source,
                exportID: fixture.exportID,
                selectedFindingIDs: (1...101).map {
                    try HistoricalFindingRecordID(Int64($0))
                },
                pathMode: .redacted(homeDirectory: nil)
            )
        }
    }

    @Test("Corrected finding identities can be selected without numeric source confusion")
    func exportsCorrectedFindingIdentity() throws {
        let correctedID = try HistoricalCorrectedFindingRecordID(1)
        let fixture = try makeFixture(findingVersionID: .corrected(correctedID))
        let prepared = try DiagnosticExportBuilder().prepare(
            source: fixture.source,
            exportID: fixture.exportID,
            selectedFindingVersionIDs: [.corrected(correctedID)],
            pathMode: .redacted(homeDirectory: "/Fixtures/Homes/alex")
        )
        let document = try JSONDecoder().decode(
            DiagnosticExportDocument.self,
            from: prepared.data
        )
        #expect(document.findings.count == 1)
        #expect(throws: DiagnosticExportError.unknownFindingSelection) {
            _ = try DiagnosticExportBuilder().prepare(
                source: fixture.source,
                exportID: fixture.exportID,
                selectedFindingIDs: [fixture.findingID],
                pathMode: .redacted(homeDirectory: "/Fixtures/Homes/alex")
            )
        }
    }

    @Test("Different export salts prevent cross-export path correlation")
    func saltsAreExportSpecific() throws {
        let fixture = try makeFixture()
        let first = try decodeFirstFinding(
            fixture: fixture,
            salt: Data(repeating: 0x11, count: 32)
        )
        let second = try decodeFirstFinding(
            fixture: fixture,
            salt: Data(repeating: 0x12, count: 32)
        )

        #expect(first.comparisonPath != second.comparisonPath)
        #expect(first.comparisonDisplayName != second.comparisonDisplayName)
    }
}

private struct DiagnosticExportFixture {
    let exportID: UUID
    let findingID: HistoricalFindingRecordID
    let findingVersionID: HistoricalFindingVersionID
    let rawPath: String
    let source: DiagnosticExportSource
}

private func makeFixture(
    findingVersionID: HistoricalFindingVersionID? = nil
) throws -> DiagnosticExportFixture {
    let exportID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    let scopeID = try WatchedScopeID("scope-private")
    let findingID = try HistoricalFindingRecordID(1)
    let effectiveFindingVersionID = findingVersionID ?? .original(findingID)
    let rawPath = "/Fixtures/Homes/alex/Secret Project/Private Cache"
    let finding = try HistoricalFindingOverviewItem(
        id: effectiveFindingVersionID,
        kind: .growth,
        metric: .allocated,
        inclusiveDeltaBytes: 4_096,
        rankingContributionBytes: 4_096,
        positiveRank: 1,
        baselinePath: rawPath,
        comparisonPath: rawPath,
        baselineDisplayName: "Private Cache",
        comparisonDisplayName: "Private Cache",
        baselineTime: ObservationInstant(millisecondsSince1970: 1_000),
        comparisonTime: ObservationInstant(millisecondsSince1970: 2_000),
        classification: .classified(
            category: .developerTools,
            confidence: .high,
            ruleID: AttributionRuleID("developer.xcode.cache"),
            ruleVersion: AttributionRuleVersion(3),
            catalogVersion: AttributionCatalogVersion(7),
            evidenceCode: AttributionEvidenceCode("home.library.caches.xcode")
        ),
        validity: .currentEffective
    )
    let source = try DiagnosticExportSource(
        generatedAt: ObservationInstant(millisecondsSince1970: 3_000),
        appVersion: "0.1.0 (42)",
        osVersion: "macOS fixture",
        architecture: "arm64",
        scopes: [
            DiagnosticExportScopeSource(
                scopeID: scopeID,
                rootPath: "/Fixtures/Homes/alex/Secret Project",
                availability: .available,
                findings: [finding]
            ),
        ],
        healthEvents: [
            try DiagnosticExportHealthEvent(
                code: "event_stream_recovered",
                severity: .notice,
                observedAt: ObservationInstant(millisecondsSince1970: 2_500),
                count: 1
            ),
        ]
    )
    return DiagnosticExportFixture(
        exportID: exportID,
        findingID: findingID,
        findingVersionID: effectiveFindingVersionID,
        rawPath: rawPath,
        source: source
    )
}

private func decodeFirstFinding(
    fixture: DiagnosticExportFixture,
    salt: Data
) throws -> DiagnosticExportFinding {
    let prepared = try DiagnosticExportBuilder().prepare(
        source: fixture.source,
        exportID: fixture.exportID,
        selectedFindingIDs: [fixture.findingID],
        pathMode: .redacted(homeDirectory: "/Fixtures/Homes/alex"),
        redactionSalt: salt
    )
    return try #require(
        JSONDecoder().decode(DiagnosticExportDocument.self, from: prepared.data)
            .findings.first
    )
}
