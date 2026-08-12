import SpaceTraceDomain

public struct ReconciliationRevisionID: Sendable, Equatable, Hashable, Comparable {
    public let rawValue: Int64

    public init(_ rawValue: Int64) throws(ReconciliationRevisionModelError) {
        guard rawValue > 0 else { throw .invalidRecordID(rawValue) }
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct ReconciliationRevisionSequence: Sendable, Equatable, Hashable, Comparable {
    public let rawValue: Int64

    public init(_ rawValue: Int64) throws(ReconciliationRevisionModelError) {
        guard rawValue > 0 else { throw .invalidSequence(rawValue) }
        self.rawValue = rawValue
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct ReconciliationRevisionDigest: Sendable, Equatable, Hashable {
    public let bytes: [UInt8]

    public init(bytes: [UInt8]) throws(ReconciliationRevisionModelError) {
        guard bytes.count == 32 else { throw .invalidDigestLength(bytes.count) }
        self.bytes = bytes
    }
}

/// The exact identity of one provisional hourly/daily read-model slot.
///
/// String-backed identifiers remain opaque UTF-8 bytes here. Swift String's
/// canonical-equivalence equality must not merge two different persisted keys.
public struct ReconciliationRevisionKey: Sendable, Equatable, Hashable {
    public let scopeID: WatchedScopeID
    public let streamID: EventStreamID
    public let subjectID: SubjectID
    public let locationID: ObservationLocationID
    public let bucket: DirectoryHistoryBucket
    public let bucketStart: ObservationInstant

    public init(
        scopeID: WatchedScopeID,
        streamID: EventStreamID,
        subjectID: SubjectID,
        locationID: ObservationLocationID,
        bucket: DirectoryHistoryBucket,
        bucketStart: ObservationInstant
    ) throws(ReconciliationRevisionModelError) {
        guard bucketStart.millisecondsSince1970 % bucket.durationMilliseconds == 0 else {
            throw .misalignedBucketStart
        }
        guard Self.isBoundedOpaqueKey(scopeID.rawValue),
              Self.isBoundedOpaqueKey(streamID.rawValue),
              Self.isBoundedOpaqueKey(subjectID.rawValue),
              Self.isBoundedOpaqueKey(locationID.rawValue) else {
            throw .invalidOpaqueIdentity
        }

        self.scopeID = scopeID
        self.streamID = streamID
        self.subjectID = subjectID
        self.locationID = locationID
        self.bucket = bucket
        self.bucketStart = bucketStart
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        reconciliationRevisionBinaryEqual(lhs.scopeID.rawValue, rhs.scopeID.rawValue)
            && reconciliationRevisionBinaryEqual(lhs.streamID.rawValue, rhs.streamID.rawValue)
            && lhs.subjectID == rhs.subjectID
            && lhs.locationID == rhs.locationID
            && lhs.bucket == rhs.bucket
            && lhs.bucketStart == rhs.bucketStart
    }

    public func hash(into hasher: inout Hasher) {
        hashBinary(scopeID.rawValue, into: &hasher)
        hashBinary(streamID.rawValue, into: &hasher)
        hasher.combine(subjectID)
        hasher.combine(locationID)
        hasher.combine(bucket.rawValue)
        hasher.combine(bucketStart)
    }

    private static func isBoundedOpaqueKey(_ value: String) -> Bool {
        value.utf8.count <= 4_096 && value.utf8.contains(0) == false
    }
}

public struct ReconciliationRevisionReference: Sendable, Equatable, Hashable {
    public let id: ReconciliationRevisionID
    public let sequence: ReconciliationRevisionSequence
    public let key: ReconciliationRevisionKey

    public init(
        id: ReconciliationRevisionID,
        sequence: ReconciliationRevisionSequence,
        key: ReconciliationRevisionKey
    ) {
        self.id = id
        self.sequence = sequence
        self.key = key
    }
}

/// One immutable complete-scan revision of a provisional directory-history
/// slot. A caller supplies the stored predecessor reference so construction
/// cannot silently cross a bucket or rely on wall-clock order.
public struct ReconciliationRevision: Sendable, Equatable {
    public let id: ReconciliationRevisionID
    public let sequence: ReconciliationRevisionSequence
    public let key: ReconciliationRevisionKey
    public let predecessorID: ReconciliationRevisionID?
    public let scanRunID: CalibrationRunID
    public let dirtyRevision: DirtyRegionRevision
    public let observedAt: ObservationInstant
    public let logicalBytes: ByteCount
    public let allocatedBytes: ByteCount
    public let descendantCount: Int64
    public let payloadDigest: ReconciliationRevisionDigest

    public var reference: ReconciliationRevisionReference {
        ReconciliationRevisionReference(id: id, sequence: sequence, key: key)
    }

    public init(
        id: ReconciliationRevisionID,
        sequence: ReconciliationRevisionSequence,
        key: ReconciliationRevisionKey,
        predecessor: ReconciliationRevisionReference?,
        scanRunID: CalibrationRunID,
        dirtyRevision: DirtyRegionRevision,
        observedAt: ObservationInstant,
        logicalBytes: ByteCount,
        allocatedBytes: ByteCount,
        descendantCount: Int64,
        payloadDigest: ReconciliationRevisionDigest
    ) throws(ReconciliationRevisionModelError) {
        guard descendantCount >= 0 else {
            throw .invalidDescendantCount(descendantCount)
        }
        if let predecessor {
            guard predecessor.id != id else { throw .predecessorRecordReused }
            guard predecessor.key == key else { throw .predecessorKeyMismatch }
            guard predecessor.sequence < sequence else { throw .nonIncreasingSequence }
        }

        self.id = id
        self.sequence = sequence
        self.key = key
        predecessorID = predecessor?.id
        self.scanRunID = scanRunID
        self.dirtyRevision = dirtyRevision
        self.observedAt = observedAt
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
        self.descendantCount = descendantCount
        self.payloadDigest = payloadDigest
    }
}

public enum ReconciliationRevisionModelError: Error, Sendable, Equatable {
    case invalidRecordID(Int64)
    case invalidSequence(Int64)
    case invalidDigestLength(Int)
    case misalignedBucketStart
    case invalidOpaqueIdentity
    case invalidDescendantCount(Int64)
    case predecessorRecordReused
    case predecessorKeyMismatch
    case nonIncreasingSequence
}

private func reconciliationRevisionBinaryEqual(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.elementsEqual(rhs.utf8)
}

private func hashBinary(_ value: String, into hasher: inout Hasher) {
    hasher.combine(value.utf8.count)
    for byte in value.utf8 {
        hasher.combine(byte)
    }
}
