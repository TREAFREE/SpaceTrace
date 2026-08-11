import Foundation
import Testing
@testable import SpaceTraceDomain

struct ObservationTests {
    @Test(
        "Storage deltas use a stable discriminated wire format",
        arguments: [
            StorageDeltaWireCase(
                value: .logical(bytes: 42),
                expectedJSON: #"{"bytes":42,"kind":"logical"}"#
            ),
            StorageDeltaWireCase(
                value: .allocated(bytes: -7),
                expectedJSON: #"{"bytes":-7,"kind":"allocated"}"#
            ),
            StorageDeltaWireCase(
                value: .volumeAvailable(bytes: 0),
                expectedJSON: #"{"bytes":0,"kind":"volume_available"}"#
            ),
        ]
    )
    func storageDeltaWireFormatIsStable(testCase: StorageDeltaWireCase) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]

        let encoded = try encoder.encode(testCase.value)

        #expect(String(decoding: encoded, as: UTF8.self) == testCase.expectedJSON)
    }

    @Test(
        "All storage delta cases round trip through the durable wire format",
        arguments: [
            StorageDelta.logical(bytes: .max),
            .allocated(bytes: .min),
            .volumeAvailable(bytes: 0),
        ]
    )
    func storageDeltaCasesRoundTrip(value: StorageDelta) throws {
        let encoded = try JSONEncoder().encode(value)

        let decoded = try JSONDecoder().decode(StorageDelta.self, from: encoded)

        #expect(decoded == value)
    }

    @Test(
        "Storage deltas reject unknown and contradictory durable fields",
        arguments: [
            #"{"kind":"logical","bytes":1,"future":true}"#,
            #"{"kind":"logical","bytes":1,"allocated":{"bytes":1}}"#,
            #"{"kind":"allocated","bytes":1,"metric":"logical"}"#,
            #"{"kind":"volume_available","bytes":1,"volumeAvailable":{"bytes":1}}"#,
        ]
    )
    func storageDeltaRejectsUnknownAndContradictoryFields(payload: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(StorageDelta.self, from: Data(payload.utf8))
        }
    }

    @Test(
        "Storage deltas reject missing fields, unknown kinds, and legacy enum payloads",
        arguments: [
            #"{"bytes":1}"#,
            #"{"kind":"logical"}"#,
            #"{}"#,
            #"{"kind":"future_metric","bytes":1}"#,
            #"{"kind":"volumeAvailable","bytes":1}"#,
            #"{"kind":"logical","bytes":null}"#,
            #"{"kind":"logical","bytes":1.5}"#,
            #"{"logical":{"bytes":1}}"#,
        ]
    )
    func storageDeltaRejectsMalformedPayloads(payload: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(StorageDelta.self, from: Data(payload.utf8))
        }
    }

    @Test("Calculates a metric-preserving signed delta", arguments: [
        DeltaCase(metric: .logical, baseline: 10, comparison: 42, expected: 32),
        DeltaCase(metric: .allocated, baseline: 42, comparison: 10, expected: -32),
        DeltaCase(metric: .volumeAvailable, baseline: 42, comparison: 42, expected: 0),
        DeltaCase(metric: .logical, baseline: 0, comparison: .max, expected: .max),
        DeltaCase(metric: .allocated, baseline: .max, comparison: 0, expected: -.max),
    ])
    func calculatesSignedDelta(testCase: DeltaCase) throws {
        let baseline = try makeObservation(
            metric: testCase.metric,
            bytes: testCase.baseline,
            time: 1
        )
        let comparison = try makeObservation(
            metric: testCase.metric,
            bytes: testCase.comparison,
            time: 2
        )

        let delta = try comparison.delta(from: baseline)

        #expect(delta.value.metric == testCase.metric)
        #expect(delta.value.bytes == testCase.expected)
        #expect(delta.scopeID == comparison.scopeID)
        #expect(delta.subjectID == comparison.subjectID)
        #expect(delta.baselineTime == baseline.observedAt)
        #expect(delta.comparisonTime == comparison.observedAt)
    }

    @Test("Unknown coverage has no byte value and cannot masquerade as zero")
    func unknownIsNotZero() throws {
        let observation = try makeObservation(bytes: nil, coverage: .unknown)

        #expect(observation.coverage == .unknown)
        #expect(observation.bytes == nil)
    }

    @Test("Unknown coverage rejects an apparent zero measurement")
    func unknownRejectsZeroBytes() throws {
        let zero = try ByteCount(0)

        #expect(throws: ObservationValidationError.unknownCoverageCannotContainBytes) {
            try Observation(
                scopeID: ScopeID("home"),
                subjectID: SubjectID("Library/Caches"),
                metric: .allocated,
                bytes: zero,
                observedAt: ObservationInstant(millisecondsSince1970: 1),
                coverage: .unknown
            )
        }
    }

    @Test("Measured coverage requires a byte value", arguments: [
        ObservationCoverage.complete,
        .partial,
    ])
    func measuredCoverageRequiresBytes(coverage: ObservationCoverage) {
        #expect(throws: ObservationValidationError.measuredCoverageRequiresBytes(coverage)) {
            try makeObservation(bytes: nil, coverage: coverage)
        }
    }

    @Test("Partial coverage preserves measured bytes but cannot produce a delta")
    func partialCoverageIsMeasuredButIncomparable() throws {
        let baseline = try makeObservation(bytes: 10, time: 1)
        let comparison = try makeObservation(bytes: 20, time: 2, coverage: .partial)

        let partialBytes = try #require(comparison.bytes)
        #expect(partialBytes.value == 20)
        #expect(
            throws: ObservationDeltaError.incompleteCoverage(
                baseline: .complete,
                comparison: .partial
            )
        ) {
            try comparison.delta(from: baseline)
        }
    }

    @Test("Rejects deltas across different scopes")
    func rejectsDifferentScopes() throws {
        let baseline = try makeObservation(scope: "home", time: 1)
        let comparison = try makeObservation(scope: "external", time: 2)

        #expect(throws: ObservationDeltaError.scopeMismatch) {
            try comparison.delta(from: baseline)
        }
    }

    @Test("Rejects deltas across different subjects")
    func rejectsDifferentSubjects() throws {
        let baseline = try makeObservation(subject: "Library/A", time: 1)
        let comparison = try makeObservation(subject: "Library/B", time: 2)

        #expect(throws: ObservationDeltaError.subjectMismatch) {
            try comparison.delta(from: baseline)
        }
    }

    @Test("Rejects deltas across different metrics")
    func rejectsDifferentMetrics() throws {
        let baseline = try makeObservation(metric: .logical, time: 1)
        let comparison = try makeObservation(metric: .allocated, time: 2)

        #expect(throws: ObservationDeltaError.metricMismatch) {
            try comparison.delta(from: baseline)
        }
    }

    @Test("Rejects an incomplete baseline")
    func rejectsIncompleteBaseline() throws {
        let baseline = try makeObservation(time: 1, coverage: .partial)
        let comparison = try makeObservation(time: 2)

        #expect(
            throws: ObservationDeltaError.incompleteCoverage(
                baseline: .partial,
                comparison: .complete
            )
        ) {
            try comparison.delta(from: baseline)
        }
    }

    @Test("Rejects an unknown comparison without treating it as zero")
    func rejectsUnknownComparison() throws {
        let baseline = try makeObservation(bytes: 10, time: 1)
        let comparison = try makeObservation(bytes: nil, time: 2, coverage: .unknown)

        #expect(
            throws: ObservationDeltaError.incompleteCoverage(
                baseline: .complete,
                comparison: .unknown
            )
        ) {
            try comparison.delta(from: baseline)
        }
    }

    @Test("Rejects a comparison that predates its baseline")
    func rejectsReverseChronology() throws {
        let baseline = try makeObservation(time: 2)
        let comparison = try makeObservation(time: 1)

        #expect(throws: ObservationDeltaError.comparisonPredatesBaseline) {
            try comparison.delta(from: baseline)
        }
    }
}

struct StorageDeltaWireCase: Sendable, CustomTestStringConvertible {
    let value: StorageDelta
    let expectedJSON: String

    var testDescription: String {
        expectedJSON
    }
}

struct DeltaCase: Sendable, CustomTestStringConvertible {
    let metric: StorageMetric
    let baseline: Int64
    let comparison: Int64
    let expected: Int64

    var testDescription: String {
        "\(metric.rawValue): \(comparison) - \(baseline) = \(expected)"
    }
}

private func makeObservation(
    scope: String = "home",
    subject: String = "Library/Caches",
    metric: StorageMetric = .allocated,
    bytes: Int64? = 10,
    time: Int64 = 1,
    coverage: ObservationCoverage = .complete
) throws -> Observation {
    let byteCount: ByteCount?
    if let bytes {
        byteCount = try ByteCount(bytes)
    } else {
        byteCount = nil
    }

    return try Observation(
        scopeID: ScopeID(scope),
        subjectID: SubjectID(subject),
        metric: metric,
        bytes: byteCount,
        observedAt: ObservationInstant(millisecondsSince1970: time),
        coverage: coverage
    )
}
