import CoreServices
import Testing
@testable import SpaceTraceFileSystem

struct FSEventFlagInterpreterTests {
    @Test("Public FSEvents flags map to semantic invalidation reasons", arguments: flagCases)
    func mapsPublicFlag(testCase: FlagCase) {
        let result = FSEventFlagInterpreter.interpret(UInt32(testCase.rawFlags))

        #expect(result.reasons.contains(testCase.expectedReason))
        let observation = FSEventObservation(
            path: "/watched/example",
            eventID: FSEventID(rawValue: 42),
            reasons: result.reasons,
            rawFlags: UInt32(testCase.rawFlags),
            unrecognizedFlags: result.unrecognizedFlags
        )
        #expect(observation.requiresCalibration == testCase.requiresCalibration)
    }

    @Test("A zero flag word remains a generic path invalidation")
    func mapsZeroFlags() {
        let result = FSEventFlagInterpreter.interpret(0)

        #expect(result.reasons == [.pathChanged])
        #expect(result.unrecognizedFlags == 0)
    }

    @Test("Combined flags preserve every semantic reason")
    func mapsCombinedFlags() {
        let flags = kFSEventStreamEventFlagMustScanSubDirs
            | kFSEventStreamEventFlagUserDropped
            | kFSEventStreamEventFlagItemCreated
            | kFSEventStreamEventFlagItemIsFile
        let result = FSEventFlagInterpreter.interpret(UInt32(flags))

        #expect(result.reasons.contains(.descendantsMustBeScanned))
        #expect(result.reasons.contains(.eventsDroppedByUserSpace))
        #expect(result.reasons.contains(.itemCreated))
        #expect(result.reasons.contains(.itemIsFile))
        #expect(result.unrecognizedFlags == 0)
    }

    @Test("Unknown future flags are preserved and require calibration")
    func preservesUnknownFlags() {
        let unknownFlag: FSEventStreamEventFlags = 0x8000_0000
        let result = FSEventFlagInterpreter.interpret(unknownFlag)
        let observation = FSEventObservation(
            path: "/watched/example",
            eventID: nil,
            reasons: result.reasons,
            rawFlags: UInt32(unknownFlag),
            unrecognizedFlags: result.unrecognizedFlags
        )

        #expect(result.reasons.contains(.unrecognizedFlags))
        #expect(result.unrecognizedFlags == UInt32(unknownFlag))
        #expect(observation.requiresCalibration)
        #expect(observation.indicatesContinuityGap)
    }
}

struct FlagCase: Sendable, CustomTestStringConvertible {
    let rawFlags: Int
    let expectedReason: FSEventReason
    let requiresCalibration: Bool

    var testDescription: String {
        expectedReason.rawValue
    }
}

private let flagCases: [FlagCase] = [
    FlagCase(
        rawFlags: kFSEventStreamEventFlagMustScanSubDirs,
        expectedReason: .descendantsMustBeScanned,
        requiresCalibration: true
    ),
    FlagCase(
        rawFlags: kFSEventStreamEventFlagUserDropped,
        expectedReason: .eventsDroppedByUserSpace,
        requiresCalibration: true
    ),
    FlagCase(
        rawFlags: kFSEventStreamEventFlagKernelDropped,
        expectedReason: .eventsDroppedByKernel,
        requiresCalibration: true
    ),
    FlagCase(
        rawFlags: kFSEventStreamEventFlagEventIdsWrapped,
        expectedReason: .eventIdentifiersWrapped,
        requiresCalibration: true
    ),
    FlagCase(
        rawFlags: kFSEventStreamEventFlagHistoryDone,
        expectedReason: .historicalReplayCompleted,
        requiresCalibration: false
    ),
    FlagCase(
        rawFlags: kFSEventStreamEventFlagRootChanged,
        expectedReason: .watchedRootChanged,
        requiresCalibration: true
    ),
    FlagCase(
        rawFlags: kFSEventStreamEventFlagMount,
        expectedReason: .volumeMounted,
        requiresCalibration: false
    ),
    FlagCase(
        rawFlags: kFSEventStreamEventFlagUnmount,
        expectedReason: .volumeUnmounted,
        requiresCalibration: false
    ),
    FlagCase(rawFlags: kFSEventStreamEventFlagItemCreated, expectedReason: .itemCreated, requiresCalibration: false),
    FlagCase(rawFlags: kFSEventStreamEventFlagItemRemoved, expectedReason: .itemRemoved, requiresCalibration: false),
    FlagCase(rawFlags: kFSEventStreamEventFlagItemInodeMetaMod, expectedReason: .itemMetadataModified, requiresCalibration: false),
    FlagCase(rawFlags: kFSEventStreamEventFlagItemRenamed, expectedReason: .itemRenamed, requiresCalibration: false),
    FlagCase(rawFlags: kFSEventStreamEventFlagItemModified, expectedReason: .itemContentModified, requiresCalibration: false),
    FlagCase(rawFlags: kFSEventStreamEventFlagItemFinderInfoMod, expectedReason: .itemFinderInfoModified, requiresCalibration: false),
    FlagCase(rawFlags: kFSEventStreamEventFlagItemChangeOwner, expectedReason: .itemOwnershipChanged, requiresCalibration: false),
    FlagCase(rawFlags: kFSEventStreamEventFlagItemXattrMod, expectedReason: .itemExtendedAttributesModified, requiresCalibration: false),
    FlagCase(rawFlags: kFSEventStreamEventFlagItemIsFile, expectedReason: .itemIsFile, requiresCalibration: false),
    FlagCase(rawFlags: kFSEventStreamEventFlagItemIsDir, expectedReason: .itemIsDirectory, requiresCalibration: false),
    FlagCase(rawFlags: kFSEventStreamEventFlagItemIsSymlink, expectedReason: .itemIsSymbolicLink, requiresCalibration: false),
    FlagCase(rawFlags: kFSEventStreamEventFlagOwnEvent, expectedReason: .eventOriginatedFromThisProcess, requiresCalibration: false),
    FlagCase(rawFlags: kFSEventStreamEventFlagItemIsHardlink, expectedReason: .itemIsHardLink, requiresCalibration: false),
    FlagCase(rawFlags: kFSEventStreamEventFlagItemIsLastHardlink, expectedReason: .itemWasLastHardLink, requiresCalibration: false),
    FlagCase(rawFlags: kFSEventStreamEventFlagItemCloned, expectedReason: .itemCloned, requiresCalibration: false),
]
