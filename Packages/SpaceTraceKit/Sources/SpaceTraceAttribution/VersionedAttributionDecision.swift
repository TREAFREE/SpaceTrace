import SpaceTraceDomain

/// One path-free classification result frozen against the exact catalog that
/// produced it.
public struct VersionedAttributionDecision: Sendable, Equatable, Hashable, Codable {
    public let catalogVersion: AttributionCatalogVersion
    public let result: AttributionClassificationResult

    public init(
        catalogVersion: AttributionCatalogVersion,
        result: AttributionClassificationResult
    ) throws(AttributionDecisionValidationError) {
        guard result.hasCanonicalDurableEvidence else {
            throw .invalidAmbiguousRuleIDs
        }

        self.catalogVersion = catalogVersion
        self.result = result
    }

    init(
        classifierCatalogVersion: AttributionCatalogVersion,
        exactResult: AttributionClassificationResult
    ) {
        precondition(
            exactResult.hasCanonicalDurableEvidence,
            "The deterministic classifier produced non-canonical durable evidence."
        )
        catalogVersion = classifierCatalogVersion
        result = exactResult
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownAttributionCodingKeys(
            in: decoder,
            allowed: ["catalogVersion", "result"],
            typeName: "VersionedAttributionDecision"
        )
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let catalogVersion = try container.decode(
            AttributionCatalogVersion.self,
            forKey: .catalogVersion
        )
        let result = try container.decode(
            AttributionClassificationResult.self,
            forKey: .result
        )

        do {
            try self.init(catalogVersion: catalogVersion, result: result)
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .result,
                in: container,
                debugDescription: "A versioned decision requires canonical durable evidence."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(catalogVersion, forKey: .catalogVersion)
        try container.encode(result, forKey: .result)
    }

    private enum CodingKeys: String, CodingKey {
        case catalogVersion
        case result
    }
}

public enum AttributionDecisionValidationError: Error, Sendable, Equatable {
    case invalidAmbiguousRuleIDs
}

func rejectUnknownAttributionCodingKeys(
    in decoder: any Decoder,
    allowed: Set<String>,
    typeName: String
) throws {
    let container = try decoder.container(
        keyedBy: AttributionDynamicCodingKey.self
    )
    guard let unknownKey = container.allKeys.first(
        where: { allowed.contains($0.stringValue) == false }
    ) else {
        return
    }

    throw DecodingError.dataCorrupted(
        DecodingError.Context(
            codingPath: decoder.codingPath + [unknownKey],
            debugDescription: "\(typeName) contains an unknown durable field."
        )
    )
}

private struct AttributionDynamicCodingKey: CodingKey {
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
