import SpaceTraceDomain

public struct AttributionRuleMatcher: Sendable, Equatable, Hashable {
    public let homeRelativePrefix: [String]?
    public let absolutePrefix: [String]?
    public let bundleIdentifier: String?
    public let snapshotFactorObservation: SnapshotFactorObservation?

    public init(
        homeRelativePrefix: [String]? = nil,
        absolutePrefix: [String]? = nil,
        bundleIdentifier: String? = nil,
        snapshotFactorObservation: SnapshotFactorObservation? = nil
    ) throws(AttributionRuleValidationError) {
        if let homeRelativePrefix {
            try Self.validatePathPattern(homeRelativePrefix)
        }
        if let absolutePrefix {
            try Self.validatePathPattern(absolutePrefix)
        }
        if let bundleIdentifier {
            guard bundleIdentifier.allSatisfy(\.isWhitespace) == false,
                  bundleIdentifier.contains("/") == false,
                  bundleIdentifier.contains("\\") == false,
                  bundleIdentifier.contains("\0") == false
            else {
                throw .invalidBundleIdentifier
            }
        }
        if snapshotFactorObservation == SnapshotFactorObservation.none {
            throw .invalidSnapshotObservation
        }

        self.homeRelativePrefix = homeRelativePrefix
        self.absolutePrefix = absolutePrefix
        self.bundleIdentifier = bundleIdentifier
        self.snapshotFactorObservation = snapshotFactorObservation
    }

    var isEmpty: Bool {
        homeRelativePrefix == nil
            && absolutePrefix == nil
            && bundleIdentifier == nil
            && snapshotFactorObservation == nil
    }

    var specificity: AttributionRuleSpecificity {
        let criteriaCount = [
            homeRelativePrefix != nil,
            absolutePrefix != nil,
            bundleIdentifier != nil,
            snapshotFactorObservation != nil,
        ].count(where: { $0 })
        let pathComponentCount = (homeRelativePrefix?.count ?? 0) + (absolutePrefix?.count ?? 0)
        return AttributionRuleSpecificity(
            criteriaCount: criteriaCount,
            pathComponentCount: pathComponentCount
        )
    }

    func matches(_ input: AttributionInput) -> Bool {
        if let homeRelativePrefix {
            guard let components = input.homeRelativePathComponents,
                  components.starts(with: homeRelativePrefix)
            else {
                return false
            }
        }

        if let absolutePrefix,
           input.absolutePathComponents.starts(with: absolutePrefix) == false {
            return false
        }

        if let bundleIdentifier,
           input.bundleIdentifier != bundleIdentifier {
            return false
        }

        if let snapshotFactorObservation,
           input.volumeContext.snapshotFactorObservation != snapshotFactorObservation {
            return false
        }

        return true
    }

    private static func validatePathPattern(
        _ components: [String]
    ) throws(AttributionRuleValidationError) {
        guard components.isEmpty == false else {
            throw .invalidPathPattern
        }

        for component in components {
            guard component.isEmpty == false,
                  component != ".",
                  component != "..",
                  component.contains("/") == false,
                  component.contains("\\") == false,
                  component.contains("\0") == false
            else {
                throw .invalidPathPattern
            }
        }
    }
}

public struct AttributionRule: Sendable, Equatable, Hashable {
    public let attribution: StorageAttribution
    public let priority: Int
    public let matcher: AttributionRuleMatcher

    public var ruleID: AttributionRuleID { attribution.ruleID }
    public var ruleVersion: AttributionRuleVersion { attribution.ruleVersion }
    public var category: StorageAttributionCategory { attribution.category }
    public var confidence: AttributionConfidence { attribution.confidence }
    public var evidenceCode: AttributionEvidenceCode { attribution.evidenceCode }

    public init(
        id: AttributionRuleID,
        version: AttributionRuleVersion,
        category: StorageAttributionCategory,
        confidence: AttributionConfidence,
        evidenceCode: AttributionEvidenceCode,
        priority: Int = 0,
        matcher: AttributionRuleMatcher
    ) throws(AttributionRuleValidationError) {
        guard matcher.isEmpty == false else {
            throw .emptyMatcher
        }
        guard confidence != .unknown else {
            throw .unknownConfidence
        }

        do {
            self.attribution = try StorageAttribution(
                category: category,
                confidence: confidence,
                ruleID: id,
                ruleVersion: version,
                evidenceCode: evidenceCode
            )
        } catch {
            throw .unknownConfidence
        }
        self.priority = priority
        self.matcher = matcher
    }
}

public struct AttributionRuleCatalog: Sendable, Equatable {
    public let version: AttributionRuleVersion
    public let rules: [AttributionRule]

    public init(
        version: AttributionRuleVersion,
        rules: [AttributionRule]
    ) throws(AttributionRuleValidationError) {
        guard rules.isEmpty == false else {
            throw .emptyCatalog
        }

        var observedIDs: Set<AttributionRuleID> = []
        for rule in rules {
            guard observedIDs.insert(rule.ruleID).inserted else {
                throw .duplicateRuleID(rule.ruleID)
            }
        }

        self.version = version
        self.rules = rules
    }
}

public enum AttributionRuleValidationError: Error, Sendable, Equatable {
    case emptyMatcher
    case invalidPathPattern
    case invalidBundleIdentifier
    case invalidSnapshotObservation
    case unknownConfidence
    case emptyCatalog
    case duplicateRuleID(AttributionRuleID)
}

struct AttributionRuleSpecificity: Sendable, Equatable, Comparable {
    let criteriaCount: Int
    let pathComponentCount: Int

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.criteriaCount != rhs.criteriaCount {
            return lhs.criteriaCount < rhs.criteriaCount
        }
        return lhs.pathComponentCount < rhs.pathComponentCount
    }
}
