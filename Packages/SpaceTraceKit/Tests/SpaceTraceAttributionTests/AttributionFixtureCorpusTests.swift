import Foundation
import Testing
@testable import SpaceTraceAttribution
import SpaceTraceDomain

struct AttributionFixtureCorpusTests {
    @Test("Versioned P0 fixtures remain deterministic and conservative")
    func evaluatesVersionedCorpus() throws {
        let corpus = try loadCorpus()
        let classifier = DeterministicAttributionClassifier(
            catalog: try BuiltInAttributionCatalog.version1()
        )
        #expect(corpus.schemaVersion == 1)
        #expect(corpus.catalogVersion == classifier.catalog.version.rawValue)

        let cases = try corpus.cases.map { try $0.evaluationCase }
        let report = AttributionFixtureEvaluator().evaluate(cases, with: classifier)

        #expect(report.known.expected == 24)
        #expect(report.known.predicted == 24)
        #expect(report.known.correct == 24)
        #expect(report.known.precision == 1)
        #expect(report.known.recall == 1)
        #expect(report.unknown.total == 8)
        #expect(report.unknown.correct == 8)
        #expect(report.unknown.accuracy == 1)
        for category in StorageAttributionCategory.allCases {
            #expect(report.knownByCategory[category]?.expected == 3)
            #expect(report.knownByCategory[category]?.predicted == 3)
            #expect(report.knownByCategory[category]?.precision == 1)
            #expect(report.knownByCategory[category]?.recall == 1)
        }
    }
}

private struct FixtureCorpus: Decodable {
    let schemaVersion: Int
    let catalogVersion: Int
    let cases: [FixtureCase]
}

private struct FixtureCase: Decodable {
    let id: String
    let absolutePath: String
    let homeDirectory: String?
    let bundleIdentifier: String?
    let snapshotFactorObservation: SnapshotFactorObservation?
    let expectedCategory: StorageAttributionCategory?
    let expectedUnknown: FixtureUnknownReason?

    var evaluationCase: AttributionEvaluationCase {
        get throws {
            let input = try AttributionInput(
                absolutePath: absolutePath,
                homeDirectory: homeDirectory,
                bundleIdentifier: bundleIdentifier,
                volumeContext: .init(snapshotFactorObservation: snapshotFactorObservation ?? .none)
            )

            if let expectedCategory, expectedUnknown == nil {
                return AttributionEvaluationCase(
                    id: id,
                    input: input,
                    expected: .classified(expectedCategory)
                )
            }
            if expectedCategory == nil, let expectedUnknown {
                return AttributionEvaluationCase(
                    id: id,
                    input: input,
                    expected: .unknown(expectedUnknown.attributionReason)
                )
            }
            throw FixtureError.invalidExpectation(id)
        }
    }
}

private enum FixtureUnknownReason: String, Decodable {
    case noMatchingRule = "no_matching_rule"

    var attributionReason: AttributionExpectedUnknownReason {
        switch self {
        case .noMatchingRule: .noMatchingRule
        }
    }
}

private enum FixtureError: Error {
    case missingResource
    case invalidExpectation(String)
}

private func loadCorpus() throws -> FixtureCorpus {
    guard let url = Bundle.module.url(
        forResource: "attribution-fixtures-v1",
        withExtension: "json",
        subdirectory: "Fixtures"
    ) else {
        throw FixtureError.missingResource
    }
    return try JSONDecoder().decode(FixtureCorpus.self, from: Data(contentsOf: url))
}
