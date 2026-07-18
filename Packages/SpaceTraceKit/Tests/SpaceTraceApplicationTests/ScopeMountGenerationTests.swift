import Foundation
import Testing
@testable import SpaceTraceApplication

struct ScopeMountGenerationTests {
    @Test(
        "Scope and mount generation identifiers reject unsafe persistence keys",
        arguments: ["", " ", " leading", "trailing ", "contains\0null"]
    )
    func rejectsUnsafeIdentifiers(rawValue: String) {
        #expect(throws: ScopeMountGenerationError.invalidScopeID) {
            try WatchedScopeID(rawValue)
        }
        #expect(throws: ScopeMountGenerationError.invalidMountGenerationID) {
            try MountGenerationID(rawValue)
        }
    }

    @Test("The first mounted observation opens a calibration-required generation")
    func opensFirstGeneration() throws {
        let fixture = try fixture()
        let evidence = try VolumeMountEvidence(
            mountPath: DirtyRegionPath("/Volumes/Projects"),
            volumeUUID: fixture.volumeA
        )

        let transition = ScopeMountGenerationStateMachine.activate(
            previous: nil,
            scopeID: fixture.scopeID,
            evidence: evidence,
            proposedGenerationID: fixture.firstGeneration
        )

        #expect(transition.reason == .firstMount)
        #expect(transition.requiresCalibration)
        #expect(transition.current.generationID == fixture.firstGeneration)
        #expect(transition.current.isActive)
    }

    @Test("Duplicate callbacks reuse the active mount generation")
    func deduplicatesActiveMount() throws {
        let fixture = try fixture()
        let evidence = try VolumeMountEvidence(
            mountPath: DirtyRegionPath("/Volumes/Projects"),
            volumeUUID: fixture.volumeA
        )
        let previous = ScopeMountGeneration(
            scopeID: fixture.scopeID,
            generationID: fixture.firstGeneration,
            mountPath: evidence.mountPath,
            volumeUUID: fixture.volumeA,
            isActive: true
        )

        let transition = ScopeMountGenerationStateMachine.activate(
            previous: previous,
            scopeID: fixture.scopeID,
            evidence: evidence,
            proposedGenerationID: fixture.nextGeneration
        )

        #expect(transition.reason == .duplicateNotification)
        #expect(transition.requiresCalibration == false)
        #expect(transition.current == previous)
    }

    @Test("An active volume rename keeps its generation but requires scope revalidation")
    func updatesMountPathWithoutInventingRemount() throws {
        let fixture = try fixture()
        let previous = ScopeMountGeneration(
            scopeID: fixture.scopeID,
            generationID: fixture.firstGeneration,
            mountPath: try DirtyRegionPath("/Volumes/Old Name"),
            volumeUUID: fixture.volumeA,
            isActive: true
        )
        let evidence = try VolumeMountEvidence(
            mountPath: DirtyRegionPath("/Volumes/New Name"),
            volumeUUID: fixture.volumeA
        )

        let transition = ScopeMountGenerationStateMachine.activate(
            previous: previous,
            scopeID: fixture.scopeID,
            evidence: evidence,
            proposedGenerationID: fixture.nextGeneration
        )

        #expect(transition.reason == .activeMountUpdated)
        #expect(transition.requiresCalibration)
        #expect(transition.current.generationID == fixture.firstGeneration)
        #expect(transition.current.mountPath == evidence.mountPath)
    }

    @Test("A remount always opens a new generation even for the same volume UUID")
    func opensNewGenerationAfterUnmount() throws {
        let fixture = try fixture()
        let previous = ScopeMountGeneration(
            scopeID: fixture.scopeID,
            generationID: fixture.firstGeneration,
            mountPath: try DirtyRegionPath("/Volumes/Projects"),
            volumeUUID: fixture.volumeA,
            isActive: false
        )
        let evidence = try VolumeMountEvidence(
            mountPath: DirtyRegionPath("/Volumes/Projects"),
            volumeUUID: fixture.volumeA
        )

        let transition = ScopeMountGenerationStateMachine.activate(
            previous: previous,
            scopeID: fixture.scopeID,
            evidence: evidence,
            proposedGenerationID: fixture.nextGeneration
        )

        #expect(transition.reason == .remountedSameVolume)
        #expect(transition.requiresCalibration)
        #expect(transition.current.generationID == fixture.nextGeneration)
    }

    @Test("A replacement volume cannot inherit a generation from the same mount name")
    func detectsReplacementVolume() throws {
        let fixture = try fixture()
        let previous = ScopeMountGeneration(
            scopeID: fixture.scopeID,
            generationID: fixture.firstGeneration,
            mountPath: try DirtyRegionPath("/Volumes/Projects"),
            volumeUUID: fixture.volumeA,
            isActive: true
        )
        let evidence = try VolumeMountEvidence(
            mountPath: DirtyRegionPath("/Volumes/Projects"),
            volumeUUID: fixture.volumeB
        )

        let transition = ScopeMountGenerationStateMachine.activate(
            previous: previous,
            scopeID: fixture.scopeID,
            evidence: evidence,
            proposedGenerationID: fixture.nextGeneration
        )

        #expect(transition.reason == .replacementVolume)
        #expect(transition.requiresCalibration)
        #expect(transition.current.generationID == fixture.nextGeneration)
        #expect(transition.current.volumeUUID == fixture.volumeB)
    }

    @Test("Missing stable identity stays explicit and cannot claim continuity")
    func preservesUnknownIdentity() throws {
        let fixture = try fixture()
        let evidence = try VolumeMountEvidence(
            mountPath: DirtyRegionPath("/Volumes/Unknown"),
            volumeUUID: nil
        )

        let transition = ScopeMountGenerationStateMachine.activate(
            previous: nil,
            scopeID: fixture.scopeID,
            evidence: evidence,
            proposedGenerationID: fixture.firstGeneration
        )

        #expect(transition.reason == .identityUnavailable)
        #expect(transition.requiresCalibration)
        #expect(transition.current.volumeUUID == nil)
    }

    @Test("Missing current identity cannot silently inherit a known active volume")
    func doesNotInheritKnownIdentityFromAmbiguousMount() throws {
        let fixture = try fixture()
        let previous = ScopeMountGeneration(
            scopeID: fixture.scopeID,
            generationID: fixture.firstGeneration,
            mountPath: try DirtyRegionPath("/Volumes/Projects"),
            volumeUUID: fixture.volumeA,
            isActive: true
        )
        let evidence = try VolumeMountEvidence(
            mountPath: DirtyRegionPath("/Volumes/Projects"),
            volumeUUID: nil
        )

        let transition = ScopeMountGenerationStateMachine.activate(
            previous: previous,
            scopeID: fixture.scopeID,
            evidence: evidence,
            proposedGenerationID: fixture.nextGeneration
        )

        #expect(transition.reason == .identityUnavailable)
        #expect(transition.requiresCalibration)
        #expect(transition.current.generationID == fixture.nextGeneration)
        #expect(transition.current.volumeUUID == nil)
    }

    private func fixture() throws -> Fixture {
        Fixture(
            scopeID: try WatchedScopeID("scope-primary"),
            firstGeneration: try MountGenerationID("mount-generation-1"),
            nextGeneration: try MountGenerationID("mount-generation-2"),
            volumeA: try #require(
                UUID(uuidString: "11111111-2222-3333-4444-555555555555")
            ),
            volumeB: try #require(
                UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
            )
        )
    }

    private struct Fixture {
        let scopeID: WatchedScopeID
        let firstGeneration: MountGenerationID
        let nextGeneration: MountGenerationID
        let volumeA: UUID
        let volumeB: UUID
    }
}
