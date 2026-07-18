public enum StorageMetric: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    /// Sum of logical file lengths visible to a scan.
    case logical

    /// Sum of observable allocated-block values, which is not guaranteed to
    /// equal unique or reclaimable physical storage on APFS.
    case allocated

    /// Point-in-time available capacity reported by the volume.
    case volumeAvailable
}

public enum ObservationCoverage: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case complete
    case partial
    case unknown
}

/// A byte measurement captured for one subject within one watch scope.
///
/// Complete and partial observations carry a measured value. Unknown
/// observations deliberately carry no value: unknown is never represented as
/// zero. Only complete observations are eligible for delta calculation.
public struct Observation: Sendable, Equatable, Hashable, Codable {
    public let scopeID: ScopeID
    public let subjectID: SubjectID
    public let metric: StorageMetric
    public let bytes: ByteCount?
    public let observedAt: ObservationInstant
    public let coverage: ObservationCoverage

    public init(
        scopeID: ScopeID,
        subjectID: SubjectID,
        metric: StorageMetric,
        bytes: ByteCount?,
        observedAt: ObservationInstant,
        coverage: ObservationCoverage
    ) throws(ObservationValidationError) {
        switch (coverage, bytes) {
        case (.complete, .some), (.partial, .some), (.unknown, .none):
            break
        case (.complete, .none), (.partial, .none):
            throw .measuredCoverageRequiresBytes(coverage)
        case (.unknown, .some):
            throw .unknownCoverageCannotContainBytes
        }

        self.scopeID = scopeID
        self.subjectID = subjectID
        self.metric = metric
        self.bytes = bytes
        self.observedAt = observedAt
        self.coverage = coverage
    }

    public func delta(from baseline: Observation) throws(ObservationDeltaError) -> ObservationDelta {
        guard scopeID == baseline.scopeID else {
            throw .scopeMismatch
        }
        guard subjectID == baseline.subjectID else {
            throw .subjectMismatch
        }
        guard metric == baseline.metric else {
            throw .metricMismatch
        }
        guard coverage == .complete, baseline.coverage == .complete else {
            throw .incompleteCoverage(baseline: baseline.coverage, comparison: coverage)
        }
        guard observedAt >= baseline.observedAt else {
            throw .comparisonPredatesBaseline
        }
        guard let bytes, let baselineBytes = baseline.bytes else {
            throw .missingMeasuredBytes
        }

        let (difference, overflowed) = bytes.value.subtractingReportingOverflow(baselineBytes.value)
        guard overflowed == false else {
            throw .arithmeticOverflow
        }

        return ObservationDelta(
            scopeID: scopeID,
            subjectID: subjectID,
            value: StorageDelta(metric: metric, bytes: difference),
            baselineTime: baseline.observedAt,
            comparisonTime: observedAt
        )
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let scopeID = try container.decode(ScopeID.self, forKey: .scopeID)
        let subjectID = try container.decode(SubjectID.self, forKey: .subjectID)
        let metric = try container.decode(StorageMetric.self, forKey: .metric)
        let bytes = try container.decodeIfPresent(ByteCount.self, forKey: .bytes)
        let observedAt = try container.decode(ObservationInstant.self, forKey: .observedAt)
        let coverage = try container.decode(ObservationCoverage.self, forKey: .coverage)

        do {
            try self.init(
                scopeID: scopeID,
                subjectID: subjectID,
                metric: metric,
                bytes: bytes,
                observedAt: observedAt,
                coverage: coverage
            )
        } catch {
            throw DecodingError.dataCorruptedError(
                forKey: .coverage,
                in: container,
                debugDescription: "Observation bytes and coverage are inconsistent."
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case scopeID
        case subjectID
        case metric
        case bytes
        case observedAt
        case coverage
    }
}

public enum ObservationValidationError: Error, Sendable, Equatable {
    case measuredCoverageRequiresBytes(ObservationCoverage)
    case unknownCoverageCannotContainBytes
}

public enum ObservationDeltaError: Error, Sendable, Equatable {
    case scopeMismatch
    case subjectMismatch
    case metricMismatch
    case incompleteCoverage(baseline: ObservationCoverage, comparison: ObservationCoverage)
    case comparisonPredatesBaseline
    case missingMeasuredBytes
    case arithmeticOverflow
}

public struct ObservationDelta: Sendable, Equatable, Hashable, Codable {
    public let scopeID: ScopeID
    public let subjectID: SubjectID
    public let value: StorageDelta
    public let baselineTime: ObservationInstant
    public let comparisonTime: ObservationInstant

    init(
        scopeID: ScopeID,
        subjectID: SubjectID,
        value: StorageDelta,
        baselineTime: ObservationInstant,
        comparisonTime: ObservationInstant
    ) {
        self.scopeID = scopeID
        self.subjectID = subjectID
        self.value = value
        self.baselineTime = baselineTime
        self.comparisonTime = comparisonTime
    }
}

/// A metric-preserving signed change. The enum shape prevents callers from
/// accidentally treating logical, allocated, and volume-available deltas as
/// interchangeable values.
public enum StorageDelta: Sendable, Equatable, Hashable, Codable {
    case logical(bytes: Int64)
    case allocated(bytes: Int64)
    case volumeAvailable(bytes: Int64)

    public var metric: StorageMetric {
        switch self {
        case .logical:
            .logical
        case .allocated:
            .allocated
        case .volumeAvailable:
            .volumeAvailable
        }
    }

    public var bytes: Int64 {
        switch self {
        case .logical(let bytes), .allocated(let bytes), .volumeAvailable(let bytes):
            bytes
        }
    }

    init(metric: StorageMetric, bytes: Int64) {
        switch metric {
        case .logical:
            self = .logical(bytes: bytes)
        case .allocated:
            self = .allocated(bytes: bytes)
        case .volumeAvailable:
            self = .volumeAvailable(bytes: bytes)
        }
    }
}
