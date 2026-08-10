import Testing
@testable import SpaceTraceAttribution
import SpaceTraceDomain

struct BuiltInAttributionCatalogTests {
    @Test("Version one contains every P0 category")
    func containsEveryP0Category() throws {
        let catalog = try BuiltInAttributionCatalog.version1()
        let expectedVersion = try AttributionRuleVersion(1)

        #expect(catalog.version == expectedVersion)
        #expect(Set(catalog.rules.map(\.category)) == Set(StorageAttributionCategory.allCases))
    }

    @Test("Specific product evidence outranks the generic cache fallback")
    func specificRuleOutranksGenericCache() throws {
        let classifier = DeterministicAttributionClassifier(
            catalog: try BuiltInAttributionCatalog.version1()
        )
        let input = try AttributionInput(
            absolutePath: "/Users/alex/Library/Caches/com.apple.dt.Xcode/index",
            homeDirectory: "/Users/alex"
        )

        guard case .classified(let attribution) = classifier.classify(input) else {
            Issue.record("Expected a classified Xcode cache")
            return
        }
        #expect(attribution.category == .developerTools)
        #expect(attribution.ruleID.rawValue == "developer.xcode.cache")
        #expect(attribution.evidenceCode.rawValue == "home.library.caches.xcode")
    }
}
