import SpaceTraceDomain

public enum AttributionUnknownReason: Sendable, Equatable, Hashable, Codable {
    case noMatchingRule
    case ambiguous(ruleIDs: [AttributionRuleID])

    var hasCanonicalDurableEvidence: Bool {
        switch self {
        case .noMatchingRule:
            true
        case let .ambiguous(ruleIDs):
            Self.hasCanonicalAmbiguousRuleIDs(ruleIDs)
        }
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownAttributionCodingKeys(
            in: decoder,
            allowed: ["kind", "ruleIDs"],
            typeName: "AttributionUnknownReason"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .noMatchingRule:
            guard container.contains(.ruleIDs) == false else {
                throw DecodingError.dataCorruptedError(
                    forKey: .ruleIDs,
                    in: container,
                    debugDescription: "A no-match reason cannot contain competing rule IDs."
                )
            }
            self = .noMatchingRule
        case .ambiguous:
            let ruleIDs = try container.decode(
                [AttributionRuleID].self,
                forKey: .ruleIDs
            )
            guard Self.hasCanonicalAmbiguousRuleIDs(ruleIDs) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .ruleIDs,
                    in: container,
                    debugDescription: Self.ambiguousRuleIDsRequirement
                )
            }
            self = .ambiguous(ruleIDs: ruleIDs)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .noMatchingRule:
            try container.encode(Kind.noMatchingRule, forKey: .kind)
        case let .ambiguous(ruleIDs):
            guard Self.hasCanonicalAmbiguousRuleIDs(ruleIDs) else {
                throw EncodingError.invalidValue(
                    self,
                    EncodingError.Context(
                        codingPath: encoder.codingPath,
                        debugDescription: Self.ambiguousRuleIDsRequirement
                    )
                )
            }
            try container.encode(Kind.ambiguous, forKey: .kind)
            try container.encode(ruleIDs, forKey: .ruleIDs)
        }
    }

    private static func hasCanonicalAmbiguousRuleIDs(
        _ ruleIDs: [AttributionRuleID]
    ) -> Bool {
        ruleIDs.count >= 2
            && zip(ruleIDs, ruleIDs.dropFirst()).allSatisfy { pair in
                pair.0 < pair.1
            }
    }

    private static let ambiguousRuleIDsRequirement =
        "Ambiguous rule IDs must contain at least two unique values in strict ascending order."

    private enum Kind: String, Codable {
        case noMatchingRule = "no_matching_rule"
        case ambiguous
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case ruleIDs
    }
}

public enum AttributionClassificationResult: Sendable, Equatable, Hashable, Codable {
    case classified(StorageAttribution)
    case unknown(AttributionUnknownReason)

    var hasCanonicalDurableEvidence: Bool {
        switch self {
        case .classified:
            true
        case let .unknown(reason):
            reason.hasCanonicalDurableEvidence
        }
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownAttributionCodingKeys(
            in: decoder,
            allowed: ["kind", "attribution", "reason"],
            typeName: "AttributionClassificationResult"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .classified:
            guard container.contains(.reason) == false else {
                throw DecodingError.dataCorruptedError(
                    forKey: .reason,
                    in: container,
                    debugDescription: "A classified result cannot contain an unknown reason."
                )
            }
            self = .classified(
                try container.decode(StorageAttribution.self, forKey: .attribution)
            )
        case .unknown:
            guard container.contains(.attribution) == false else {
                throw DecodingError.dataCorruptedError(
                    forKey: .attribution,
                    in: container,
                    debugDescription: "An unknown result cannot contain an attribution."
                )
            }
            self = .unknown(
                try container.decode(AttributionUnknownReason.self, forKey: .reason)
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .classified(attribution):
            try container.encode(Kind.classified, forKey: .kind)
            try container.encode(attribution, forKey: .attribution)
        case let .unknown(reason):
            try container.encode(Kind.unknown, forKey: .kind)
            try container.encode(reason, forKey: .reason)
        }
    }

    private enum Kind: String, Codable {
        case classified
        case unknown
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case attribution
        case reason
    }
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

    /// Freezes the exact deterministic result together with the catalog that
    /// produced it. Rule and catalog versions remain independent evidence.
    public func classifyVersioned(
        _ input: AttributionInput
    ) -> VersionedAttributionDecision {
        let result = classify(input)
        return VersionedAttributionDecision(
            classifierCatalogVersion: catalog.version,
            exactResult: result
        )
    }
}
