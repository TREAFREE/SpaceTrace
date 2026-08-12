import Foundation
import Testing
@testable import SpaceTraceAttribution
import SpaceTraceDomain

struct AttributionFixtureCorpusTests {
    @Test("Reviewed P0 corpus satisfies the Beta precision and coverage gate")
    func evaluatesVersionedCorpus() throws {
        let corpus = try loadCorpus()
        let classifier = DeterministicAttributionClassifier(
            catalog: try BuiltInAttributionCatalog.version1()
        )
        #expect(corpus.schemaVersion == 2)
        #expect(corpus.catalogVersion == classifier.catalog.version.rawValue)

        let ruleContracts = try corpus.validatedRuleContracts()
        try corpus.validateCaseIDs()
        try validateCatalog(classifier.catalog, against: ruleContracts)
        let knownCasesByRule = Dictionary(
            grouping: corpus.cases.compactMap(\.expectedRuleID),
            by: { $0 }
        )
        for ruleID in ruleContracts.keys {
            #expect(knownCasesByRule[ruleID, default: []].count >= 2, "Rule: \(ruleID)")
        }

        let cases = try corpus.cases.map {
            try $0.evaluationCase(ruleContracts: ruleContracts)
        }
        let report = AttributionFixtureEvaluator().evaluate(cases, with: classifier)

        #expect(report.known.expected == 64)
        #expect(report.known.predicted == 64)
        #expect(report.known.correct == 64)
        #expect(try #require(report.known.precision) >= 0.95)
        #expect(report.known.precision == 1)
        #expect(report.known.recall == 1)
        #expect(report.unknown.total == 32)
        #expect(report.unknown.correct == 32)
        #expect(report.unknown.accuracy == 1)
        for category in StorageAttributionCategory.allCases {
            #expect(report.knownByCategory[category]?.expected == 8)
            #expect(report.knownByCategory[category]?.predicted == 8)
            #expect(report.knownByCategory[category]?.precision == 1)
            #expect(report.knownByCategory[category]?.recall == 1)
        }

        for fixtureCase in corpus.cases {
            try fixtureCase.validateExactDecision(
                classifier.classify(try fixtureCase.input),
                ruleContracts: ruleContracts
            )
        }
    }
}

private struct FixtureCorpus: Decodable {
    let schemaVersion: Int
    let catalogVersion: Int
    let ruleContracts: [FixtureRuleContract]
    let cases: [FixtureCase]

    func validatedRuleContracts() throws -> [String: FixtureRuleContract] {
        var result: [String: FixtureRuleContract] = [:]
        for contract in ruleContracts {
            guard result.updateValue(contract, forKey: contract.ruleID) == nil else {
                throw FixtureError.duplicateRuleContract(contract.ruleID)
            }
            _ = try contract.attribution
        }
        return result
    }

    func validateCaseIDs() throws {
        var observed: Set<String> = []
        for fixtureCase in cases {
            let id = fixtureCase.id
            guard id.isEmpty == false,
                  id.utf8.allSatisfy({
                      ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45
                  })
            else {
                throw FixtureError.invalidCaseID(id)
            }
            guard observed.insert(id).inserted else {
                throw FixtureError.duplicateCaseID(id)
            }
        }
    }
}

private struct FixtureRuleContract: Decodable {
    let ruleID: String
    let ruleVersion: Int
    let category: StorageAttributionCategory
    let confidence: AttributionConfidence
    let evidenceCode: String

    var attribution: StorageAttribution {
        get throws {
            try StorageAttribution(
                category: category,
                confidence: confidence,
                ruleID: AttributionRuleID(ruleID),
                ruleVersion: AttributionRuleVersion(ruleVersion),
                evidenceCode: AttributionEvidenceCode(evidenceCode)
            )
        }
    }
}

private struct FixtureCase: Decodable {
    let id: String
    let absolutePath: String
    let homeDirectory: String?
    let bundleIdentifier: String?
    let snapshotFactorObservation: SnapshotFactorObservation?
    let expectedRuleID: String?
    let expectedUnknown: FixtureUnknownReason?

    var input: AttributionInput {
        get throws {
            try AttributionInput(
                absolutePath: absolutePath,
                homeDirectory: homeDirectory,
                bundleIdentifier: bundleIdentifier,
                volumeContext: .init(snapshotFactorObservation: snapshotFactorObservation ?? .none)
            )
        }
    }

    func evaluationCase(
        ruleContracts: [String: FixtureRuleContract]
    ) throws -> AttributionEvaluationCase {
        if let expectedRuleID, expectedUnknown == nil {
            guard let contract = ruleContracts[expectedRuleID] else {
                throw FixtureError.missingRuleContract(expectedRuleID)
            }
            return AttributionEvaluationCase(
                id: id,
                input: try input,
                expected: .classified(contract.category)
            )
        }
        if expectedRuleID == nil, let expectedUnknown {
            return AttributionEvaluationCase(
                id: id,
                input: try input,
                expected: .unknown(expectedUnknown.attributionReason)
            )
        }
        throw FixtureError.invalidExpectation(id)
    }

    func validateExactDecision(
        _ actual: AttributionClassificationResult,
        ruleContracts: [String: FixtureRuleContract]
    ) throws {
        if let expectedRuleID, expectedUnknown == nil {
            guard let contract = ruleContracts[expectedRuleID] else {
                throw FixtureError.missingRuleContract(expectedRuleID)
            }
            #expect(actual == .classified(try contract.attribution), "Fixture: \(id)")
            return
        }
        if expectedRuleID == nil, let expectedUnknown {
            switch (expectedUnknown, actual) {
            case (.noMatchingRule, .unknown(.noMatchingRule)):
                return
            case (.ambiguous, .unknown(.ambiguous)):
                return
            default:
                Issue.record("Fixture \(id) did not preserve its expected Unknown reason")
                return
            }
        }
        throw FixtureError.invalidExpectation(id)
    }
}

private enum FixtureUnknownReason: String, Decodable {
    case noMatchingRule = "no_matching_rule"
    case ambiguous

    var attributionReason: AttributionExpectedUnknownReason {
        switch self {
        case .noMatchingRule: .noMatchingRule
        case .ambiguous: .ambiguous
        }
    }
}

private enum FixtureError: Error {
    case missingResource
    case invalidExpectation(String)
    case invalidCaseID(String)
    case duplicateCaseID(String)
    case duplicateRuleContract(String)
    case missingRuleContract(String)
}

private func loadCorpus() throws -> FixtureCorpus {
    guard let url = Bundle.module.url(
        forResource: "attribution-fixtures-v2",
        withExtension: "json",
        subdirectory: "Fixtures"
    ) else {
        throw FixtureError.missingResource
    }
    return try JSONDecoder().decode(FixtureCorpus.self, from: Data(contentsOf: url))
}

private func validateCatalog(
    _ catalog: AttributionRuleCatalog,
    against contracts: [String: FixtureRuleContract]
) throws {
    #expect(contracts.count == catalog.rules.count)
    #expect(Set(contracts.keys) == Set(catalog.rules.map(\.ruleID.rawValue)))
    for rule in catalog.rules {
        let contract = try #require(contracts[rule.ruleID.rawValue])
        #expect(rule.attribution == (try contract.attribution))
    }
}
