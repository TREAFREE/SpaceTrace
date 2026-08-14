import Foundation
import SpaceTraceApplication
import SpaceTraceDomain

/// Reads the volume that contains the injected data-directory URL. Using the
/// Application Support directory keeps the sample on the startup data volume
/// without assuming a hard-coded mount path on APFS volume groups.
public struct FoundationStartupVolumeCapacityProvider: StartupVolumeCapacitySnapshotProviding {
    private let dataDirectoryURL: URL
    private let now: @Sendable () -> Date

    public init(
        dataDirectoryURL: URL,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.dataDirectoryURL = dataDirectoryURL
        self.now = now
    }

    public func snapshot() async -> StartupVolumeCapacitySnapshot {
        let values = try? dataDirectoryURL.resourceValues(forKeys: [
            .volumeUUIDStringKey,
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ])

        return StartupVolumeCapacitySnapshot(
            observedAt: now(),
            volumeUUID: values?.volumeUUIDString.flatMap(UUID.init(uuidString:)),
            totalBytes: byteCount(values?.volumeTotalCapacity),
            availableBytes: byteCount(values?.volumeAvailableCapacity),
            availableForImportantUsageBytes: byteCount(
                values?.volumeAvailableCapacityForImportantUsage
            )
        )
    }

    private func byteCount(_ value: Int?) -> ByteCount? {
        guard let value, value >= 0 else { return nil }
        return try? ByteCount(Int64(value))
    }

    private func byteCount(_ value: Int64?) -> ByteCount? {
        guard let value, value >= 0 else { return nil }
        return try? ByteCount(value)
    }
}
