import Foundation

/// Persistent identity for one volume-local FSEvents journal generation.
///
/// The volume UUID identifies the filesystem volume across mounts. The
/// journal UUID identifies the FSEvents history currently stored on that
/// volume and changes when that history is replaced or becomes incompatible.
/// The ephemeral `dev_t` used to open a native stream is deliberately absent.
public struct PersistentEventStreamIdentity: Sendable, Equatable, Hashable, Codable {
    public let volumeUUID: UUID
    public let journalUUID: UUID

    public init(volumeUUID: UUID, journalUUID: UUID) {
        self.volumeUUID = volumeUUID
        self.journalUUID = journalUUID
    }

    /// Canonical persistence key used by the event-journal repository.
    public var streamID: EventStreamID {
        EventStreamID(
            validatedRawValue: "fsevents/v1/\(Self.canonical(volumeUUID))/\(Self.canonical(journalUUID))"
        )
    }

    public func continuity(
        from previous: PersistentEventStreamIdentity
    ) -> EventStreamContinuity {
        guard volumeUUID == previous.volumeUUID else {
            return .volumeChanged
        }
        guard journalUUID == previous.journalUUID else {
            return .journalGenerationChanged
        }
        return .continuous
    }

    private static func canonical(_ uuid: UUID) -> String {
        uuid.uuidString.lowercased()
    }
}

public enum EventStreamContinuity: String, Sendable, Equatable, Codable {
    case continuous
    case volumeChanged
    case journalGenerationChanged
}
