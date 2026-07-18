import CoreServices
import Testing
@testable import SpaceTraceFileSystem

struct FSEventStreamClientTests {
    @Test("Invalid configuration throws a typed error", arguments: invalidConfigurations)
    func rejectsInvalidConfiguration(testCase: InvalidConfigurationCase) {
        let client = FSEventStreamClient()

        #expect(throws: FSEventStreamError.invalidConfiguration(testCase.expectedError)) {
            _ = try client.start(configuration: testCase.configuration)
        }
    }

    @Test("Buffer overflow emits a calibration gap instead of failing silently")
    func overflowEmitsCalibrationGap() async throws {
        let streamPair = FSEventStreamClient.ObservationStream.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let first = observation(id: 1)
        let second = observation(id: 2)

        FSEventCallbackBridge.yield(first, to: streamPair.continuation)
        FSEventCallbackBridge.yield(second, to: streamPair.continuation)
        streamPair.continuation.finish()

        var iterator = streamPair.stream.makeAsyncIterator()
        let emitted = try #require(try await iterator.next())
        #expect(emitted.path == nil)
        #expect(emitted.eventID == second.eventID)
        #expect(emitted.reasons == [.callbackBridgeOverflow])
        #expect(emitted.requiresCalibration)
        #expect(emitted.indicatesContinuityGap)
        #expect(try await iterator.next() == nil)
    }

    @Test("Historical replay requests the overlapping restart-safe chunk")
    func historicalReplayUsesFullHistory() {
        let configuration = FSEventStreamConfiguration(
            watchedPaths: ["/watched"],
            replayPosition: .after(FSEventID(rawValue: 42))
        )

        #expect(
            configuration.nativeCreateFlags
                & FSEventStreamCreateFlags(kFSEventStreamCreateFlagFullHistory) != 0
        )
    }

    @Test("Root changes do not expose the zero sentinel as a journal cursor")
    func rootChangeSuppressesSentinelCursor() {
        let observation = FSEventObservationFactory.make(
            "/watched",
            eventID: 0,
            rawFlags: FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)
        )

        #expect(observation.path == "/watched")
        #expect(observation.eventID == nil)
        #expect(observation.reasons.contains(.watchedRootChanged))
        #expect(observation.requiresCalibration)
    }

    private func observation(id: UInt64) -> FSEventObservation {
        FSEventObservation(
            path: "/watched/file-\(id)",
            eventID: FSEventID(rawValue: id),
            reasons: [.itemContentModified],
            rawFlags: 0
        )
    }
}

struct InvalidConfigurationCase: Sendable, CustomTestStringConvertible {
    let name: String
    let configuration: FSEventStreamConfiguration
    let expectedError: FSEventStreamConfigurationError

    var testDescription: String { name }
}

private let invalidConfigurations: [InvalidConfigurationCase] = [
    InvalidConfigurationCase(
        name: "empty path list",
        configuration: FSEventStreamConfiguration(watchedPaths: []),
        expectedError: .noWatchedPaths
    ),
    InvalidConfigurationCase(
        name: "relative path",
        configuration: FSEventStreamConfiguration(watchedPaths: ["relative/path"]),
        expectedError: .watchedPathMustBeAbsolute(index: 0)
    ),
    InvalidConfigurationCase(
        name: "negative latency",
        configuration: FSEventStreamConfiguration(watchedPaths: ["/watched"], latency: -1),
        expectedError: .latencyMustBeFiniteAndNonnegative
    ),
    InvalidConfigurationCase(
        name: "non-finite latency",
        configuration: FSEventStreamConfiguration(watchedPaths: ["/watched"], latency: .infinity),
        expectedError: .latencyMustBeFiniteAndNonnegative
    ),
    InvalidConfigurationCase(
        name: "zero capacity",
        configuration: FSEventStreamConfiguration(watchedPaths: ["/watched"], bufferCapacity: 0),
        expectedError: .bufferCapacityMustBePositive
    ),
]
