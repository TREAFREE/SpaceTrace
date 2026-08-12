import CryptoKit
import Foundation
import SpaceTraceDomain

package struct HistoricalProjectionCorrectionInput: Sendable, Equatable {
    package let formatVersion: HistoricalCorrectionInputFormatVersion
    package let canonicalBytes: Data
    package let digest: HistoricalProjectionCorrectionDigest

    package init(
        formatVersion: HistoricalCorrectionInputFormatVersion,
        canonicalBytes: Data
    ) throws(HistoricalProjectionCorrectionRegistryError) {
        guard (1...65_536).contains(canonicalBytes.count) else {
            throw .invalidInputByteCount(canonicalBytes.count)
        }
        self.formatVersion = formatVersion
        self.canonicalBytes = canonicalBytes
        do {
            digest = try HistoricalProjectionCorrectionDigest(
                bytes: Array(SHA256.hash(data: canonicalBytes))
            )
        } catch {
            throw .invalidCanonicalInput
        }
    }
}

package struct HistoricalProjectionCorrectionImplementation: Sendable {
    package typealias Generate = @Sendable (
        _ canonicalInput: Data,
        _ baseline: HistoricalFindingObservationFrame,
        _ comparison: HistoricalFindingObservationFrame,
        _ positiveLimit: Int
    ) throws -> HistoricalFindingGenerationResult

    package let algorithmVersion: HistoricalFindingAlgorithmVersion
    package let rankingPolicyVersion: HistoricalFindingRankingPolicyVersion
    package let correctionInputFormatVersion: HistoricalCorrectionInputFormatVersion
    fileprivate let generateValue: Generate

    package init(
        algorithmVersion: HistoricalFindingAlgorithmVersion,
        rankingPolicyVersion: HistoricalFindingRankingPolicyVersion,
        correctionInputFormatVersion: HistoricalCorrectionInputFormatVersion,
        generate: @escaping Generate
    ) {
        self.algorithmVersion = algorithmVersion
        self.rankingPolicyVersion = rankingPolicyVersion
        self.correctionInputFormatVersion = correctionInputFormatVersion
        generateValue = generate
    }
}

/// Immutable, source-registered correction implementations. There is no
/// runtime registration API: a retained work tuple either resolves exactly or
/// fails closed. Production begins empty until a concrete correction is
/// approved with fixture vectors; tests inject bounded deterministic entries.
package struct HistoricalProjectionCorrectionRegistry: Sendable {
    private struct Key: Sendable, Equatable, Hashable {
        let algorithmVersion: Int
        let rankingPolicyVersion: Int
        let correctionInputFormatVersion: Int
    }

    private let implementations: [Key: HistoricalProjectionCorrectionImplementation]

    package static let production = HistoricalProjectionCorrectionRegistry(
        validatedImplementations: [:]
    )

    private init(
        validatedImplementations: [
            Key: HistoricalProjectionCorrectionImplementation
        ]
    ) {
        implementations = validatedImplementations
    }

    package init(
        implementations: [HistoricalProjectionCorrectionImplementation]
    ) throws(HistoricalProjectionCorrectionRegistryError) {
        var indexed: [Key: HistoricalProjectionCorrectionImplementation] = [:]
        for implementation in implementations {
            let key = Key(
                algorithmVersion: implementation.algorithmVersion.rawValue,
                rankingPolicyVersion: implementation.rankingPolicyVersion.rawValue,
                correctionInputFormatVersion:
                    implementation.correctionInputFormatVersion.rawValue
            )
            guard indexed.updateValue(implementation, forKey: key) == nil else {
                throw .duplicateRegistration
            }
        }
        self.implementations = indexed
    }

    package func generate(
        semanticIdentity: HistoricalProjectionSemanticIdentity,
        canonicalInput: Data,
        baseline: HistoricalFindingObservationFrame,
        comparison: HistoricalFindingObservationFrame,
        positiveLimit: Int
    ) throws -> HistoricalFindingGenerationResult {
        guard let formatVersion = semanticIdentity.correctionInputFormatVersion,
              let expectedDigest = semanticIdentity.correctionInputDigest else {
            throw HistoricalProjectionCorrectionRegistryError.incompleteSemanticIdentity
        }
        guard (1...65_536).contains(canonicalInput.count) else {
            throw HistoricalProjectionCorrectionRegistryError.invalidInputByteCount(
                canonicalInput.count
            )
        }
        let actualDigest = try HistoricalProjectionCorrectionDigest(
            bytes: Array(SHA256.hash(data: canonicalInput))
        )
        guard actualDigest == expectedDigest else {
            throw HistoricalProjectionCorrectionRegistryError.inputDigestMismatch
        }
        let key = Key(
            algorithmVersion: semanticIdentity.algorithmVersion.rawValue,
            rankingPolicyVersion: semanticIdentity.rankingPolicyVersion.rawValue,
            correctionInputFormatVersion: formatVersion.rawValue
        )
        guard let implementation = implementations[key] else {
            throw HistoricalProjectionCorrectionRegistryError.unregisteredSemanticIdentity
        }
        guard historicalProjectionCorrectionFrameIsComplete(baseline),
              historicalProjectionCorrectionFrameIsComplete(comparison) else {
            throw HistoricalProjectionCorrectionRegistryError.partialFrame
        }
        let result = try implementation.generateValue(
            canonicalInput,
            baseline,
            comparison,
            positiveLimit
        )
        guard let baselineRoot = baseline.nodes.first(where: {
            $0.endpoint.subjectID == baseline.rootSubjectID
        }), let comparisonRoot = comparison.nodes.first(where: {
            $0.endpoint.subjectID == comparison.rootSubjectID
        }) else {
            throw HistoricalProjectionCorrectionRegistryError.generatorFrameMismatch
        }
        guard result.batch.algorithmVersion == semanticIdentity.algorithmVersion,
              result.batch.rankingPolicyVersion == semanticIdentity.rankingPolicyVersion else {
            throw HistoricalProjectionCorrectionRegistryError.generatorIdentityMismatch
        }
        guard result.batch.baselineSequence == baseline.sequence,
              result.batch.comparisonSequence == comparison.sequence,
              result.batch.baselineRootEndpointID == baselineRoot.endpoint.id,
              result.batch.comparisonRootEndpointID == comparisonRoot.endpoint.id,
              result.batch.positiveLimit == positiveLimit else {
            throw HistoricalProjectionCorrectionRegistryError.generatorFrameMismatch
        }
        return result
    }
}

package struct HistoricalProjectionCorrectionAuditRecord: Sendable, Equatable {
    package let rootProjectionID: HistoricalProjectionRecordID
    package let predecessorCorrectingProjectionID: HistoricalCorrectingProjectionRecordID?
    package let predecessor: HistoricalProjectionCorrectionReference
    package let positiveLimit: Int

    package init(
        rootProjectionID: HistoricalProjectionRecordID,
        predecessorCorrectingProjectionID: HistoricalCorrectingProjectionRecordID?,
        predecessor: HistoricalProjectionCorrectionReference,
        positiveLimit: Int
    ) throws(HistoricalProjectionCorrectionServiceError) {
        guard rootProjectionID == predecessor.projectionID else {
            throw .auditRecordMismatch
        }
        guard (1...100).contains(positiveLimit) else {
            throw .auditRecordMismatch
        }
        self.rootProjectionID = rootProjectionID
        self.predecessorCorrectingProjectionID = predecessorCorrectingProjectionID
        self.predecessor = predecessor
        self.positiveLimit = positiveLimit
    }
}

package struct HistoricalProjectionCorrectionCommand: Sendable, Equatable {
    package let requestID: HistoricalProjectionCorrectionRequestID
    package let rootProjectionID: HistoricalProjectionRecordID
    package let predecessorCorrectingProjectionID: HistoricalCorrectingProjectionRecordID?
    package let predecessor: HistoricalProjectionCorrectionReference
    package let replacement: HistoricalProjectionReplacement
    package let canonicalInput: Data
    package let expectedResult: HistoricalFindingGenerationResult

    fileprivate init(
        requestID: HistoricalProjectionCorrectionRequestID,
        audit: HistoricalProjectionCorrectionAuditRecord,
        replacement: HistoricalProjectionReplacement,
        canonicalInput: Data,
        expectedResult: HistoricalFindingGenerationResult
    ) {
        self.requestID = requestID
        rootProjectionID = audit.rootProjectionID
        predecessorCorrectingProjectionID = audit.predecessorCorrectingProjectionID
        predecessor = audit.predecessor
        self.replacement = replacement
        self.canonicalInput = canonicalInput
        self.expectedResult = expectedResult
    }

    /// Rehydrates a request that Persistence has already authenticated by its
    /// immutable request ID and stored canonical digest. New correction
    /// commands must continue to flow through `HistoricalProjectionCorrectionService`.
    package init(
        rehydratingStoredRequestID requestID: HistoricalProjectionCorrectionRequestID,
        audit: HistoricalProjectionCorrectionAuditRecord,
        replacement: HistoricalProjectionReplacement,
        canonicalInput: Data,
        expectedResult: HistoricalFindingGenerationResult
    ) {
        self.requestID = requestID
        rootProjectionID = audit.rootProjectionID
        predecessorCorrectingProjectionID = audit.predecessorCorrectingProjectionID
        predecessor = audit.predecessor
        self.replacement = replacement
        self.canonicalInput = canonicalInput
        self.expectedResult = expectedResult
    }
}

package struct HistoricalProjectionCorrectionStoredRequest: Sendable, Equatable {
    package let audit: HistoricalProjectionCorrectionAuditRecord
    package let semanticIdentity: HistoricalProjectionSemanticIdentity
    package let canonicalInput: Data

    package init(
        audit: HistoricalProjectionCorrectionAuditRecord,
        semanticIdentity: HistoricalProjectionSemanticIdentity,
        canonicalInput: Data
    ) {
        self.audit = audit
        self.semanticIdentity = semanticIdentity
        self.canonicalInput = canonicalInput
    }
}

package enum HistoricalProjectionCorrectionCommitOutcome: Sendable, Equatable {
    case newlyCommitted(HistoricalCorrectingProjectionRecordID)
    case alreadyCommitted(HistoricalCorrectingProjectionRecordID)
}

package protocol HistoricalProjectionCorrectionRepository: Sendable {
    func historicalProjectionCorrectionStoredRequest(
        requestID: HistoricalProjectionCorrectionRequestID
    ) async throws -> HistoricalProjectionCorrectionStoredRequest?

    func historicalProjectionCorrectionAuditRecord(
        rootProjectionID: HistoricalProjectionRecordID
    ) async throws -> HistoricalProjectionCorrectionAuditRecord?

    func historicalObservationFrame(
        sequence: ObservationCommitSequence
    ) async throws -> HistoricalFindingObservationFrame?

    func commitHistoricalProjectionCorrection(
        _ command: HistoricalProjectionCorrectionCommand
    ) async throws -> HistoricalProjectionCorrectionCommitOutcome
}

package actor HistoricalProjectionCorrectionService {
    private let repository: any HistoricalProjectionCorrectionRepository
    private let registry: HistoricalProjectionCorrectionRegistry

    package init(
        repository: any HistoricalProjectionCorrectionRepository,
        registry: HistoricalProjectionCorrectionRegistry = .production
    ) {
        self.repository = repository
        self.registry = registry
    }

    package func correct(
        rootProjectionID: HistoricalProjectionRecordID,
        requestID: HistoricalProjectionCorrectionRequestID,
        input: HistoricalProjectionCorrectionInput,
        algorithmVersion: HistoricalFindingAlgorithmVersion,
        rankingPolicyVersion: HistoricalFindingRankingPolicyVersion
    ) async throws -> HistoricalProjectionCorrectionCommitOutcome {
        let requestedSemanticIdentity = try HistoricalProjectionSemanticIdentity(
            algorithmVersion: algorithmVersion,
            rankingPolicyVersion: rankingPolicyVersion,
            correctionInputFormatVersion: input.formatVersion,
            correctionInputDigest: input.digest
        )
        let audit: HistoricalProjectionCorrectionAuditRecord
        if let stored = try await repository.historicalProjectionCorrectionStoredRequest(
            requestID: requestID
        ) {
            guard stored.audit.rootProjectionID == rootProjectionID,
                  stored.semanticIdentity == requestedSemanticIdentity,
                  stored.canonicalInput == input.canonicalBytes else {
                throw HistoricalProjectionCorrectionServiceError.immutableRequestConflict
            }
            audit = stored.audit
        } else {
            guard let current = try await repository.historicalProjectionCorrectionAuditRecord(
                rootProjectionID: rootProjectionID
            ) else {
                throw HistoricalProjectionCorrectionServiceError.predecessorUnavailable
            }
            audit = current
        }
        guard let baseline = try await repository.historicalObservationFrame(
            sequence: audit.predecessor.baselineSequence
        ) else {
            throw HistoricalProjectionCorrectionServiceError.frameUnavailable(
                audit.predecessor.baselineSequence
            )
        }
        guard let comparison = try await repository.historicalObservationFrame(
            sequence: audit.predecessor.comparisonSequence
        ) else {
            throw HistoricalProjectionCorrectionServiceError.frameUnavailable(
                audit.predecessor.comparisonSequence
            )
        }
        guard let baselineRoot = baseline.nodes.first(where: {
            $0.endpoint.subjectID == baseline.rootSubjectID
        }), let comparisonRoot = comparison.nodes.first(where: {
            $0.endpoint.subjectID == comparison.rootSubjectID
        }) else {
            throw HistoricalProjectionCorrectionServiceError.frameContextMismatch
        }
        guard baseline.sequence == audit.predecessor.baselineSequence,
              comparison.sequence == audit.predecessor.comparisonSequence,
              baselineRoot.endpoint.scopeID == audit.predecessor.scopeID,
              comparisonRoot.endpoint.scopeID == audit.predecessor.scopeID,
              baselineRoot.endpoint.metric == audit.predecessor.metric,
              comparisonRoot.endpoint.metric == audit.predecessor.metric else {
            throw HistoricalProjectionCorrectionServiceError.frameContextMismatch
        }
        guard historicalProjectionCorrectionFrameIsComplete(baseline),
              historicalProjectionCorrectionFrameIsComplete(comparison) else {
            throw HistoricalProjectionCorrectionServiceError.partialFrame
        }

        let result = try registry.generate(
            semanticIdentity: requestedSemanticIdentity,
            canonicalInput: input.canonicalBytes,
            baseline: baseline,
            comparison: comparison,
            positiveLimit: audit.positiveLimit
        )
        let resultDigest = try historicalProjectionCorrectionResultDigest(result)
        let replacement = try HistoricalProjectionReplacement(
            baselineSequence: baseline.sequence,
            comparisonSequence: comparison.sequence,
            scopeID: audit.predecessor.scopeID,
            metric: audit.predecessor.metric,
            semanticIdentity: requestedSemanticIdentity,
            resultDigest: resultDigest,
            findingCount: result.batch.findings.count
        )
        _ = try HistoricalProjectionCorrectionRequest(
            requestID: requestID,
            predecessor: audit.predecessor,
            replacement: replacement
        )
        return try await repository.commitHistoricalProjectionCorrection(
            HistoricalProjectionCorrectionCommand(
                requestID: requestID,
                audit: audit,
                replacement: replacement,
                canonicalInput: input.canonicalBytes,
                expectedResult: result
            )
        )
    }
}

package func historicalProjectionCorrectionResultDigest(
    _ result: HistoricalFindingGenerationResult
) throws -> HistoricalProjectionCorrectionDigest {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let payload = try encoder.encode(result)
    var canonical = Data("SpaceTrace.HistoricalFindingGenerationResult.v1".utf8)
    canonical.append(0)
    var length = UInt64(payload.count).bigEndian
    withUnsafeBytes(of: &length) { canonical.append(contentsOf: $0) }
    canonical.append(payload)
    return try HistoricalProjectionCorrectionDigest(
        bytes: Array(SHA256.hash(data: canonical))
    )
}

package enum HistoricalProjectionCorrectionRegistryError: Error, Sendable, Equatable {
    case duplicateRegistration
    case invalidInputByteCount(Int)
    case incompleteSemanticIdentity
    case inputDigestMismatch
    case unregisteredSemanticIdentity
    case invalidCanonicalInput
    case generatorIdentityMismatch
    case generatorFrameMismatch
    case partialFrame
}

package enum HistoricalProjectionCorrectionServiceError: Error, Sendable, Equatable {
    case predecessorUnavailable
    case frameUnavailable(ObservationCommitSequence)
    case frameContextMismatch
    case auditRecordMismatch
    case immutableRequestConflict
    case partialFrame
}

private func historicalProjectionCorrectionFrameIsComplete(
    _ frame: HistoricalFindingObservationFrame
) -> Bool {
    frame.nodes.allSatisfy { node in
        switch node.endpoint.state {
        case .present(_, let coverage):
            return coverage == .complete && node.directChildrenCoverage == .complete
        case .absent:
            return true
        case .unknown:
            return false
        }
    }
}
