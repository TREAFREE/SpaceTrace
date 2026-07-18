import CoreServices

struct FSEventFlagInterpretation: Equatable, Sendable {
    let reasons: Set<FSEventReason>
    let unrecognizedFlags: UInt32
}

enum FSEventFlagInterpreter {
    static func interpret(_ flags: FSEventStreamEventFlags) -> FSEventFlagInterpretation {
        let rawFlags = UInt32(flags)
        var reasons: Set<FSEventReason> = []

        append(.descendantsMustBeScanned, when: kFSEventStreamEventFlagMustScanSubDirs, isSetIn: rawFlags, to: &reasons)
        append(.eventsDroppedByUserSpace, when: kFSEventStreamEventFlagUserDropped, isSetIn: rawFlags, to: &reasons)
        append(.eventsDroppedByKernel, when: kFSEventStreamEventFlagKernelDropped, isSetIn: rawFlags, to: &reasons)
        append(.eventIdentifiersWrapped, when: kFSEventStreamEventFlagEventIdsWrapped, isSetIn: rawFlags, to: &reasons)
        append(.historicalReplayCompleted, when: kFSEventStreamEventFlagHistoryDone, isSetIn: rawFlags, to: &reasons)
        append(.watchedRootChanged, when: kFSEventStreamEventFlagRootChanged, isSetIn: rawFlags, to: &reasons)
        append(.volumeMounted, when: kFSEventStreamEventFlagMount, isSetIn: rawFlags, to: &reasons)
        append(.volumeUnmounted, when: kFSEventStreamEventFlagUnmount, isSetIn: rawFlags, to: &reasons)
        append(.itemCreated, when: kFSEventStreamEventFlagItemCreated, isSetIn: rawFlags, to: &reasons)
        append(.itemRemoved, when: kFSEventStreamEventFlagItemRemoved, isSetIn: rawFlags, to: &reasons)
        append(.itemMetadataModified, when: kFSEventStreamEventFlagItemInodeMetaMod, isSetIn: rawFlags, to: &reasons)
        append(.itemRenamed, when: kFSEventStreamEventFlagItemRenamed, isSetIn: rawFlags, to: &reasons)
        append(.itemContentModified, when: kFSEventStreamEventFlagItemModified, isSetIn: rawFlags, to: &reasons)
        append(.itemFinderInfoModified, when: kFSEventStreamEventFlagItemFinderInfoMod, isSetIn: rawFlags, to: &reasons)
        append(.itemOwnershipChanged, when: kFSEventStreamEventFlagItemChangeOwner, isSetIn: rawFlags, to: &reasons)
        append(.itemExtendedAttributesModified, when: kFSEventStreamEventFlagItemXattrMod, isSetIn: rawFlags, to: &reasons)
        append(.itemIsFile, when: kFSEventStreamEventFlagItemIsFile, isSetIn: rawFlags, to: &reasons)
        append(.itemIsDirectory, when: kFSEventStreamEventFlagItemIsDir, isSetIn: rawFlags, to: &reasons)
        append(.itemIsSymbolicLink, when: kFSEventStreamEventFlagItemIsSymlink, isSetIn: rawFlags, to: &reasons)
        append(.eventOriginatedFromThisProcess, when: kFSEventStreamEventFlagOwnEvent, isSetIn: rawFlags, to: &reasons)
        append(.itemIsHardLink, when: kFSEventStreamEventFlagItemIsHardlink, isSetIn: rawFlags, to: &reasons)
        append(.itemWasLastHardLink, when: kFSEventStreamEventFlagItemIsLastHardlink, isSetIn: rawFlags, to: &reasons)
        append(.itemCloned, when: kFSEventStreamEventFlagItemCloned, isSetIn: rawFlags, to: &reasons)

        let unknown = rawFlags & ~knownFlagMask
        if unknown != 0 {
            reasons.insert(.unrecognizedFlags)
        }

        if rawFlags == 0 {
            reasons.insert(.pathChanged)
        }

        return FSEventFlagInterpretation(
            reasons: reasons,
            unrecognizedFlags: unknown
        )
    }

    private static func append(
        _ reason: FSEventReason,
        when flag: Int,
        isSetIn rawFlags: UInt32,
        to reasons: inout Set<FSEventReason>
    ) {
        if rawFlags & UInt32(flag) != 0 {
            reasons.insert(reason)
        }
    }

    private static let knownFlagMask: UInt32 = [
        kFSEventStreamEventFlagMustScanSubDirs,
        kFSEventStreamEventFlagUserDropped,
        kFSEventStreamEventFlagKernelDropped,
        kFSEventStreamEventFlagEventIdsWrapped,
        kFSEventStreamEventFlagHistoryDone,
        kFSEventStreamEventFlagRootChanged,
        kFSEventStreamEventFlagMount,
        kFSEventStreamEventFlagUnmount,
        kFSEventStreamEventFlagItemCreated,
        kFSEventStreamEventFlagItemRemoved,
        kFSEventStreamEventFlagItemInodeMetaMod,
        kFSEventStreamEventFlagItemRenamed,
        kFSEventStreamEventFlagItemModified,
        kFSEventStreamEventFlagItemFinderInfoMod,
        kFSEventStreamEventFlagItemChangeOwner,
        kFSEventStreamEventFlagItemXattrMod,
        kFSEventStreamEventFlagItemIsFile,
        kFSEventStreamEventFlagItemIsDir,
        kFSEventStreamEventFlagItemIsSymlink,
        kFSEventStreamEventFlagOwnEvent,
        kFSEventStreamEventFlagItemIsHardlink,
        kFSEventStreamEventFlagItemIsLastHardlink,
        kFSEventStreamEventFlagItemCloned,
    ].reduce(0) { $0 | UInt32($1) }
}
