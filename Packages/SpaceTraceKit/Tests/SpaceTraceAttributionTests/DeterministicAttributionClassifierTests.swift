import Testing
@testable import SpaceTraceAttribution
import SpaceTraceDomain

struct DeterministicAttributionClassifierTests {
    @Test("Returns Unknown when no exact rule matches")
    func returnsUnknownForNoMatch() throws {
        let classifier = try makeClassifier([
            makeRule(id: "generic.caches", category: .logsAndCaches, path: ["Library", "Caches"]),
        ])
        let input = try AttributionInput(
            absolutePath: "/Users/alex/Documents/Cache Notes",
            homeDirectory: "/Users/alex"
        )

        #expect(classifier.classify(input) == .unknown(.noMatchingRule))
    }

    @Test("Matches only complete component prefixes")
    func matchesComponentBoundaries() throws {
        let classifier = try makeClassifier([
            makeRule(id: "generic.caches", category: .logsAndCaches, path: ["Library", "Caches"]),
        ])
        let nearMiss = try AttributionInput(
            absolutePath: "/Users/alex/Library/CachesBackup/item",
            homeDirectory: "/Users/alex"
        )

        #expect(classifier.classify(nearMiss) == .unknown(.noMatchingRule))
    }

    @Test("A specific rule outranks a generic rule at equal priority")
    func specificRuleWins() throws {
        let classifier = try makeClassifier([
            makeRule(id: "generic.caches", category: .logsAndCaches, path: ["Library", "Caches"]),
            makeRule(
                id: "developer.xcode.cache",
                category: .developerTools,
                path: ["Library", "Caches", "com.apple.dt.Xcode"]
            ),
        ])
        let input = try AttributionInput(
            absolutePath: "/Users/alex/Library/Caches/com.apple.dt.Xcode/index",
            homeDirectory: "/Users/alex"
        )

        let result = classifier.classify(input)
        let attribution = try #require(result.attribution)
        #expect(attribution.category == .developerTools)
        #expect(attribution.ruleID.rawValue == "developer.xcode.cache")
    }

    @Test("Explicit priority outranks path specificity")
    func priorityWinsBeforeSpecificity() throws {
        let classifier = try makeClassifier([
            makeRule(
                id: "high.priority",
                category: .creativeCachesAndRenderData,
                path: ["Library", "Caches"],
                priority: 10
            ),
            makeRule(
                id: "longer.path",
                category: .developerTools,
                path: ["Library", "Caches", "com.apple.dt.Xcode"],
                priority: 0
            ),
        ])
        let input = try AttributionInput(
            absolutePath: "/Users/alex/Library/Caches/com.apple.dt.Xcode",
            homeDirectory: "/Users/alex"
        )

        #expect(classifier.classify(input).attribution?.ruleID.rawValue == "high.priority")
    }

    @Test("Equal winners from different categories fail closed as ambiguity")
    func crossCategoryTieIsAmbiguous() throws {
        let classifier = try makeClassifier([
            makeRule(id: "z.rule", category: .games, path: ["Shared"]),
            makeRule(id: "a.rule", category: .virtualization, path: ["Shared"]),
        ])
        let input = try AttributionInput(
            absolutePath: "/Users/alex/Shared/data",
            homeDirectory: "/Users/alex"
        )

        #expect(classifier.classify(input) == .unknown(.ambiguous(ruleIDs: [
            try AttributionRuleID("a.rule"),
            try AttributionRuleID("z.rule"),
        ])))
    }

    @Test("Equal winners in one category select the stable rule-ID order")
    func sameCategoryTieIsStable() throws {
        let input = try AttributionInput(
            absolutePath: "/Users/alex/Shared/data",
            homeDirectory: "/Users/alex"
        )
        let rules = [
            try makeRule(id: "z.rule", category: .games, path: ["Shared"]),
            try makeRule(id: "a.rule", category: .games, path: ["Shared"]),
        ]
        let forward = try makeClassifier(rules).classify(input)
        let reversed = try makeClassifier(rules.reversed()).classify(input)

        #expect(forward.attribution?.ruleID.rawValue == "a.rule")
        #expect(reversed == forward)
    }

    @Test("Snapshot names alone are insufficient; explicit context is required")
    func snapshotRequiresContext() throws {
        let rule = try AttributionRule(
            id: AttributionRuleID("snapshot.local"),
            version: AttributionRuleVersion(1),
            category: .snapshotFactors,
            confidence: .high,
            evidenceCode: AttributionEvidenceCode("context.snapshot.local"),
            matcher: AttributionRuleMatcher(snapshotFactorObservation: .localAPFSSnapshot)
        )
        let classifier = try makeClassifier([rule])
        let namedOnly = try AttributionInput(absolutePath: "/Users/alex/Snapshots")
        let observed = try AttributionInput(
            absolutePath: "/Users/alex/anything",
            volumeContext: .init(snapshotFactorObservation: .localAPFSSnapshot)
        )

        #expect(classifier.classify(namedOnly) == .unknown(.noMatchingRule))
        #expect(classifier.classify(observed).attribution?.category == .snapshotFactors)
    }

    @Test("Absolute rules do not require home-directory knowledge")
    func absoluteRuleMatchesWithoutHome() throws {
        let rule = try AttributionRule(
            id: AttributionRuleID("system.logs"),
            version: AttributionRuleVersion(1),
            category: .logsAndCaches,
            confidence: .high,
            evidenceCode: AttributionEvidenceCode("absolute.library.logs"),
            matcher: AttributionRuleMatcher(absolutePrefix: ["Library", "Logs"])
        )
        let classifier = try makeClassifier([rule])
        let input = try AttributionInput(absolutePath: "/Library/Logs/DiagnosticReports")

        #expect(classifier.classify(input).attribution?.ruleID == rule.ruleID)
    }

    @Test("Every configured matcher criterion must be satisfied")
    func combinedMatcherUsesAndSemantics() throws {
        let rule = try AttributionRule(
            id: AttributionRuleID("developer.bundle-cache"),
            version: AttributionRuleVersion(1),
            category: .developerTools,
            confidence: .high,
            evidenceCode: AttributionEvidenceCode("home.cache.and.bundle"),
            matcher: AttributionRuleMatcher(
                homeRelativePrefix: ["Library", "Caches"],
                bundleIdentifier: "com.example.developer"
            )
        )
        let classifier = try makeClassifier([rule])
        let wrongBundle = try AttributionInput(
            absolutePath: "/Users/alex/Library/Caches/data",
            homeDirectory: "/Users/alex",
            bundleIdentifier: "com.example.other"
        )
        let completeEvidence = try AttributionInput(
            absolutePath: "/Users/alex/Library/Caches/data",
            homeDirectory: "/Users/alex",
            bundleIdentifier: "com.example.developer"
        )

        #expect(classifier.classify(wrongBundle) == .unknown(.noMatchingRule))
        #expect(classifier.classify(completeEvidence).attribution?.category == .developerTools)
    }
}

private func makeClassifier<S: Sequence>(_ rules: S) throws -> DeterministicAttributionClassifier
where S.Element == AttributionRule {
    try DeterministicAttributionClassifier(
        catalog: AttributionRuleCatalog(
            version: AttributionCatalogVersion(1),
            rules: Array(rules)
        )
    )
}

private func makeRule(
    id: String,
    category: StorageAttributionCategory,
    path: [String],
    priority: Int = 0
) throws -> AttributionRule {
    try AttributionRule(
        id: AttributionRuleID(id),
        version: AttributionRuleVersion(1),
        category: category,
        confidence: .high,
        evidenceCode: AttributionEvidenceCode(id),
        priority: priority,
        matcher: AttributionRuleMatcher(homeRelativePrefix: path)
    )
}

private extension AttributionClassificationResult {
    var attribution: StorageAttribution? {
        guard case .classified(let attribution) = self else { return nil }
        return attribution
    }
}
