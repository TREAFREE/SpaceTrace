import SpaceTraceDomain

public enum AttributionUnknownReason: Sendable, Equatable, Hashable {
    case noMatchingRule
    case ambiguous(ruleIDs: [AttributionRuleID])
}

public enum AttributionClassificationResult: Sendable, Equatable, Hashable {
    case classified(StorageAttribution)
    case unknown(AttributionUnknownReason)
}

public struct DeterministicAttributionClassifier: Sendable {
    public let catalog: AttributionRuleCatalog

    public init(catalog: AttributionRuleCatalog) {
        self.catalog = catalog
    }

    public func classify(_ input: AttributionInput) -> AttributionClassificationResult {
        let matchingRules = catalog.rules.filter { $0.matcher.matches(input) }
        guard matchingRules.isEmpty == false else {
            return .unknown(.noMatchingRule)
        }

        guard let highestPriority = matchingRules.map(\.priority).max() else {
            return .unknown(.noMatchingRule)
        }
        let priorityWinners = matchingRules.filter { $0.priority == highestPriority }
        guard let greatestSpecificity = priorityWinners.map(\.matcher.specificity).max() else {
            return .unknown(.noMatchingRule)
        }
        let winners = priorityWinners
            .filter { $0.matcher.specificity == greatestSpecificity }
            .sorted { $0.ruleID < $1.ruleID }

        let categories = Set(winners.map(\.category))
        guard categories.count == 1 else {
            return .unknown(.ambiguous(ruleIDs: winners.map(\.ruleID)))
        }

        guard let winner = winners.first else {
            return .unknown(.noMatchingRule)
        }
        return .classified(winner.attribution)
    }
}
