import SpaceTraceApplication

/// The anti-corruption layer between native FSEvents semantics and the
/// application-owned calibration pipeline.
public struct FSEventInvalidationMapper: Sendable {
    public init() {}

    public func map(_ observation: FSEventObservation) throws -> FileSystemInvalidation? {
        if observation.reasons == [.historicalReplayCompleted] {
            return nil
        }

        var reasons: DirtyRegionReason = []
        for reason in observation.reasons {
            reasons.formUnion(map(reason))
        }
        guard reasons.isEmpty == false else {
            return nil
        }

        let cursor: EventJournalCursor?
        if observation.reasons.isDisjoint(with: Self.cursorInvalidatingReasons) == false {
            cursor = nil
        } else {
            cursor = observation.eventID.map { EventJournalCursor($0.rawValue) }
        }

        return try FileSystemInvalidation(
            path: observation.path,
            cursor: cursor,
            reasons: reasons,
            itemKind: itemKind(from: observation.reasons),
            invalidatesStoredCursor: observation.reasons.contains(.eventIdentifiersWrapped)
        )
    }

    private static let cursorInvalidatingReasons: Set<FSEventReason> = [
        .eventsDroppedByUserSpace,
        .eventsDroppedByKernel,
        .eventIdentifiersWrapped,
        .watchedRootChanged,
        .callbackBridgeOverflow,
        .unrecognizedFlags,
    ]

    private func itemKind(from reasons: Set<FSEventReason>) -> FileSystemItemKind {
        let kinds: [(FSEventReason, FileSystemItemKind)] = [
            (.itemIsFile, .file),
            (.itemIsDirectory, .directory),
            (.itemIsSymbolicLink, .symbolicLink),
        ]
        let matches = kinds.compactMap { reasons.contains($0.0) ? $0.1 : nil }
        return matches.count == 1 ? matches[0] : .unknown
    }

    private func map(_ reason: FSEventReason) -> DirtyRegionReason {
        switch reason {
        case .pathChanged:
            return .metadataChanged
        case .descendantsMustBeScanned:
            return [.mustScanSubdirectories, .requiresCalibration]
        case .eventsDroppedByUserSpace, .eventsDroppedByKernel,
             .eventIdentifiersWrapped, .callbackBridgeOverflow,
             .unrecognizedFlags:
            return [.droppedEvents, .requiresCalibration]
        case .watchedRootChanged:
            return [.rootChanged, .requiresCalibration]
        case .volumeMounted, .volumeUnmounted:
            return [.mountChanged, .requiresCalibration]
        case .itemCreated:
            return .created
        case .itemRemoved:
            return .removed
        case .itemRenamed:
            return .renamed
        case .itemContentModified, .itemCloned:
            return .contentModified
        case .itemMetadataModified, .itemFinderInfoModified,
             .itemOwnershipChanged, .itemExtendedAttributesModified,
             .itemIsHardLink, .itemWasLastHardLink:
            return .metadataChanged
        case .historicalReplayCompleted, .itemIsFile, .itemIsDirectory,
             .itemIsSymbolicLink, .eventOriginatedFromThisProcess:
            return []
        }
    }
}
