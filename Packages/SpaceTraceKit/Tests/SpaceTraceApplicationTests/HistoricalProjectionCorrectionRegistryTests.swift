import CryptoKit
import Foundation
import SpaceTraceAttribution
import SpaceTraceDomain
import Testing
@testable import SpaceTraceApplication

@Suite("Historical projection correction registry")
struct HistoricalProjectionCorrectionRegistryTests {
    @Test("A closed registry resolves only an exact semantic tuple and input digest")
    func exactRegistration() throws {
        let fixture = try correctionRegistryFixture()
        let registry = try HistoricalProjectionCorrectionRegistry(
            implementations: [fixture.implementation]
        )

        let generated = try registry.generate(
            semanticIdentity: fixture.semanticIdentity,
            canonicalInput: fixture.input,
            baseline: fixture.baseline,
            comparison: fixture.comparison,
            positiveLimit: 10
        )
        #expect(generated == fixture.result)

        #expect(throws: HistoricalProjectionCorrectionRegistryError.unregisteredSemanticIdentity) {
            _ = try registry.generate(
                semanticIdentity: try HistoricalProjectionSemanticIdentity(
                    algorithmVersion: HistoricalFindingAlgorithmVersion(2),
                    rankingPolicyVersion: HistoricalFindingRankingPolicyVersion(1),
                    correctionInputFormatVersion: HistoricalCorrectionInputFormatVersion(1),
                    correctionInputDigest: fixture.semanticIdentity.correctionInputDigest
                ),
                canonicalInput: fixture.input,
                baseline: fixture.baseline,
                comparison: fixture.comparison,
                positiveLimit: 10
            )
        }
        #expect(throws: HistoricalProjectionCorrectionRegistryError.inputDigestMismatch) {
            _ = try registry.generate(
                semanticIdentity: fixture.semanticIdentity,
                canonicalInput: Data("changed".utf8),
                baseline: fixture.baseline,
                comparison: fixture.comparison,
                positiveLimit: 10
            )
        }
    }

    @Test("Duplicate registrations and unbounded correction inputs fail closed")
    func closedShape() throws {
        let fixture = try correctionRegistryFixture()
        #expect(throws: HistoricalProjectionCorrectionRegistryError.duplicateRegistration) {
            _ = try HistoricalProjectionCorrectionRegistry(
                implementations: [fixture.implementation, fixture.implementation]
            )
        }
        #expect(throws: HistoricalProjectionCorrectionRegistryError.invalidInputByteCount(0)) {
            _ = try HistoricalProjectionCorrectionInput(
                formatVersion: HistoricalCorrectionInputFormatVersion(1),
                canonicalBytes: Data()
            )
        }
        #expect(
            throws: HistoricalProjectionCorrectionRegistryError.invalidInputByteCount(65_537)
        ) {
            _ = try HistoricalProjectionCorrectionInput(
                formatVersion: HistoricalCorrectionInputFormatVersion(1),
                canonicalBytes: Data(repeating: 1, count: 65_537)
            )
        }
    }

    @Test("The registry rejects partial evidence and mismatched generator output")
    func rejectsUnqualifiedGeneration() throws {
        let fixture = try correctionRegistryFixture()
        let registry = try HistoricalProjectionCorrectionRegistry(
            implementations: [fixture.implementation]
        )
        let partialBaseline = try correctionRegistryFrame(
            sequence: fixture.baseline.sequence.rawValue,
            prefix: "partial-registry-baseline",
            bytes: 10,
            coverage: .partial
        )

        #expect(throws: HistoricalProjectionCorrectionRegistryError.partialFrame) {
            _ = try registry.generate(
                semanticIdentity: fixture.semanticIdentity,
                canonicalInput: fixture.input,
                baseline: partialBaseline,
                comparison: fixture.comparison,
                positiveLimit: 10
            )
        }
        let mismatchedRegistry = try HistoricalProjectionCorrectionRegistry(
            implementations: [
                HistoricalProjectionCorrectionImplementation(
                    algorithmVersion: HistoricalFindingAlgorithmVersion(1),
                    rankingPolicyVersion: HistoricalFindingRankingPolicyVersion(1),
                    correctionInputFormatVersion: HistoricalCorrectionInputFormatVersion(1)
                ) { _, _, _, _ in
                    fixture.result
                },
            ]
        )
        #expect(
            throws: HistoricalProjectionCorrectionRegistryError.generatorFrameMismatch
        ) {
            _ = try mismatchedRegistry.generate(
                semanticIdentity: fixture.semanticIdentity,
                canonicalInput: fixture.input,
                baseline: fixture.baseline,
                comparison: fixture.comparison,
                positiveLimit: 9
            )
        }
    }

    @Test("The authorizer reloads immutable audit evidence before committing")
    func authorizesFromStoredAudit() async throws {
        let fixture = try correctionRegistryFixture()
        let audit = try HistoricalProjectionCorrectionAuditRecord(
            rootProjectionID: HistoricalProjectionRecordID(41),
            predecessorCorrectingProjectionID: nil,
            predecessor: HistoricalProjectionCorrectionReference(
                projectionID: HistoricalProjectionRecordID(41),
                projectionDigest: fixtureDigest(0x41),
                baselineSequence: fixture.baseline.sequence,
                comparisonSequence: fixture.comparison.sequence,
                scopeID: fixture.baseline.nodes[0].endpoint.scopeID,
                metric: fixture.baseline.nodes[0].endpoint.metric,
                semanticIdentity: try HistoricalProjectionSemanticIdentity(
                    algorithmVersion: HistoricalFindingAlgorithmVersion(1),
                    rankingPolicyVersion: HistoricalFindingRankingPolicyVersion(1),
                    correctionInputFormatVersion: nil,
                    correctionInputDigest: nil
                )
            ),
            positiveLimit: 10
        )
        let repository = try CorrectionServiceRepositoryStub(
            audit: audit,
            frames: [fixture.baseline, fixture.comparison]
        )
        let service = HistoricalProjectionCorrectionService(
            repository: repository,
            registry: try HistoricalProjectionCorrectionRegistry(
                implementations: [fixture.implementation]
            )
        )
        let requestID = try HistoricalProjectionCorrectionRequestID(
            bytes: Array(repeating: 0x5a, count: 16)
        )

        let outcome = try await service.correct(
            rootProjectionID: audit.rootProjectionID,
            requestID: requestID,
            input: try HistoricalProjectionCorrectionInput(
                formatVersion: HistoricalCorrectionInputFormatVersion(1),
                canonicalBytes: fixture.input
            ),
            algorithmVersion: HistoricalFindingAlgorithmVersion(1),
            rankingPolicyVersion: HistoricalFindingRankingPolicyVersion(1)
        )

        #expect(outcome == .newlyCommitted(try HistoricalCorrectingProjectionRecordID(71)))
        let commands = await repository.commands
        #expect(commands.count == 1)
        #expect(commands[0].requestID == requestID)
        #expect(commands[0].rootProjectionID == audit.rootProjectionID)
        #expect(commands[0].predecessor == audit.predecessor)
        #expect(commands[0].expectedResult == fixture.result)
        #expect(commands[0].canonicalInput == fixture.input)
    }

    @Test("Unavailable audit records and frames never reach persistence")
    func unavailableEvidence() async throws {
        let fixture = try correctionRegistryFixture()
        let registry = try HistoricalProjectionCorrectionRegistry(
            implementations: [fixture.implementation]
        )
        let requestID = try HistoricalProjectionCorrectionRequestID(
            bytes: Array(repeating: 0x4a, count: 16)
        )
        let input = try HistoricalProjectionCorrectionInput(
            formatVersion: HistoricalCorrectionInputFormatVersion(1),
            canonicalBytes: fixture.input
        )
        let missingAudit = try CorrectionServiceRepositoryStub(audit: nil, frames: [])
        let missingAuditService = HistoricalProjectionCorrectionService(
            repository: missingAudit,
            registry: registry
        )
        await #expect(throws: HistoricalProjectionCorrectionServiceError.predecessorUnavailable) {
            _ = try await missingAuditService.correct(
                rootProjectionID: HistoricalProjectionRecordID(1),
                requestID: requestID,
                input: input,
                algorithmVersion: HistoricalFindingAlgorithmVersion(1),
                rankingPolicyVersion: HistoricalFindingRankingPolicyVersion(1)
            )
        }

        let audit = try HistoricalProjectionCorrectionAuditRecord(
            rootProjectionID: HistoricalProjectionRecordID(1),
            predecessorCorrectingProjectionID: nil,
            predecessor: HistoricalProjectionCorrectionReference(
                projectionID: HistoricalProjectionRecordID(1),
                projectionDigest: fixtureDigest(1),
                baselineSequence: fixture.baseline.sequence,
                comparisonSequence: fixture.comparison.sequence,
                scopeID: fixture.baseline.nodes[0].endpoint.scopeID,
                metric: fixture.baseline.nodes[0].endpoint.metric,
                semanticIdentity: try HistoricalProjectionSemanticIdentity(
                    algorithmVersion: HistoricalFindingAlgorithmVersion(1),
                    rankingPolicyVersion: HistoricalFindingRankingPolicyVersion(1),
                    correctionInputFormatVersion: nil,
                    correctionInputDigest: nil
                )
            ),
            positiveLimit: 10
        )
        let missingFrame = try CorrectionServiceRepositoryStub(
            audit: audit,
            frames: [fixture.baseline]
        )
        let missingFrameService = HistoricalProjectionCorrectionService(
            repository: missingFrame,
            registry: registry
        )
        await #expect(
            throws: HistoricalProjectionCorrectionServiceError.frameUnavailable(
                fixture.comparison.sequence
            )
        ) {
            _ = try await missingFrameService.correct(
                rootProjectionID: audit.rootProjectionID,
                requestID: requestID,
                input: input,
                algorithmVersion: HistoricalFindingAlgorithmVersion(1),
                rankingPolicyVersion: HistoricalFindingRankingPolicyVersion(1)
            )
        }
        #expect(await missingFrame.commands.isEmpty)
    }
}

@Suite("Historical projection correction service")
struct HistoricalProjectionCorrectionServiceTests {
    @Test("A committed request reloads its original predecessor instead of branching")
    func reloadsStoredRequestForRetry() async throws {
        let fixture = try correctionRegistryFixture()
        let audit = try correctionServiceAudit(fixture: fixture)
        let stored = HistoricalProjectionCorrectionStoredRequest(
            audit: audit,
            semanticIdentity: fixture.semanticIdentity,
            canonicalInput: fixture.input
        )
        let repository = try CorrectionServiceRepositoryStub(
            audit: nil,
            frames: [fixture.baseline, fixture.comparison],
            storedRequest: stored,
            commitOutcome: .alreadyCommitted(
                try HistoricalCorrectingProjectionRecordID(71)
            )
        )
        let service = HistoricalProjectionCorrectionService(
            repository: repository,
            registry: try HistoricalProjectionCorrectionRegistry(
                implementations: [fixture.implementation]
            )
        )

        let outcome = try await service.correct(
            rootProjectionID: audit.rootProjectionID,
            requestID: HistoricalProjectionCorrectionRequestID(
                bytes: Array(repeating: 0x62, count: 16)
            ),
            input: HistoricalProjectionCorrectionInput(
                formatVersion: HistoricalCorrectionInputFormatVersion(1),
                canonicalBytes: fixture.input
            ),
            algorithmVersion: HistoricalFindingAlgorithmVersion(1),
            rankingPolicyVersion: HistoricalFindingRankingPolicyVersion(1)
        )

        #expect(outcome == .alreadyCommitted(try HistoricalCorrectingProjectionRecordID(71)))
        #expect(await repository.commands.first?.predecessor == audit.predecessor)
    }

    @Test("Partial immutable frames fail before registry execution or persistence")
    func rejectsPartialFrames() async throws {
        let complete = try correctionRegistryFixture()
        let partialBaseline = try correctionRegistryFrame(
            sequence: 10,
            prefix: "baseline",
            bytes: 10,
            coverage: .partial
        )
        let audit = try correctionServiceAudit(fixture: complete)
        let repository = try CorrectionServiceRepositoryStub(
            audit: audit,
            frames: [partialBaseline, complete.comparison]
        )
        let service = HistoricalProjectionCorrectionService(
            repository: repository,
            registry: try HistoricalProjectionCorrectionRegistry(
                implementations: [complete.implementation]
            )
        )

        await #expect(throws: HistoricalProjectionCorrectionServiceError.partialFrame) {
            _ = try await service.correct(
                rootProjectionID: audit.rootProjectionID,
                requestID: HistoricalProjectionCorrectionRequestID(
                    bytes: Array(repeating: 0x63, count: 16)
                ),
                input: HistoricalProjectionCorrectionInput(
                    formatVersion: HistoricalCorrectionInputFormatVersion(1),
                    canonicalBytes: complete.input
                ),
                algorithmVersion: HistoricalFindingAlgorithmVersion(1),
                rankingPolicyVersion: HistoricalFindingRankingPolicyVersion(1)
            )
        }
        #expect(await repository.commands.isEmpty)
    }

    @Test("An unchanged registered semantic identity is not a correction")
    func rejectsSemanticNoOp() async throws {
        let fixture = try correctionRegistryFixture()
        let originalAudit = try correctionServiceAudit(fixture: fixture)
        let predecessor = try HistoricalProjectionCorrectionReference(
            projectionID: originalAudit.rootProjectionID,
            projectionDigest: originalAudit.predecessor.projectionDigest,
            baselineSequence: originalAudit.predecessor.baselineSequence,
            comparisonSequence: originalAudit.predecessor.comparisonSequence,
            scopeID: originalAudit.predecessor.scopeID,
            metric: originalAudit.predecessor.metric,
            semanticIdentity: fixture.semanticIdentity
        )
        let audit = try HistoricalProjectionCorrectionAuditRecord(
            rootProjectionID: originalAudit.rootProjectionID,
            predecessorCorrectingProjectionID: HistoricalCorrectingProjectionRecordID(9),
            predecessor: predecessor,
            positiveLimit: 10
        )
        let repository = try CorrectionServiceRepositoryStub(
            audit: audit,
            frames: [fixture.baseline, fixture.comparison]
        )
        let service = HistoricalProjectionCorrectionService(
            repository: repository,
            registry: try HistoricalProjectionCorrectionRegistry(
                implementations: [fixture.implementation]
            )
        )

        await #expect(
            throws: HistoricalProjectionCorrectionModelError.semanticIdentityUnchanged
        ) {
            _ = try await service.correct(
                rootProjectionID: audit.rootProjectionID,
                requestID: HistoricalProjectionCorrectionRequestID(
                    bytes: Array(repeating: 0x64, count: 16)
                ),
                input: HistoricalProjectionCorrectionInput(
                    formatVersion: HistoricalCorrectionInputFormatVersion(1),
                    canonicalBytes: fixture.input
                ),
                algorithmVersion: HistoricalFindingAlgorithmVersion(1),
                rankingPolicyVersion: HistoricalFindingRankingPolicyVersion(1)
            )
        }
        #expect(await repository.commands.isEmpty)
    }
}

private actor CorrectionServiceRepositoryStub: HistoricalProjectionCorrectionRepository {
    let audit: HistoricalProjectionCorrectionAuditRecord?
    let frames: [ObservationCommitSequence: HistoricalFindingObservationFrame]
    private(set) var commands: [HistoricalProjectionCorrectionCommand] = []
    private let storedRequest: HistoricalProjectionCorrectionStoredRequest?
    private let commitOutcome: HistoricalProjectionCorrectionCommitOutcome

    init(
        audit: HistoricalProjectionCorrectionAuditRecord?,
        frames: [HistoricalFindingObservationFrame],
        storedRequest: HistoricalProjectionCorrectionStoredRequest? = nil,
        commitOutcome: HistoricalProjectionCorrectionCommitOutcome? = nil
    ) throws {
        self.audit = audit
        self.frames = Dictionary(uniqueKeysWithValues: frames.map { ($0.sequence, $0) })
        self.storedRequest = storedRequest
        if let commitOutcome {
            self.commitOutcome = commitOutcome
        } else {
            self.commitOutcome = .newlyCommitted(
                try HistoricalCorrectingProjectionRecordID(71)
            )
        }
    }

    func historicalProjectionCorrectionStoredRequest(
        requestID: HistoricalProjectionCorrectionRequestID
    ) -> HistoricalProjectionCorrectionStoredRequest? {
        storedRequest
    }

    func historicalProjectionCorrectionAuditRecord(
        rootProjectionID: HistoricalProjectionRecordID
    ) -> HistoricalProjectionCorrectionAuditRecord? {
        guard audit?.rootProjectionID == rootProjectionID else { return nil }
        return audit
    }

    func historicalObservationFrame(
        sequence: ObservationCommitSequence
    ) -> HistoricalFindingObservationFrame? {
        frames[sequence]
    }

    func commitHistoricalProjectionCorrection(
        _ command: HistoricalProjectionCorrectionCommand
    ) throws -> HistoricalProjectionCorrectionCommitOutcome {
        commands.append(command)
        return commitOutcome
    }
}

private struct CorrectionRegistryFixture {
    let baseline: HistoricalFindingObservationFrame
    let comparison: HistoricalFindingObservationFrame
    let input: Data
    let semanticIdentity: HistoricalProjectionSemanticIdentity
    let result: HistoricalFindingGenerationResult
    let implementation: HistoricalProjectionCorrectionImplementation
}

private func correctionRegistryFixture() throws -> CorrectionRegistryFixture {
    let baseline = try correctionRegistryFrame(sequence: 10, prefix: "baseline", bytes: 10)
    let comparison = try correctionRegistryFrame(sequence: 20, prefix: "comparison", bytes: 20)
    let input = Data("fixture-correction-v1".utf8)
    let digest = try HistoricalProjectionCorrectionDigest(
        bytes: Array(SHA256.hash(data: input))
    )
    let semanticIdentity = try HistoricalProjectionSemanticIdentity(
        algorithmVersion: HistoricalFindingAlgorithmVersion(1),
        rankingPolicyVersion: HistoricalFindingRankingPolicyVersion(1),
        correctionInputFormatVersion: HistoricalCorrectionInputFormatVersion(1),
        correctionInputDigest: digest
    )
    let result = try HistoricalFindingGenerator().generate(
        baseline: baseline,
        comparison: comparison,
        positiveLimit: 10
    )
    let implementation = HistoricalProjectionCorrectionImplementation(
        algorithmVersion: try HistoricalFindingAlgorithmVersion(1),
        rankingPolicyVersion: try HistoricalFindingRankingPolicyVersion(1),
        correctionInputFormatVersion: try HistoricalCorrectionInputFormatVersion(1)
    ) { receivedInput, receivedBaseline, receivedComparison, positiveLimit in
        guard receivedInput == input else {
            throw HistoricalProjectionCorrectionRegistryError.invalidCanonicalInput
        }
        return try HistoricalFindingGenerator().generate(
            baseline: receivedBaseline,
            comparison: receivedComparison,
            positiveLimit: positiveLimit
        )
    }
    return CorrectionRegistryFixture(
        baseline: baseline,
        comparison: comparison,
        input: input,
        semanticIdentity: semanticIdentity,
        result: result,
        implementation: implementation
    )
}

private func correctionRegistryFrame(
    sequence: Int64,
    prefix: String,
    bytes: Int64,
    coverage: ObservationCoverage = .complete
) throws -> HistoricalFindingObservationFrame {
    let endpoint = try ObservationEndpoint(
        id: ObservationEndpointID("\(prefix)-root"),
        scopeID: ScopeID("scope-correction"),
        volumeID: ObservationVolumeID("volume-correction"),
        mountGenerationID: ObservationMountGenerationID("mount-correction"),
        coverageEpochID: ObservationCoverageEpochID("coverage-correction"),
        subjectID: SubjectID("root"),
        identityBasis: .normalizedPath,
        locationID: ObservationLocationID("location-root"),
        metric: .logical,
        pathSemanticsVersion: ObservationSemanticsVersion(1),
        measurementSemanticsVersion: ObservationSemanticsVersion(1),
        sequence: ObservationCommitSequence(sequence),
        observedAt: ObservationInstant(millisecondsSince1970: sequence * 1_000),
        state: .present(bytes: ByteCount(bytes), coverage: coverage)
    )
    let node = try HistoricalFindingNode(
        endpoint: endpoint,
        parentSubjectID: nil,
        path: "/Fixtures",
        displayName: "Fixtures",
        directChildrenCoverage: coverage,
        classification: VersionedAttributionDecision(
            catalogVersion: AttributionCatalogVersion(1),
            result: .unknown(.noMatchingRule)
        ),
        stableIdentityEvidence: nil
    )
    return try HistoricalFindingObservationFrame(
        rootSubjectID: SubjectID("root"),
        rootPath: "/Fixtures",
        nodes: [node]
    )
}

private func fixtureDigest(_ byte: UInt8) throws -> HistoricalProjectionCorrectionDigest {
    try HistoricalProjectionCorrectionDigest(bytes: Array(repeating: byte, count: 32))
}

private func correctionServiceAudit(
    fixture: CorrectionRegistryFixture
) throws -> HistoricalProjectionCorrectionAuditRecord {
    try HistoricalProjectionCorrectionAuditRecord(
        rootProjectionID: HistoricalProjectionRecordID(41),
        predecessorCorrectingProjectionID: nil,
        predecessor: HistoricalProjectionCorrectionReference(
            projectionID: HistoricalProjectionRecordID(41),
            projectionDigest: fixtureDigest(0x41),
            baselineSequence: fixture.baseline.sequence,
            comparisonSequence: fixture.comparison.sequence,
            scopeID: fixture.baseline.nodes[0].endpoint.scopeID,
            metric: fixture.baseline.nodes[0].endpoint.metric,
            semanticIdentity: HistoricalProjectionSemanticIdentity(
                algorithmVersion: HistoricalFindingAlgorithmVersion(1),
                rankingPolicyVersion: HistoricalFindingRankingPolicyVersion(1),
                correctionInputFormatVersion: nil,
                correctionInputDigest: nil
            )
        ),
        positiveLimit: 10
    )
}
