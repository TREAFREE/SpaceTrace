import CoreServices
import Darwin
import Foundation
import Testing
@testable import SpaceTraceFileSystem

extension Tag {
    @Tag static var nativeFSEvents: Self
}

@Suite(
    "Native FSEvents integration",
    .serialized,
    .tags(.nativeFSEvents)
)
struct NativeFSEventStreamIntegrationTests {
    @Test("A disposable APFS scope resolves to a persistent per-device identity")
    func resolvesPersistentDeviceIdentity() throws {
        let fixture = try DisposableAPFSFixture()
        defer { fixture.remove() }

        let scope = try FSEventDeviceScopeResolver().resolve(watchedURLs: [fixture.root])
        let identity = try #require(scope.persistentIdentity)

        #expect(scope.deviceTarget.deviceID > 0)
        #expect(scope.deviceTarget.relativePaths.count == 1)
        #expect(scope.deviceTarget.relativePaths[0].first != "/")
        #expect(scope.volumeUUID == identity.volumeUUID)
        #expect(identity.journalUUID == scope.journalUUID)
        #expect(identity.streamID.rawValue.hasPrefix("fsevents/v1/"))
    }

    @Test(
        "Live delivery, single subscription, cancellation, and stop are lifecycle-safe",
        .timeLimit(.minutes(1))
    )
    func liveDeliveryAndCancellation() async throws {
        let fixture = try DisposableAPFSFixture()
        defer { fixture.remove() }

        let client = FSEventStreamClient()
        let configuration = try configuration(for: fixture.root)
        let stream = try client.start(configuration: configuration)
        #expect(throws: FSEventStreamError.alreadyRunning) {
            _ = try client.start(configuration: configuration)
        }

        let signal = AsyncStream<FSEventObservation>.makeStream(
            bufferingPolicy: .bufferingNewest(256)
        )
        let consumer = Task { () throws -> Void in
            defer { signal.continuation.finish() }
            for try await observation in stream {
                signal.continuation.yield(observation)
            }
        }
        defer {
            consumer.cancel()
            client.stop()
        }

        _ = try fixture.createFile(named: "stream-ready.bin")
        try #require(client.flushSynchronously())
        _ = try await firstObservation(in: signal.stream)

        let target = try fixture.createFile(named: "live-event.bin")
        try #require(client.flushSynchronously())
        let observation = try await firstObservation(of: target, in: signal.stream)
        let cursor = try #require(observation.eventID)
        #expect(cursor.rawValue > 0)
        #expect(
            observation.reasons.isDisjoint(with: [.itemCreated, .itemRenamed]) == false
        )
        #expect(observation.reasons.contains(.itemIsFile))

        consumer.cancel()
        _ = await consumer.result

        let replacement = try client.start(configuration: configuration)
        client.stop()
        var iterator = replacement.makeAsyncIterator()
        #expect(try await iterator.next() == nil)
        client.stop()
    }

    @Test(
        "A completed native event can be replayed after its earlier device cursor",
        .timeLimit(.minutes(1))
    )
    func replaysHistoricalEvent() async throws {
        let fixture = try DisposableAPFSFixture()
        defer { fixture.remove() }

        let client = FSEventStreamClient()
        let liveConfiguration = try configuration(for: fixture.root)
        let liveStream = try client.start(configuration: liveConfiguration)
        defer { client.stop() }

        _ = try fixture.createFile(named: "stream-ready.bin")
        try #require(client.flushSynchronously())
        let readiness = try await firstObservation(in: liveStream)

        let cursorBeforeMutation = try #require(readiness.eventID)
        let target = try fixture.createFile(named: "replayed-event.bin")

        try #require(client.flushSynchronously())
        let liveObservation = try await firstObservation(of: target, in: liveStream)
        let liveEventID = try #require(liveObservation.eventID)
        #expect(liveEventID > cursorBeforeMutation)
        client.stop()

        let replayStream = try client.start(
            configuration: try configuration(
                for: fixture.root,
                replayPosition: .after(cursorBeforeMutation)
            )
        )
        try #require(client.flushSynchronously())
        let replayed = try await observationsThroughHistoryDone(in: replayStream)
        client.stop()

        let replayedMutation = try #require(
            replayed.first { $0.represents(target) }
        )
        #expect(replayedMutation.eventID == liveEventID)
        let historyDone = try #require(
            replayed.last { $0.reasons.contains(.historicalReplayCompleted) }
        )
        #expect(historyDone.path == nil)
    }

    @Test(
        "Native callback pressure emits a cursor-free overflow marker",
        .timeLimit(.minutes(1))
    )
    func reportsNativeCallbackBufferOverflow() async throws {
        let fixture = try DisposableAPFSFixture()
        defer { fixture.remove() }

        let client = FSEventStreamClient()
        let stream = try client.start(
            configuration: try configuration(for: fixture.root, bufferCapacity: 1)
        )
        defer { client.stop() }

        _ = try fixture.createFile(named: "stream-ready.bin")
        try #require(client.flushSynchronously())
        _ = try await firstObservation(in: stream)

        _ = try fixture.createFile(named: "overflow-one.bin")
        try #require(client.flushSynchronously())
        _ = try fixture.createFile(named: "overflow-two.bin")
        try #require(client.flushSynchronously())

        let overflow = try await firstOverflowMarker(in: stream)
        #expect(overflow.reasons == [.callbackBridgeOverflow])
        #expect(overflow.path == nil)
        #expect(overflow.eventID == nil)
    }

    private func configuration(
        for root: URL,
        replayPosition: FSEventReplayPosition = .sinceNow,
        bufferCapacity: Int = 256
    ) throws -> FSEventStreamConfiguration {
        let scope = try FSEventDeviceScopeResolver().resolve(watchedURLs: [root])
        return try scope.configuration(
            replayPosition: replayPosition,
            latency: 0.01,
            bufferCapacity: bufferCapacity,
            excludeEventsFromThisProcess: false
        )
    }

    private func firstObservation(
        of target: URL,
        in stream: FSEventStreamClient.ObservationStream
    ) async throws -> FSEventObservation {
        try await withIntegrationTimeout {
            for try await observation in stream {
                if observation.represents(target) {
                    return observation
                }
            }
            throw NativeFSEventIntegrationError.streamEndedBeforeExpectedEvidence
        }
    }

    private func firstObservation(
        of target: URL,
        in stream: AsyncStream<FSEventObservation>
    ) async throws -> FSEventObservation {
        try await withIntegrationTimeout {
            for await observation in stream {
                if observation.represents(target) {
                    return observation
                }
            }
            throw NativeFSEventIntegrationError.streamEndedBeforeExpectedEvidence
        }
    }

    private func firstObservation<Element: Sendable>(
        in stream: AsyncStream<Element>
    ) async throws -> Element {
        try await withIntegrationTimeout {
            for await element in stream {
                return element
            }
            throw NativeFSEventIntegrationError.streamEndedBeforeExpectedEvidence
        }
    }

    private func firstObservation(
        in stream: FSEventStreamClient.ObservationStream
    ) async throws -> FSEventObservation {
        try await withIntegrationTimeout {
            for try await observation in stream {
                return observation
            }
            throw NativeFSEventIntegrationError.streamEndedBeforeExpectedEvidence
        }
    }

    private func observationsThroughHistoryDone(
        in stream: FSEventStreamClient.ObservationStream
    ) async throws -> [FSEventObservation] {
        try await withIntegrationTimeout {
            var observations: [FSEventObservation] = []
            for try await observation in stream {
                observations.append(observation)
                if observation.reasons.contains(.historicalReplayCompleted) {
                    return observations
                }
            }
            throw NativeFSEventIntegrationError.streamEndedBeforeExpectedEvidence
        }
    }

    private func firstOverflowMarker(
        in stream: FSEventStreamClient.ObservationStream
    ) async throws -> FSEventObservation {
        try await withIntegrationTimeout {
            for try await observation in stream {
                if observation.reasons == [.callbackBridgeOverflow] {
                    return observation
                }
            }
            throw NativeFSEventIntegrationError.streamEndedBeforeExpectedEvidence
        }
    }
}

private struct DisposableAPFSFixture {
    let root: URL
    private let temporaryRoot: URL

    init() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let candidate = temporaryRoot
            .appendingPathComponent(
                "SpaceTraceFSEventsTests-\(UUID().uuidString)",
                isDirectory: true
            )
            .standardizedFileURL
        guard Self.isSafe(candidate, within: temporaryRoot, fileManager: fileManager) else {
            throw NativeFSEventIntegrationError.unsafeFixtureScope
        }

        try fileManager.createDirectory(
            at: candidate,
            withIntermediateDirectories: false
        )
        do {
            let fileSystem = try Self.fileSystemType(at: candidate)
            guard fileSystem == "apfs" else {
                throw NativeFSEventIntegrationError.unsupportedFileSystem(fileSystem)
            }
        } catch {
            try? fileManager.removeItem(at: candidate)
            throw error
        }

        self.root = candidate
        self.temporaryRoot = temporaryRoot
    }

    func createFile(named name: String) throws -> URL {
        guard name.isEmpty == false,
              name != ".",
              name != "..",
              name.contains("/") == false else {
            throw NativeFSEventIntegrationError.invalidFixtureName
        }
        let url = root.appendingPathComponent(name, isDirectory: false)
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: Data([0x53, 0x54])
        ) else {
            throw NativeFSEventIntegrationError.fixtureWriteFailed
        }
        return url.standardizedFileURL
    }

    func remove() {
        let fileManager = FileManager.default
        guard Self.isSafe(root, within: temporaryRoot, fileManager: fileManager) else {
            return
        }
        try? fileManager.removeItem(at: root)
    }

    private static func isSafe(
        _ candidate: URL,
        within temporaryRoot: URL,
        fileManager: FileManager
    ) -> Bool {
        let candidatePath = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        let temporaryPath = temporaryRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let homePath = fileManager.homeDirectoryForCurrentUser
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        return candidatePath != "/"
            && candidatePath != homePath
            && candidatePath.hasPrefix(homePath + "/") == false
            && candidatePath.hasPrefix(temporaryPath + "/")
    }

    private static func fileSystemType(at url: URL) throws -> String {
        var information = statfs()
        let result = url.path.withCString { pointer in
            statfs(pointer, &information)
        }
        guard result == 0 else {
            throw NativeFSEventIntegrationError.fileSystemInspectionFailed(errno)
        }
        return withUnsafeBytes(of: &information.f_fstypename) { bytes in
            guard let address = bytes.bindMemory(to: CChar.self).baseAddress else {
                return ""
            }
            return String(cString: address)
        }
    }
}

private extension FSEventObservation {
    func represents(_ target: URL) -> Bool {
        guard let path else { return false }
        return URL(fileURLWithPath: path).standardizedFileURL.path
            == target.standardizedFileURL.path
    }
}

private func withIntegrationTimeout<Value: Sendable>(
    _ duration: Duration = .seconds(10),
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw NativeFSEventIntegrationError.timedOut
        }
        guard let value = try await group.next() else {
            throw NativeFSEventIntegrationError.streamEndedBeforeExpectedEvidence
        }
        group.cancelAll()
        return value
    }
}

private enum NativeFSEventIntegrationError: Error, Sendable, Equatable {
    case unsafeFixtureScope
    case unsupportedFileSystem(String)
    case invalidFixtureName
    case fixtureWriteFailed
    case fileSystemInspectionFailed(Int32)
    case streamEndedBeforeExpectedEvidence
    case timedOut
}
