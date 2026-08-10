public enum StorageAttributionCategory: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case developerTools = "developer_tools"
    case virtualization
    case aiModelsAndCaches = "ai_models_and_caches"
    case creativeCachesAndRenderData = "creative_caches_and_render_data"
    case games
    case logsAndCaches = "logs_and_caches"
    case cloudLocalData = "cloud_local_data"
    case snapshotFactors = "snapshot_factors"
}

public enum AttributionConfidence: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case high
    case medium
    case low
    case unknown
}

public struct AttributionRuleID: Sendable, Equatable, Hashable, Codable, Comparable {
    public let rawValue: String

    public init(_ rawValue: String) throws(AttributionValidationError) {
        guard rawValue.allSatisfy(\.isWhitespace) == false else {
            throw .emptyRuleID
        }
        guard rawValue.utf8.allSatisfy(isStableCodeByte) else {
            throw .invalidRuleID
        }

        self.rawValue = rawValue
    }

    public static func < (lhs: AttributionRuleID, rhs: AttributionRuleID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)

        do {
            try self.init(rawValue)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "AttributionRuleID must be a non-empty lowercase ASCII code."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct AttributionRuleVersion: Sendable, Equatable, Hashable, Codable, Comparable {
    public let rawValue: Int

    public init(_ rawValue: Int) throws(AttributionValidationError) {
        guard rawValue > 0 else {
            throw .invalidRuleVersion(rawValue)
        }

        self.rawValue = rawValue
    }

    public static func < (lhs: AttributionRuleVersion, rhs: AttributionRuleVersion) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(Int.self)

        do {
            try self.init(rawValue)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "AttributionRuleVersion must be greater than zero."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The positive version of one complete attribution-rule catalog.
///
/// This is intentionally distinct from ``AttributionRuleVersion``: a catalog
/// can evolve while a winning rule remains unchanged, and individual rules
/// can evolve independently within one catalog release.
public struct AttributionCatalogVersion: Sendable, Equatable, Hashable, Codable, Comparable {
    public let rawValue: Int

    public init(_ rawValue: Int) throws(AttributionValidationError) {
        guard rawValue > 0 else {
            throw .invalidCatalogVersion(rawValue)
        }

        self.rawValue = rawValue
    }

    public static func < (lhs: AttributionCatalogVersion, rhs: AttributionCatalogVersion) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(Int.self)

        do {
            try self.init(rawValue)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "AttributionCatalogVersion must be greater than zero."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct AttributionEvidenceCode: Sendable, Equatable, Hashable, Codable {
    public let rawValue: String

    public init(_ rawValue: String) throws(AttributionValidationError) {
        guard rawValue.allSatisfy(\.isWhitespace) == false else {
            throw .emptyEvidenceCode
        }
        guard rawValue.utf8.allSatisfy(isStableCodeByte) else {
            throw .invalidEvidenceCode
        }

        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)

        do {
            try self.init(rawValue)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "AttributionEvidenceCode must be a non-empty lowercase ASCII code."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// A durable successful classification result.
///
/// Unknown and ambiguous outcomes deliberately live outside this value so a
/// caller cannot accidentally persist uncertainty as a successful category.
public struct StorageAttribution: Sendable, Equatable, Hashable, Codable {
    public let category: StorageAttributionCategory
    public let confidence: AttributionConfidence
    public let ruleID: AttributionRuleID
    public let ruleVersion: AttributionRuleVersion
    public let evidenceCode: AttributionEvidenceCode

    public init(
        category: StorageAttributionCategory,
        confidence: AttributionConfidence,
        ruleID: AttributionRuleID,
        ruleVersion: AttributionRuleVersion,
        evidenceCode: AttributionEvidenceCode
    ) throws(AttributionValidationError) {
        guard confidence != .unknown else {
            throw .unknownConfidenceCannotClassify
        }

        self.category = category
        self.confidence = confidence
        self.ruleID = ruleID
        self.ruleVersion = ruleVersion
        self.evidenceCode = evidenceCode
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownStorageAttributionCodingKeys(in: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let category = try container.decode(StorageAttributionCategory.self, forKey: .category)
        let confidence = try container.decode(AttributionConfidence.self, forKey: .confidence)
        let ruleID = try container.decode(AttributionRuleID.self, forKey: .ruleID)
        let ruleVersion = try container.decode(AttributionRuleVersion.self, forKey: .ruleVersion)
        let evidenceCode = try container.decode(AttributionEvidenceCode.self, forKey: .evidenceCode)

        do {
            try self.init(
                category: category,
                confidence: confidence,
                ruleID: ruleID,
                ruleVersion: ruleVersion,
                evidenceCode: evidenceCode
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .confidence,
                in: container,
                debugDescription: "A successful StorageAttribution cannot use unknown confidence."
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case category
        case confidence
        case ruleID
        case ruleVersion
        case evidenceCode
    }
}

public enum AttributionValidationError: Error, Sendable, Equatable {
    case emptyRuleID
    case invalidRuleID
    case invalidRuleVersion(Int)
    case invalidCatalogVersion(Int)
    case emptyEvidenceCode
    case invalidEvidenceCode
    case unknownConfidenceCannotClassify
}

private func isStableCodeByte(_ byte: UInt8) -> Bool {
    switch byte {
    case 45, 46, 48...57, 95, 97...122:
        true
    default:
        false
    }
}

private func rejectUnknownStorageAttributionCodingKeys(
    in decoder: any Decoder
) throws {
    let container = try decoder.container(
        keyedBy: StorageAttributionDynamicCodingKey.self
    )
    let allowedKeys: Set<String> = [
        "category",
        "confidence",
        "ruleID",
        "ruleVersion",
        "evidenceCode",
    ]
    guard let unknownKey = container.allKeys.first(
        where: { allowedKeys.contains($0.stringValue) == false }
    ) else {
        return
    }

    throw DecodingError.dataCorrupted(
        DecodingError.Context(
            codingPath: decoder.codingPath + [unknownKey],
            debugDescription: "StorageAttribution contains an unknown durable field."
        )
    )
}

private struct StorageAttributionDynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}
