import SpaceTraceApplication
import SpaceTraceDomain
import Testing

struct HistoricalProjectionCorrectionTests {
    @Test("Correction request and digest values have exact widths")
    func scalarValidation() throws {
        #expect(throws: HistoricalProjectionCorrectionModelError.invalidRequestIDLength(15)) {
            try HistoricalProjectionCorrectionRequestID(
                bytes: Array(repeating: 1, count: 15)
            )
        }
        #expect(
            try HistoricalProjectionCorrectionRequestID(
                bytes: Array(repeating: 0, count: 16)
            ).bytes.count == 16
        )
        #expect(throws: HistoricalProjectionCorrectionModelError.invalidDigestLength(31)) {
            try HistoricalProjectionCorrectionDigest(
                bytes: Array(repeating: 1, count: 31)
            )
        }
    }

    @Test("Semantic identity requires correction format and digest together")
    func semanticIdentityShape() throws {
        #expect(throws: HistoricalProjectionCorrectionModelError.incompleteCorrectionInputIdentity) {
            try HistoricalProjectionSemanticIdentity(
                algorithmVersion: HistoricalFindingAlgorithmVersion(1),
                rankingPolicyVersion: HistoricalFindingRankingPolicyVersion(1),
                correctionInputFormatVersion: HistoricalCorrectionInputFormatVersion(1),
                correctionInputDigest: nil
            )
        }
        #expect(throws: HistoricalProjectionCorrectionModelError.incompleteCorrectionInputIdentity) {
            try HistoricalProjectionSemanticIdentity(
                algorithmVersion: HistoricalFindingAlgorithmVersion(1),
                rankingPolicyVersion: HistoricalFindingRankingPolicyVersion(1),
                correctionInputFormatVersion: nil,
                correctionInputDigest: correctionDigest(1)
            )
        }
    }

    @Test("A replacement keeps the exact frame pair and changes semantic input")
    func sameFrameCorrection() throws {
        let predecessor = try correctionPredecessor()
        let replacement = try correctionReplacement(
            baselineSequence: 10,
            comparisonSequence: 20,
            semanticIdentity: correctedSemanticIdentity(),
            findingCount: 0
        )
        let request = try HistoricalProjectionCorrectionRequest(
            requestID: HistoricalProjectionCorrectionRequestID(
                bytes: Array(repeating: 7, count: 16)
            ),
            predecessor: predecessor,
            replacement: replacement
        )

        #expect(request.replacement.findingCount == 0)
        #expect(request.predecessor.baselineSequence == request.replacement.baselineSequence)
        #expect(request.predecessor.comparisonSequence == request.replacement.comparisonSequence)

        #expect(throws: HistoricalProjectionCorrectionModelError.framePairMismatch) {
            try HistoricalProjectionCorrectionRequest(
                requestID: HistoricalProjectionCorrectionRequestID(
                    bytes: Array(repeating: 8, count: 16)
                ),
                predecessor: predecessor,
                replacement: correctionReplacement(
                    baselineSequence: 10,
                    comparisonSequence: 21,
                    semanticIdentity: correctedSemanticIdentity(),
                    findingCount: 1
                )
            )
        }
    }

    @Test("A no-op replay cannot masquerade as a correction")
    func semanticChangeRequired() throws {
        let predecessor = try correctionPredecessor()
        #expect(throws: HistoricalProjectionCorrectionModelError.semanticIdentityUnchanged) {
            try HistoricalProjectionCorrectionRequest(
                requestID: HistoricalProjectionCorrectionRequestID(
                    bytes: Array(repeating: 9, count: 16)
                ),
                predecessor: predecessor,
                replacement: correctionReplacement(
                    baselineSequence: 10,
                    comparisonSequence: 20,
                    semanticIdentity: predecessor.semanticIdentity,
                    findingCount: 1
                )
            )
        }
    }

    @Test("A replacement always freezes a versioned correction input")
    func replacementInputRequired() throws {
        let predecessor = try correctionPredecessor()
        #expect(throws: HistoricalProjectionCorrectionModelError.replacementCorrectionInputRequired) {
            try HistoricalProjectionCorrectionRequest(
                requestID: HistoricalProjectionCorrectionRequestID(
                    bytes: Array(repeating: 12, count: 16)
                ),
                predecessor: predecessor,
                replacement: correctionReplacement(
                    baselineSequence: 10,
                    comparisonSequence: 20,
                    semanticIdentity: try HistoricalProjectionSemanticIdentity(
                        algorithmVersion: HistoricalFindingAlgorithmVersion(2),
                        rankingPolicyVersion: HistoricalFindingRankingPolicyVersion(1),
                        correctionInputFormatVersion: nil,
                        correctionInputDigest: nil
                    ),
                    findingCount: 1
                )
            )
        }
    }

    @Test("Cross-scope, cross-metric, and volume-level correction are rejected")
    func contextValidation() throws {
        let predecessor = try correctionPredecessor()

        #expect(throws: HistoricalProjectionCorrectionModelError.scopeMismatch) {
            try HistoricalProjectionCorrectionRequest(
                requestID: HistoricalProjectionCorrectionRequestID(
                    bytes: Array(repeating: 10, count: 16)
                ),
                predecessor: predecessor,
                replacement: correctionReplacement(
                    scopeID: ScopeID("scope-b"),
                    semanticIdentity: correctedSemanticIdentity(),
                    findingCount: 1
                )
            )
        }
        #expect(throws: HistoricalProjectionCorrectionModelError.metricMismatch) {
            try HistoricalProjectionCorrectionRequest(
                requestID: HistoricalProjectionCorrectionRequestID(
                    bytes: Array(repeating: 11, count: 16)
                ),
                predecessor: predecessor,
                replacement: correctionReplacement(
                    metric: .logical,
                    semanticIdentity: correctedSemanticIdentity(),
                    findingCount: 1
                )
            )
        }
        #expect(throws: HistoricalProjectionCorrectionModelError.unsupportedMetric) {
            _ = try HistoricalProjectionReplacement(
                baselineSequence: ObservationCommitSequence(10),
                comparisonSequence: ObservationCommitSequence(20),
                scopeID: ScopeID("scope-a"),
                metric: .volumeAvailable,
                semanticIdentity: correctedSemanticIdentity(),
                resultDigest: correctionDigest(3),
                findingCount: 1
            )
        }
    }

    @Test("Replacement finding count is bounded and nonnegative")
    func findingCountValidation() throws {
        #expect(throws: HistoricalProjectionCorrectionModelError.invalidFindingCount(-1)) {
            try correctionReplacement(
                semanticIdentity: correctedSemanticIdentity(),
                findingCount: -1
            )
        }
        #expect(throws: HistoricalProjectionCorrectionModelError.invalidFindingCount(50_001)) {
            try correctionReplacement(
                semanticIdentity: correctedSemanticIdentity(),
                findingCount: 50_001
            )
        }
    }
}

private func correctionDigest(_ byte: UInt8) throws -> HistoricalProjectionCorrectionDigest {
    try HistoricalProjectionCorrectionDigest(bytes: Array(repeating: byte, count: 32))
}

private func originalSemanticIdentity() throws -> HistoricalProjectionSemanticIdentity {
    try HistoricalProjectionSemanticIdentity(
        algorithmVersion: HistoricalFindingAlgorithmVersion(1),
        rankingPolicyVersion: HistoricalFindingRankingPolicyVersion(1),
        correctionInputFormatVersion: nil,
        correctionInputDigest: nil
    )
}

private func correctedSemanticIdentity() throws -> HistoricalProjectionSemanticIdentity {
    try HistoricalProjectionSemanticIdentity(
        algorithmVersion: HistoricalFindingAlgorithmVersion(1),
        rankingPolicyVersion: HistoricalFindingRankingPolicyVersion(1),
        correctionInputFormatVersion: HistoricalCorrectionInputFormatVersion(1),
        correctionInputDigest: correctionDigest(2)
    )
}

private func correctionPredecessor() throws -> HistoricalProjectionCorrectionReference {
    try HistoricalProjectionCorrectionReference(
        projectionID: HistoricalProjectionRecordID(1),
        projectionDigest: correctionDigest(1),
        baselineSequence: ObservationCommitSequence(10),
        comparisonSequence: ObservationCommitSequence(20),
        scopeID: ScopeID("scope-a"),
        metric: .allocated,
        semanticIdentity: originalSemanticIdentity()
    )
}

private func correctionReplacement(
    baselineSequence: Int64 = 10,
    comparisonSequence: Int64 = 20,
    scopeID: ScopeID? = nil,
    metric: StorageMetric = .allocated,
    semanticIdentity: HistoricalProjectionSemanticIdentity,
    findingCount: Int
) throws -> HistoricalProjectionReplacement {
    try HistoricalProjectionReplacement(
        baselineSequence: ObservationCommitSequence(baselineSequence),
        comparisonSequence: ObservationCommitSequence(comparisonSequence),
        scopeID: scopeID ?? ScopeID("scope-a"),
        metric: metric,
        semanticIdentity: semanticIdentity,
        resultDigest: correctionDigest(3),
        findingCount: findingCount
    )
}
