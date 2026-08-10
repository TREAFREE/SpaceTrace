import Foundation
import Testing
@testable import SpaceTraceAttribution
import SpaceTraceDomain

struct VersionedAttributionDecisionTests {
    @Test("Classified decisions preserve independent catalog and winning-rule versions")
    func classifiedDecisionRoundTripsWithIndependentVersions() throws {
        let attribution = try StorageAttribution(
            category: .developerTools,
            confidence: .high,
            ruleID: AttributionRuleID("developer.fixture"),
            ruleVersion: AttributionRuleVersion(3),
            evidenceCode: AttributionEvidenceCode("fixture.developer")
        )
        let decision = try VersionedAttributionDecision(
            catalogVersion: try AttributionCatalogVersion(41),
            result: .classified(attribution)
        )

        let decoded = try roundTrip(decision)

        #expect(decoded == decision)
        #expect(decoded.catalogVersion.rawValue == 41)
        guard case .classified(let persistedAttribution) = decoded.result else {
            Issue.record("Expected a classified durable decision")
            return
        }
        #expect(persistedAttribution.ruleVersion.rawValue == 3)
    }

    @Test("A no-match decision round trips without inventing a category")
    func noMatchDecisionRoundTrips() throws {
        let decision = try VersionedAttributionDecision(
            catalogVersion: try AttributionCatalogVersion(5),
            result: .unknown(.noMatchingRule)
        )

        #expect(try roundTrip(decision) == decision)
    }

    @Test("Every durable decision kind has a stable explicit JSON shape")
    func durableWireFormatIsExplicit() throws {
        let attribution = try StorageAttribution(
            category: .games,
            confidence: .high,
            ruleID: AttributionRuleID("games.fixture"),
            ruleVersion: AttributionRuleVersion(3),
            evidenceCode: AttributionEvidenceCode("fixture.games")
        )
        let classified = try VersionedAttributionDecision(
            catalogVersion: try AttributionCatalogVersion(5),
            result: .classified(attribution)
        )
        let noMatch = try VersionedAttributionDecision(
            catalogVersion: try AttributionCatalogVersion(5),
            result: .unknown(.noMatchingRule)
        )
        let ambiguous = try VersionedAttributionDecision(
            catalogVersion: try AttributionCatalogVersion(5),
            result: .unknown(.ambiguous(ruleIDs: [
                AttributionRuleID("a.rule"),
                AttributionRuleID("z.rule"),
            ]))
        )

        try expectEquivalentJSON(
            JSONEncoder().encode(classified),
            #"""
            {"catalogVersion":5,"result":{"kind":"classified","attribution":{
              "category":"games","confidence":"high","ruleID":"games.fixture",
              "ruleVersion":3,"evidenceCode":"fixture.games"
            }}}
            """#
        )
        try expectEquivalentJSON(
            JSONEncoder().encode(noMatch),
            #"{"catalogVersion":5,"result":{"kind":"unknown","reason":{"kind":"no_matching_rule"}}}"#
        )
        try expectEquivalentJSON(
            JSONEncoder().encode(ambiguous),
            #"""
            {"catalogVersion":5,"result":{"kind":"unknown","reason":{
              "kind":"ambiguous","ruleIDs":["a.rule","z.rule"]
            }}}
            """#
        )
    }

    @Test("An ambiguous decision round trips with binary-ascending competing rule IDs")
    func ambiguousDecisionRoundTripsInCanonicalOrder() throws {
        let first = try AttributionRuleID("rule.10")
        let second = try AttributionRuleID("rule.2")
        let decision = try VersionedAttributionDecision(
            catalogVersion: try AttributionCatalogVersion(5),
            result: .unknown(.ambiguous(ruleIDs: [first, second]))
        )

        let decoded = try roundTrip(decision)

        #expect(decoded == decision)
        #expect(decoded.result == .unknown(.ambiguous(ruleIDs: [first, second])))
    }

    @Test("Durable ambiguity rejects fewer than two, duplicate, and non-canonical rule IDs")
    func rejectsInvalidAmbiguousRuleIDs() throws {
        let first = try AttributionRuleID("a.rule")
        let second = try AttributionRuleID("z.rule")
        let catalogVersion = try AttributionCatalogVersion(5)
        let invalidRuleIDSets = [
            [AttributionRuleID](),
            [first],
            [first, first],
            [second, first],
        ]

        for ruleIDs in invalidRuleIDSets {
            #expect(throws: AttributionDecisionValidationError.invalidAmbiguousRuleIDs) {
                try VersionedAttributionDecision(
                    catalogVersion: catalogVersion,
                    result: .unknown(.ambiguous(ruleIDs: ruleIDs))
                )
            }
            #expect(throws: EncodingError.self) {
                try JSONEncoder().encode(
                    AttributionClassificationResult.unknown(
                        .ambiguous(ruleIDs: ruleIDs)
                    )
                )
            }
        }
    }

    @Test("Decoding revalidates every durable ambiguity invariant")
    func decodingRejectsInvalidAmbiguousRuleIDs() throws {
        let first = try AttributionRuleID("a.rule")
        let second = try AttributionRuleID("z.rule")
        let valid = try VersionedAttributionDecision(
            catalogVersion: try AttributionCatalogVersion(5),
            result: .unknown(.ambiguous(ruleIDs: [first, second]))
        )
        let encoded = try JSONEncoder().encode(valid)
        let invalidRuleIDSets = [
            [String](),
            ["a.rule"],
            ["a.rule", "a.rule"],
            ["z.rule", "a.rule"],
        ]

        for ruleIDs in invalidRuleIDSets {
            let malicious = try replacingRuleIDs(in: encoded, with: ruleIDs)
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(
                    VersionedAttributionDecision.self,
                    from: malicious
                )
            }
        }
    }

    @Test("Decoding rejects contradictory discriminated-union payloads")
    func decodingRejectsContradictoryPayloads() {
        let attribution = #"""
        {"category":"games","confidence":"high","ruleID":"games.fixture",
         "ruleVersion":3,"evidenceCode":"fixture.games"}
        """#
        let maliciousPayloads = [
            #"""
            {"catalogVersion":5,"result":{"kind":"classified",
             "attribution":\#(attribution),"reason":{"kind":"no_matching_rule"}}}
            """#,
            #"""
            {"catalogVersion":5,"result":{"kind":"unknown",
             "reason":{"kind":"no_matching_rule"},"attribution":\#(attribution)}}
            """#,
            #"{"catalogVersion":5,"result":{"kind":"unknown","reason":{"kind":"no_matching_rule","ruleIDs":null}}}"#,
        ]

        for payload in maliciousPayloads {
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(
                    VersionedAttributionDecision.self,
                    from: Data(payload.utf8)
                )
            }
        }
    }

    @Test("Unknown fields cannot be silently dropped from immutable evidence")
    func decodingRejectsUnknownFieldsAtEveryLevel() {
        let maliciousPayloads = [
            #"{"catalogVersion":5,"result":{"kind":"unknown","reason":{"kind":"no_matching_rule"}},"future":true}"#,
            #"{"catalogVersion":5,"result":{"kind":"unknown","reason":{"kind":"no_matching_rule"},"future":true}}"#,
            #"{"catalogVersion":5,"result":{"kind":"unknown","reason":{"kind":"no_matching_rule","future":true}}}"#,
            #"""
            {"catalogVersion":5,"result":{"kind":"classified","attribution":{
              "category":"games","confidence":"high","ruleID":"games.fixture",
              "ruleVersion":3,"evidenceCode":"fixture.games","future":true
            }}}
            """#,
        ]

        for payload in maliciousPayloads {
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(
                    VersionedAttributionDecision.self,
                    from: Data(payload.utf8)
                )
            }
        }
    }

    @Test("Versioned classification wraps the exact legacy result for every outcome")
    func versionedClassificationMatchesLegacyClassification() throws {
        let classifier = try makeVersionedClassifier()
        let inputs = [
            try AttributionInput(
                absolutePath: "/Fixtures/Home/Library/Caches/item",
                homeDirectory: "/Fixtures/Home"
            ),
            try AttributionInput(
                absolutePath: "/Fixtures/Home/Shared/item",
                homeDirectory: "/Fixtures/Home"
            ),
            try AttributionInput(
                absolutePath: "/Fixtures/Home/Documents/item",
                homeDirectory: "/Fixtures/Home"
            ),
        ]

        for input in inputs {
            let legacy = classifier.classify(input)
            let versioned = classifier.classifyVersioned(input)

            #expect(versioned.catalogVersion.rawValue == 41)
            #expect(versioned.result == legacy)
        }
    }

    @Test("Catalog evolution does not rewrite the winning rule version")
    func catalogAndRuleVersionsEvolveIndependently() throws {
        let rule = try makeVersionedRule(
            id: "cache.rule",
            version: 3,
            category: .logsAndCaches,
            path: ["Library", "Caches"]
        )
        let input = try AttributionInput(
            absolutePath: "/Fixtures/Home/Library/Caches/item",
            homeDirectory: "/Fixtures/Home"
        )
        let oldCatalog = try DeterministicAttributionClassifier(
            catalog: AttributionRuleCatalog(
                version: AttributionCatalogVersion(40),
                rules: [rule]
            )
        )
        let newCatalog = try DeterministicAttributionClassifier(
            catalog: AttributionRuleCatalog(
                version: AttributionCatalogVersion(41),
                rules: [rule]
            )
        )

        let oldDecision = oldCatalog.classifyVersioned(input)
        let newDecision = newCatalog.classifyVersioned(input)

        #expect(oldDecision.catalogVersion.rawValue == 40)
        #expect(newDecision.catalogVersion.rawValue == 41)
        #expect(oldDecision.result == newDecision.result)
        guard case .classified(let attribution) = newDecision.result else {
            Issue.record("Expected the unchanged rule to classify the fixture")
            return
        }
        #expect(attribution.ruleVersion.rawValue == 3)
    }
}

private func roundTrip(
    _ decision: VersionedAttributionDecision
) throws -> VersionedAttributionDecision {
    let encoded = try JSONEncoder().encode(decision)
    return try JSONDecoder().decode(VersionedAttributionDecision.self, from: encoded)
}

private func expectEquivalentJSON(
    _ actualData: Data,
    _ expectedJSON: String
) throws {
    let actual = try JSONSerialization.jsonObject(with: actualData)
    let expected = try JSONSerialization.jsonObject(
        with: Data(expectedJSON.utf8)
    )
    let options: JSONSerialization.WritingOptions = [.sortedKeys]
    let actualCanonical = try JSONSerialization.data(
        withJSONObject: actual,
        options: options
    )
    let expectedCanonical = try JSONSerialization.data(
        withJSONObject: expected,
        options: options
    )

    #expect(actualCanonical == expectedCanonical)
}

private func replacingRuleIDs(in data: Data, with ruleIDs: [String]) throws -> Data {
    let object = try JSONSerialization.jsonObject(with: data)
    var replaced = false

    func replacing(in value: Any) -> Any {
        if var dictionary = value as? [String: Any] {
            for key in Array(dictionary.keys) {
                if key == "ruleIDs" {
                    dictionary[key] = ruleIDs
                    replaced = true
                } else if let child = dictionary[key] {
                    dictionary[key] = replacing(in: child)
                }
            }
            return dictionary
        }
        if let array = value as? [Any] {
            return array.map { replacing(in: $0) }
        }
        return value
    }

    let malicious = replacing(in: object)
    guard replaced else {
        throw VersionedAttributionDecisionFixtureError.missingRuleIDs
    }
    return try JSONSerialization.data(withJSONObject: malicious)
}

private func makeVersionedClassifier() throws -> DeterministicAttributionClassifier {
    try DeterministicAttributionClassifier(
        catalog: AttributionRuleCatalog(
            version: AttributionCatalogVersion(41),
            rules: [
                makeVersionedRule(
                    id: "cache.rule",
                    version: 3,
                    category: .logsAndCaches,
                    path: ["Library", "Caches"]
                ),
                makeVersionedRule(
                    id: "z.shared",
                    version: 8,
                    category: .games,
                    path: ["Shared"]
                ),
                makeVersionedRule(
                    id: "a.shared",
                    version: 13,
                    category: .virtualization,
                    path: ["Shared"]
                ),
            ]
        )
    )
}

private func makeVersionedRule(
    id: String,
    version: Int,
    category: StorageAttributionCategory,
    path: [String]
) throws -> AttributionRule {
    try AttributionRule(
        id: AttributionRuleID(id),
        version: AttributionRuleVersion(version),
        category: category,
        confidence: .high,
        evidenceCode: AttributionEvidenceCode(id),
        matcher: AttributionRuleMatcher(homeRelativePrefix: path)
    )
}

private enum VersionedAttributionDecisionFixtureError: Error {
    case missingRuleIDs
}
