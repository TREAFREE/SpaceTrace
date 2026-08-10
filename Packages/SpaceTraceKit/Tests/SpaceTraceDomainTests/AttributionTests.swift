import Foundation
import Testing
@testable import SpaceTraceDomain

struct AttributionTests {
    @Test("Storage attribution categories have stable persisted codes")
    func categoryCodesAreStable() {
        #expect(StorageAttributionCategory.allCases.map(\.rawValue) == [
            "developer_tools",
            "virtualization",
            "ai_models_and_caches",
            "creative_caches_and_render_data",
            "games",
            "logs_and_caches",
            "cloud_local_data",
            "snapshot_factors",
        ])
    }

    @Test("Rejects blank stable identifiers", arguments: ["", " ", "\n\t"])
    func rejectsBlankIdentifiers(value: String) {
        #expect(throws: AttributionValidationError.emptyRuleID) {
            try AttributionRuleID(value)
        }
        #expect(throws: AttributionValidationError.emptyEvidenceCode) {
            try AttributionEvidenceCode(value)
        }
    }

    @Test("Stable identifiers cannot contain paths or display text", arguments: [
        "developer/xcode",
        "developer\\xcode",
        "Developer Xcode",
        "开发工具",
    ])
    func rejectsNonCodeIdentifiers(value: String) {
        #expect(throws: AttributionValidationError.invalidRuleID) {
            try AttributionRuleID(value)
        }
        #expect(throws: AttributionValidationError.invalidEvidenceCode) {
            try AttributionEvidenceCode(value)
        }
    }

    @Test("Rejects non-positive rule versions", arguments: [Int.min, -1, 0])
    func rejectsNonPositiveVersions(value: Int) {
        #expect(throws: AttributionValidationError.invalidRuleVersion(value)) {
            try AttributionRuleVersion(value)
        }
    }

    @Test(
        "Catalog versions are positive identifiers independent from rule versions",
        arguments: [Int.min, -1, 0]
    )
    func rejectsNonPositiveCatalogVersions(value: Int) {
        #expect(throws: AttributionValidationError.invalidCatalogVersion(value)) {
            try AttributionCatalogVersion(value)
        }
    }

    @Test("Catalog version decoding revalidates the durable positive-value invariant")
    func catalogVersionRoundTripsAndRejectsMaliciousPayloads() throws {
        let version = try AttributionCatalogVersion(7)

        let encoded = try JSONEncoder().encode(version)
        let decoded = try JSONDecoder().decode(AttributionCatalogVersion.self, from: encoded)

        #expect(decoded == version)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                AttributionCatalogVersion.self,
                from: Data("0".utf8)
            )
        }
    }

    @Test("Round-trips a durable successful attribution")
    func roundTripsAttribution() throws {
        let attribution = try StorageAttribution(
            category: .developerTools,
            confidence: .high,
            ruleID: AttributionRuleID("developer.xcode.derived-data"),
            ruleVersion: AttributionRuleVersion(1),
            evidenceCode: AttributionEvidenceCode("home.library.developer.xcode.derived-data")
        )

        let encoded = try JSONEncoder().encode(attribution)
        let decoded = try JSONDecoder().decode(StorageAttribution.self, from: encoded)

        #expect(decoded == attribution)
    }

    @Test("Unknown confidence cannot masquerade as a successful attribution")
    func rejectsUnknownConfidence() throws {
        #expect(throws: AttributionValidationError.unknownConfidenceCannotClassify) {
            try StorageAttribution(
                category: .logsAndCaches,
                confidence: .unknown,
                ruleID: AttributionRuleID("generic.cache"),
                ruleVersion: AttributionRuleVersion(1),
                evidenceCode: AttributionEvidenceCode("home.library.caches")
            )
        }
    }

    @Test("Decoding revalidates persisted attribution invariants")
    func decodingRejectsInvalidAttribution() {
        let invalid = Data(#"""
        {"category":"games","confidence":"unknown","ruleID":"game.steam",
         "ruleVersion":1,"evidenceCode":"home.steam.steamapps"}
        """#.utf8)
        let unknownField = Data(#"""
        {"category":"games","confidence":"high","ruleID":"game.steam",
         "ruleVersion":1,"evidenceCode":"home.steam.steamapps","future":true}
        """#.utf8)

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(StorageAttribution.self, from: invalid)
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(StorageAttribution.self, from: unknownField)
        }
    }
}
