import Foundation
import Testing
import SpaceTraceAttribution
import SpaceTraceDomain
@testable import SpaceTraceApplication

struct HistoricalCalibrationCandidateBuilderTests {
    @Test("A complete directory scan freezes path identity and versioned classification")
    func buildsPathBasedCandidate() throws {
        let root = try DirtyRegionPath("/Users/example")
        let library = try DirtyRegionPath("/Users/example/Library")
        let caches = try DirtyRegionPath("/Users/example/Library/Caches")
        let observedAt = try ObservationInstant(millisecondsSince1970: 1_800_000_000_000)
        let evidence = try HistoricalCalibrationScanEvidence(
            rootPath: root,
            directories: [
                try HistoricalDirectoryScanObservation(
                    path: caches,
                    parentPath: library,
                    logicalBytes: try ByteCount(30),
                    allocatedBytes: try ByteCount(40),
                    directChildrenCoverage: .complete,
                    observedAt: observedAt,
                    objectIdentity: nil
                ),
                try HistoricalDirectoryScanObservation(
                    path: library,
                    parentPath: root,
                    logicalBytes: try ByteCount(60),
                    allocatedBytes: try ByteCount(80),
                    directChildrenCoverage: .complete,
                    observedAt: observedAt,
                    objectIdentity: nil
                ),
                try HistoricalDirectoryScanObservation(
                    path: root,
                    parentPath: nil,
                    logicalBytes: try ByteCount(100),
                    allocatedBytes: try ByteCount(120),
                    directChildrenCoverage: .complete,
                    observedAt: observedAt,
                    objectIdentity: nil
                ),
            ]
        )

        let candidate = try HistoricalCalibrationCandidateBuilder().build(
            evidence,
            context: try historicalContext(homeDirectoryPath: "/Users/example")
        )

        #expect(candidate.nodes.count == 3)
        let rootNode = try #require(candidate.nodes.first { $0.path == root.rawValue })
        let libraryNode = try #require(candidate.nodes.first { $0.path == library.rawValue })
        let cacheNode = try #require(candidate.nodes.first { $0.path == caches.rawValue })
        #expect(candidate.rootSubjectID == rootNode.subjectID)
        #expect(rootNode.identityBasis == .normalizedPath)
        #expect(rootNode.stableIdentityEvidence == nil)
        #expect(libraryNode.parentSubjectID == rootNode.subjectID)
        #expect(cacheNode.parentSubjectID == libraryNode.subjectID)
        #expect(cacheNode.identityBasis == .normalizedPath)
        #expect(cacheNode.stableIdentityEvidence == nil)
        #expect(cacheNode.subjectID.rawValue.hasPrefix("path-v1:"))
        #expect(cacheNode.locationID.rawValue.hasPrefix("location-v1:"))

        guard case let .classified(attribution) = cacheNode.classification?.result else {
            Issue.record("Expected the built-in cache rule to be frozen.")
            return
        }
        let expectedRuleID = try AttributionRuleID("generic.user-caches")
        #expect(attribution.category == .logsAndCaches)
        #expect(attribution.ruleID == expectedRuleID)
    }

    @Test("Stable identity requires qualified APFS object, reuse, and link-set evidence")
    func qualifiesStableIdentityConservatively() throws {
        let firstPath = try DirtyRegionPath("/Volumes/Fixture/Before")
        let secondPath = try DirtyRegionPath("/Volumes/Fixture/After")
        let birthTime = try HistoricalFindingBirthTime(
            secondsSince1970: 1_700_000_000,
            nanoseconds: 123_456_789
        )
        let qualified = HistoricalDirectoryObjectIdentityObservation(
            fileSystem: .apfs,
            volumeLocalObjectID: 42,
            birthTime: birthTime,
            linkStatus: .unique
        )
        let unqualified = HistoricalDirectoryObjectIdentityObservation(
            fileSystem: .apfs,
            volumeLocalObjectID: 42,
            birthTime: birthTime,
            linkStatus: .unknown
        )
        let builder = HistoricalCalibrationCandidateBuilder()
        let context = try historicalContext(homeDirectoryPath: nil)

        let stableBefore = try builder.build(
            singleDirectoryEvidence(path: firstPath, identity: qualified),
            context: context
        ).nodes[0]
        let stableAfter = try builder.build(
            singleDirectoryEvidence(path: secondPath, identity: qualified),
            context: context
        ).nodes[0]
        let conservative = try builder.build(
            singleDirectoryEvidence(path: firstPath, identity: unqualified),
            context: context
        ).nodes[0]

        #expect(stableBefore.identityBasis == .stableFileSystemObject)
        #expect(stableBefore.subjectID == stableAfter.subjectID)
        #expect(stableBefore.locationID != stableAfter.locationID)
        let expectedStableEvidence = try HistoricalFindingStableIdentityEvidence(
            reuseGuard: .birthTime(birthTime),
            nodeKind: .directory,
            linkStatus: .unique
        )
        #expect(stableBefore.stableIdentityEvidence == expectedStableEvidence)
        #expect(conservative.identityBasis == .normalizedPath)
        #expect(conservative.stableIdentityEvidence == nil)
    }

    @Test("A reused APFS object number with a different birth time receives a new subject")
    func stableSubjectIncludesTheReuseGuard() throws {
        let path = try DirtyRegionPath("/Volumes/Fixture/Object")
        let firstBirthTime = try HistoricalFindingBirthTime(
            secondsSince1970: 1_700_000_000,
            nanoseconds: 123
        )
        let reusedBirthTime = try HistoricalFindingBirthTime(
            secondsSince1970: 1_700_000_001,
            nanoseconds: 456
        )
        let builder = HistoricalCalibrationCandidateBuilder()
        let context = try historicalContext(homeDirectoryPath: nil)

        let first = try builder.build(
            singleDirectoryEvidence(
                path: path,
                identity: HistoricalDirectoryObjectIdentityObservation(
                    fileSystem: .apfs,
                    volumeLocalObjectID: 42,
                    birthTime: firstBirthTime,
                    linkStatus: .unique
                )
            ),
            context: context
        ).nodes[0]
        let reused = try builder.build(
            singleDirectoryEvidence(
                path: path,
                identity: HistoricalDirectoryObjectIdentityObservation(
                    fileSystem: .apfs,
                    volumeLocalObjectID: 42,
                    birthTime: reusedBirthTime,
                    linkStatus: .unique
                )
            ),
            context: context
        ).nodes[0]

        #expect(first.subjectID != reused.subjectID)
        #expect(first.locationID == reused.locationID)
    }

    @Test("Coverage epochs remain stable within one authorized mount generation")
    func derivesCoverageEpochFromAuthorizedMount() throws {
        let scope = try WatchedScopeID("scope-fixture")
        let volume = try #require(UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"))
        let first = try HistoricalCalibrationContext(
            watchedScopeID: scope,
            volumeUUID: volume,
            mountGenerationID: try MountGenerationID("mount-a"),
            homeDirectoryPath: nil
        )
        let repeated = try HistoricalCalibrationContext(
            watchedScopeID: scope,
            volumeUUID: volume,
            mountGenerationID: try MountGenerationID("mount-a"),
            homeDirectoryPath: nil
        )
        let remounted = try HistoricalCalibrationContext(
            watchedScopeID: scope,
            volumeUUID: volume,
            mountGenerationID: try MountGenerationID("mount-b"),
            homeDirectoryPath: nil
        )

        #expect(first == repeated)
        #expect(first.coverageEpochID != remounted.coverageEpochID)
        #expect(first.mountGenerationID != remounted.mountGenerationID)
    }
}

private func historicalContext(
    homeDirectoryPath: String?
) throws -> HistoricalCalibrationContext {
    try HistoricalCalibrationContext(
        scopeID: ScopeID("scope-fixture"),
        volumeID: ObservationVolumeID("volume-fixture"),
        mountGenerationID: ObservationMountGenerationID("mount-fixture"),
        coverageEpochID: ObservationCoverageEpochID("coverage-fixture"),
        homeDirectoryPath: homeDirectoryPath
    )
}

private func singleDirectoryEvidence(
    path: DirtyRegionPath,
    identity: HistoricalDirectoryObjectIdentityObservation
) throws -> HistoricalCalibrationScanEvidence {
    try HistoricalCalibrationScanEvidence(
        rootPath: path,
        directories: [
            try HistoricalDirectoryScanObservation(
                path: path,
                parentPath: nil,
                logicalBytes: try ByteCount(1),
                allocatedBytes: try ByteCount(2),
                directChildrenCoverage: .complete,
                observedAt: try ObservationInstant(millisecondsSince1970: 1_800_000_000_000),
                objectIdentity: identity
            ),
        ]
    )
}
