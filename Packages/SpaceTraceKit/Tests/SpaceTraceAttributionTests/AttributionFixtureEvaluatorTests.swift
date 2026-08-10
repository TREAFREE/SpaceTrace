import Testing
@testable import SpaceTraceAttribution
import SpaceTraceDomain

struct AttributionFixtureEvaluatorTests {
    @Test("Precision, recall, and Unknown accuracy use distinct denominators")
    func metricsDoNotOverstateCoverage() throws {
        let classifier = try classifier([
            try rule(id: "games.shared", category: .games, path: ["Shared"]),
        ])
        let cases = [
            try evaluation("correct", "/Users/alex/Shared/game", .classified(.games)),
            try evaluation("false-positive", "/Users/alex/Shared/document", .unknown(.noMatchingRule)),
            try evaluation("false-negative", "/Users/alex/Games/missing", .classified(.games)),
        ]

        let report = AttributionFixtureEvaluator().evaluate(cases, with: classifier)

        #expect(report.known.expected == 2)
        #expect(report.known.predicted == 2)
        #expect(report.known.correct == 1)
        #expect(report.known.precision == 0.5)
        #expect(report.known.recall == 0.5)
        #expect(report.unknown.accuracy == 0)
    }

    @Test("Expected ambiguity counts only an actual cross-category tie")
    func measuresAmbiguity() throws {
        let classifier = try classifier([
            try rule(id: "a.rule", category: .games, path: ["Shared"]),
            try rule(id: "b.rule", category: .virtualization, path: ["Shared"]),
        ])
        let testCase = try evaluation(
            "ambiguous",
            "/Users/alex/Shared/item",
            .unknown(.ambiguous)
        )

        let report = AttributionFixtureEvaluator().evaluate([testCase], with: classifier)

        #expect(report.unknown.total == 1)
        #expect(report.unknown.correct == 1)
        #expect(report.unknown.accuracy == 1)
        #expect(report.known.precision == nil)
        #expect(report.known.recall == nil)
    }
}

private func classifier(_ rules: [AttributionRule]) throws -> DeterministicAttributionClassifier {
    try DeterministicAttributionClassifier(
        catalog: AttributionRuleCatalog(
            version: AttributionCatalogVersion(1),
            rules: rules
        )
    )
}

private func rule(
    id: String,
    category: StorageAttributionCategory,
    path: [String]
) throws -> AttributionRule {
    try AttributionRule(
        id: AttributionRuleID(id),
        version: AttributionRuleVersion(1),
        category: category,
        confidence: .high,
        evidenceCode: AttributionEvidenceCode(id),
        matcher: AttributionRuleMatcher(homeRelativePrefix: path)
    )
}

private func evaluation(
    _ id: String,
    _ path: String,
    _ expected: AttributionEvaluationExpectation
) throws -> AttributionEvaluationCase {
    try AttributionEvaluationCase(
        id: id,
        input: AttributionInput(absolutePath: path, homeDirectory: "/Users/alex"),
        expected: expected
    )
}
