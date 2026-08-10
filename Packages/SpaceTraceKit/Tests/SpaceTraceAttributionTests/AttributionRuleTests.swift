import Testing
@testable import SpaceTraceAttribution
import SpaceTraceDomain

struct AttributionRuleTests {
    @Test("A catalog rejects duplicate stable rule identifiers")
    func rejectsDuplicateRuleIDs() throws {
        let first = try makeRule(id: "test.duplicate", components: ["Library", "Caches"])
        let second = try makeRule(id: "test.duplicate", components: ["Library", "Logs"])

        #expect(throws: AttributionRuleValidationError.duplicateRuleID(first.ruleID)) {
            try AttributionRuleCatalog(version: AttributionRuleVersion(1), rules: [first, second])
        }
    }

    @Test("A catalog cannot silently classify nothing")
    func rejectsEmptyCatalog() throws {
        #expect(throws: AttributionRuleValidationError.emptyCatalog) {
            try AttributionRuleCatalog(version: AttributionRuleVersion(1), rules: [])
        }
    }

    @Test("A rule requires at least one explicit matcher")
    func rejectsEmptyMatcher() throws {
        #expect(throws: AttributionRuleValidationError.emptyMatcher) {
            try AttributionRule(
                id: AttributionRuleID("test.empty"),
                version: AttributionRuleVersion(1),
                category: .logsAndCaches,
                confidence: .medium,
                evidenceCode: AttributionEvidenceCode("test.empty"),
                priority: 0,
                matcher: AttributionRuleMatcher()
            )
        }
    }

    @Test("Path patterns use complete normalized components", arguments: [
        [String](),
        ["Library/Caches"],
        ["."],
        [".."],
        ["bad\0component"],
    ])
    func rejectsInvalidPatterns(components: [String]) {
        #expect(throws: AttributionRuleValidationError.invalidPathPattern) {
            try AttributionRuleMatcher(homeRelativePrefix: components)
        }
    }

    @Test("A rule cannot classify with unknown confidence")
    func rejectsUnknownConfidence() throws {
        #expect(throws: AttributionRuleValidationError.unknownConfidence) {
            try AttributionRule(
                id: AttributionRuleID("test.unknown"),
                version: AttributionRuleVersion(1),
                category: .games,
                confidence: .unknown,
                evidenceCode: AttributionEvidenceCode("test.unknown"),
                matcher: AttributionRuleMatcher(homeRelativePrefix: ["Games"])
            )
        }
    }

    @Test("Matcher metadata remains explicit and validated")
    func validatesMetadataMatchers() {
        #expect(throws: AttributionRuleValidationError.invalidBundleIdentifier) {
            try AttributionRuleMatcher(bundleIdentifier: "com.example/app")
        }
        #expect(throws: AttributionRuleValidationError.invalidSnapshotObservation) {
            try AttributionRuleMatcher(snapshotFactorObservation: SnapshotFactorObservation.none)
        }
    }
}

private func makeRule(
    id: String,
    components: [String],
    category: StorageAttributionCategory = .logsAndCaches
) throws -> AttributionRule {
    try AttributionRule(
        id: AttributionRuleID(id),
        version: AttributionRuleVersion(1),
        category: category,
        confidence: .high,
        evidenceCode: AttributionEvidenceCode(id),
        matcher: AttributionRuleMatcher(homeRelativePrefix: components)
    )
}
