import DiskArbitration
import Foundation
import SpaceTraceApplication
import Testing
@testable import SpaceTracePlatform

struct DiskArbitrationVolumeEventSourceTests {
    @Test("A callback copies stable volume evidence into Sendable values")
    func copiesDescriptionEvidence() throws {
        let volumeUUID = try #require(
            UUID(uuidString: "11111111-2222-3333-4444-555555555555")
        )
        let description: NSDictionary = [
            kDADiskDescriptionVolumePathKey as String:
                URL(fileURLWithPath: "/Volumes/Projects", isDirectory: true),
            kDADiskDescriptionVolumeUUIDKey as String: volumeUUID as NSUUID,
        ]

        let observation = DiskArbitrationObservationFactory.make(
            kind: .appeared,
            bsdName: "disk9s1",
            description: description
        )

        #expect(
            observation == .appeared(
                DiskArbitrationVolumeSnapshot(
                    bsdName: "disk9s1",
                    mountPath: "/Volumes/Projects",
                    volumeUUID: volumeUUID
                )
            )
        )
        guard case let .appeared(snapshot) = observation else {
            Issue.record("Expected an appeared observation.")
            return
        }
        #expect(try snapshot.mountEvidence()?.mountPath.rawValue == "/Volumes/Projects")
        #expect(try snapshot.mountEvidence()?.volumeUUID == volumeUUID)
    }

    @Test("An unmounted or malformed path remains unknown instead of becoming a root path")
    func keepsUnavailableMountPathUnknown() {
        let description: NSDictionary = [
            kDADiskDescriptionVolumePathKey as String: "relative/path",
        ]

        let observation = DiskArbitrationObservationFactory.make(
            kind: .descriptionChanged,
            bsdName: "disk9s1",
            description: description
        )

        #expect(
            observation == .descriptionChanged(
                DiskArbitrationVolumeSnapshot(
                    bsdName: "disk9s1",
                    mountPath: nil,
                    volumeUUID: nil
                )
            )
        )
    }

    @Test("A callback buffer overflow replaces precision with an explicit continuity-loss marker")
    func emitsOverflowMarker() async throws {
        let pair = DiskArbitrationVolumeEventSource.EventStream.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let snapshot = DiskArbitrationVolumeSnapshot(
            bsdName: "disk9s1",
            mountPath: "/Volumes/Projects",
            volumeUUID: nil
        )

        DiskArbitrationCallbackBridge.yield(.appeared(snapshot), to: pair.continuation)
        DiskArbitrationCallbackBridge.yield(.descriptionChanged(snapshot), to: pair.continuation)
        pair.continuation.finish()

        var iterator = pair.stream.makeAsyncIterator()
        #expect(await iterator.next() == .callbackBridgeOverflow)
        #expect(await iterator.next() == nil)
    }

    @Test("The native source has single-subscription and idempotent-stop lifecycle")
    func nativeLifecycle() async throws {
        let source = DiskArbitrationVolumeEventSource()
        let stream = try source.start(bufferCapacity: 8)

        #expect(throws: DiskArbitrationVolumeEventSourceError.alreadyRunning) {
            try source.start(bufferCapacity: 8)
        }

        source.stop()
        source.stop()
        var iterator = stream.makeAsyncIterator()
        var bufferedCount = 0
        while await iterator.next() != nil {
            bufferedCount += 1
        }
        #expect(bufferedCount <= 8)
    }

    @Test("The callback buffer must be bounded by a positive capacity")
    func validatesBufferCapacity() {
        let source = DiskArbitrationVolumeEventSource()

        #expect(throws: DiskArbitrationVolumeEventSourceError.invalidBufferCapacity) {
            try source.start(bufferCapacity: 0)
        }
    }

    @Test("Native events map to application lifecycle signals without display-name identity")
    func mapsApplicationLifecycleSignal() throws {
        let volumeUUID = UUID()
        let mounted = DiskArbitrationVolumeSnapshot(
            bsdName: "disk9s1",
            mountPath: "/Volumes/Exchange",
            volumeUUID: volumeUUID
        )
        let unmounted = DiskArbitrationVolumeSnapshot(
            bsdName: "disk9s1",
            mountPath: nil,
            volumeUUID: volumeUUID
        )

        #expect(
            try DiskArbitrationVolumeEvent.appeared(mounted).lifecycleSignal()
                == .available(
                    VolumeMountObservation(
                        runtimeID: RuntimeVolumeID("disk9s1"),
                        evidence: mounted.mountEvidence(),
                        volumeUUID: volumeUUID
                    )
                )
        )
        #expect(
            try DiskArbitrationVolumeEvent.descriptionChanged(unmounted).lifecycleSignal()
                == .changed(
                    VolumeMountObservation(
                        runtimeID: RuntimeVolumeID("disk9s1"),
                        evidence: nil,
                        volumeUUID: volumeUUID
                    )
                )
        )
        #expect(try DiskArbitrationVolumeEvent.callbackBridgeOverflow.lifecycleSignal() == .continuityLost)
    }
}
