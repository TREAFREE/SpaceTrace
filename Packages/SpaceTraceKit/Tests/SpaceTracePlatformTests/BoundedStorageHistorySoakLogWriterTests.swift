import Foundation
import SpaceTraceApplication
import Testing
@testable import SpaceTracePlatform

struct BoundedStorageHistorySoakLogWriterTests {
    @Test("Native probe reports process resources and only aggregate database size")
    func probesAggregateResources() throws {
        let fixture = try TemporaryDirectory()
        let database = fixture.url.appendingPathComponent("SpaceTrace.sqlite")
        try Data(repeating: 1, count: 10).write(to: database)
        try Data(repeating: 2, count: 20).write(
            to: URL(fileURLWithPath: database.path + "-wal")
        )
        try Data(repeating: 3, count: 30).write(
            to: URL(fileURLWithPath: database.path + "-shm")
        )

        let measurement = try NativeStorageHistoryResourceSnapshotProvider(
            databaseURL: database
        ).snapshot()

        #expect(measurement.continuousTimeMilliseconds > 0)
        #expect(measurement.resource.cumulativeCPUMilliseconds >= 0)
        #expect(measurement.resource.residentMemoryBytes > 0)
        #expect(measurement.resource.databaseBytes == 60)
    }

    @Test("Writer rotates within its byte budget and protects created files")
    func rotatesAndProtectsFiles() async throws {
        let fixture = try TemporaryDirectory()
        let writer = try BoundedStorageHistorySoakLogWriter(
            directoryURL: fixture.url,
            maximumTotalBytes: 4_096,
            retentionDuration: 7 * 86_400,
            fileManager: .default
        )

        for index in 0..<80 {
            try await writer.append(record(sequence: Int64(index + 1)))
        }

        let files = try FileManager.default.contentsOfDirectory(
            at: fixture.url,
            includingPropertiesForKeys: [.fileSizeKey]
        )
        let total = try files.reduce(Int64.zero) { partial, url in
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            return partial + Int64(size ?? 0)
        }
        let directoryMode = try permissions(at: fixture.url)

        #expect(files.count <= 2)
        #expect(total <= 4_096)
        #expect(directoryMode == 0o700)
        for file in files {
            #expect(try permissions(at: file) == 0o600)
        }
    }

    @Test("Expired segments are removed before a new append")
    func removesExpiredSegments() async throws {
        let fixture = try TemporaryDirectory()
        let expired = fixture.url.appendingPathComponent("expired.jsonl")
        try Data("old".utf8).write(to: expired)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1)],
            ofItemAtPath: expired.path
        )
        let writer = try BoundedStorageHistorySoakLogWriter(
            directoryURL: fixture.url,
            maximumTotalBytes: 4_096,
            retentionDuration: 60,
            fileManager: .default,
            now: { Date(timeIntervalSince1970: 10_000) }
        )

        try await writer.append(record(sequence: 1))

        #expect(FileManager.default.fileExists(atPath: expired.path) == false)
    }
}

private func record(sequence: Int64) -> StorageHistorySoakDiagnosticRecord {
    StorageHistorySoakDiagnosticRecord(
        sessionID: UUID(
            uuid: (
                0x77, 0x72, 0x69, 0x74,
                0x00, 0x00,
                0x40, 0x00,
                0x80, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x01
            )
        ),
        recordedAtMilliseconds: sequence,
        continuousTimeMilliseconds: sequence,
        reason: .heartbeat,
        background: .stopped,
        resource: StorageHistorySoakResourceSnapshot(
            cumulativeCPUMilliseconds: sequence,
            residentMemoryBytes: 1,
            databaseBytes: 1
        ),
        capacity: StorageHistorySoakCapacitySnapshot(
            sequence: sequence,
            qualification: .collecting
        )
    )
}

private func permissions(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(
        atPath: url.path
    )
    return try #require(attributes[.posixPermissions] as? Int)
}

private struct TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
    }
}
