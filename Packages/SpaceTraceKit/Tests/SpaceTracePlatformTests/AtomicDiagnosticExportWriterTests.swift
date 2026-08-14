import Foundation
import SpaceTraceApplication
import SpaceTraceDomain
import Testing
@testable import SpaceTracePlatform

struct AtomicDiagnosticExportWriterTests {
    @Test("A completed export is exact, protected, and leaves no staging data")
    func writesExactProtectedExport() async throws {
        let fixture = try DiagnosticExportTemporaryDirectory()
        defer { fixture.remove() }
        let staging = fixture.url.appendingPathComponent("Staging", isDirectory: true)
        let destination = fixture.url.appendingPathComponent("SpaceTrace-Diagnostics.json")
        let prepared = try preparedExport()
        let writer = try AtomicDiagnosticExportWriter(stagingDirectoryURL: staging)

        let receipt = try await writer.write(prepared, to: destination)

        #expect(try Data(contentsOf: destination) == prepared.data)
        #expect(receipt.destinationURL == destination.standardizedFileURL)
        #expect(receipt.byteCount == prepared.data.count)
        #expect(try permissions(at: destination) == 0o600)
        #expect(try permissions(at: staging) == 0o700)
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    @Test("Cancellation before destination commit removes the private partial file")
    func cancellationLeavesNoArtifact() async throws {
        let fixture = try DiagnosticExportTemporaryDirectory()
        defer { fixture.remove() }
        let staging = fixture.url.appendingPathComponent("Staging", isDirectory: true)
        let destination = fixture.url.appendingPathComponent("cancelled.json")
        let prepared = try preparedExport()
        let writer = try AtomicDiagnosticExportWriter(
            stagingDirectoryURL: staging,
            beforeDestinationCommit: {
                try await Task.sleep(for: .seconds(30))
            }
        )
        let task = Task {
            try await writer.write(prepared, to: destination)
        }

        try await waitForPartialFile(in: staging)
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        #expect(FileManager.default.fileExists(atPath: destination.path) == false)
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    @Test("A failed destination write preserves an existing file and clears staging")
    func failedCommitPreservesExistingDestination() async throws {
        let fixture = try DiagnosticExportTemporaryDirectory()
        defer { fixture.remove() }
        let staging = fixture.url.appendingPathComponent("Staging", isDirectory: true)
        let destination = fixture.url.appendingPathComponent("existing.json")
        let original = Data("existing".utf8)
        try original.write(to: destination)
        let writer = try AtomicDiagnosticExportWriter(
            stagingDirectoryURL: staging,
            destinationCommit: { _, _ in
                throw CocoaError(.fileWriteNoPermission)
            }
        )

        await #expect(throws: CocoaError.self) {
            try await writer.write(try preparedExport(), to: destination)
        }
        #expect(try Data(contentsOf: destination) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    @Test("Startup recovery removes only regular writer-owned partial files")
    func recoveryIsNarrowAndIdempotent() async throws {
        let fixture = try DiagnosticExportTemporaryDirectory()
        defer { fixture.remove() }
        let staging = fixture.url.appendingPathComponent("Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let interrupted = staging.appendingPathComponent(
            "11111111-1111-4111-8111-111111111111.partial"
        )
        let unrelated = staging.appendingPathComponent("keep.txt")
        let outside = fixture.url.appendingPathComponent("outside.txt")
        let symlink = staging.appendingPathComponent(
            "22222222-2222-4222-8222-222222222222.partial"
        )
        try Data("partial".utf8).write(to: interrupted)
        try Data("keep".utf8).write(to: unrelated)
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
        let writer = try AtomicDiagnosticExportWriter(stagingDirectoryURL: staging)

        let first = try await writer.recoverInterruptedExports()
        let second = try await writer.recoverInterruptedExports()

        #expect(first == 1)
        #expect(second == 0)
        #expect(FileManager.default.fileExists(atPath: interrupted.path) == false)
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(FileManager.default.fileExists(atPath: symlink.path))
        #expect(try Data(contentsOf: outside) == Data("outside".utf8))
    }

    @Test("Writer rejects destinations inside its private staging directory")
    func rejectsStagingDestination() async throws {
        let fixture = try DiagnosticExportTemporaryDirectory()
        defer { fixture.remove() }
        let staging = fixture.url.appendingPathComponent("Staging", isDirectory: true)
        let writer = try AtomicDiagnosticExportWriter(stagingDirectoryURL: staging)
        let destination = staging.appendingPathComponent("export.json")

        await #expect(throws: AtomicDiagnosticExportWriterError.invalidDestination) {
            try await writer.write(try preparedExport(), to: destination)
        }
    }

    @Test("A broken writer-owned symlink is rejected without creating its target")
    func brokenStagingSymlinkCannotEscapePrivateDirectory() async throws {
        let fixture = try DiagnosticExportTemporaryDirectory()
        defer { fixture.remove() }
        let staging = fixture.url.appendingPathComponent("Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let outside = fixture.url.appendingPathComponent("must-not-be-created.json")
        let partial = staging.appendingPathComponent(
            "33333333-3333-4333-8333-333333333333.partial"
        )
        try FileManager.default.createSymbolicLink(
            at: partial,
            withDestinationURL: outside
        )
        let writer = try AtomicDiagnosticExportWriter(stagingDirectoryURL: staging)

        await #expect(throws: AtomicDiagnosticExportWriterError.unsafeStagingEntry) {
            try await writer.write(try preparedExport(), to: fixture.url.appendingPathComponent("export.json"))
        }
        #expect(FileManager.default.fileExists(atPath: outside.path) == false)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: partial.path).isEmpty == false)
    }

    @Test("Atomic destination replacement does not follow an existing symbolic link")
    func destinationSymlinkDoesNotOverwriteTarget() async throws {
        let fixture = try DiagnosticExportTemporaryDirectory()
        defer { fixture.remove() }
        let staging = fixture.url.appendingPathComponent("Staging", isDirectory: true)
        let outside = fixture.url.appendingPathComponent("outside.json")
        let destination = fixture.url.appendingPathComponent("export.json")
        let original = Data("outside-original".utf8)
        try original.write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: destination,
            withDestinationURL: outside
        )
        let prepared = try preparedExport()
        let writer = try AtomicDiagnosticExportWriter(stagingDirectoryURL: staging)

        _ = try await writer.write(prepared, to: destination)

        #expect(try Data(contentsOf: outside) == original)
        #expect(try Data(contentsOf: destination) == prepared.data)
        #expect(
            (try? FileManager.default.destinationOfSymbolicLink(
                atPath: destination.path
            )) == nil
        )
    }
}

private func preparedExport() throws -> PreparedDiagnosticExport {
    let source = try DiagnosticExportSource(
        generatedAt: ObservationInstant(millisecondsSince1970: 1_800_000_000_000),
        appVersion: "1.0.0 (1)",
        osVersion: "macOS 15.6",
        architecture: "arm64",
        scopes: [],
        healthEvents: []
    )
    return try DiagnosticExportBuilder().prepare(
        source: source,
        exportID: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!,
        selectedFindingIDs: [],
        pathMode: .redacted(homeDirectory: nil)
    )
}

private func waitForPartialFile(in directory: URL) async throws {
    for _ in 0..<1_000 {
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
           entries.contains(where: { $0.hasSuffix(".partial") }) {
            return
        }
        await Task.yield()
    }
    throw CocoaError(.fileReadUnknown)
}

private func permissions(at url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try #require(attributes[.posixPermissions] as? Int)
}

private struct DiagnosticExportTemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SpaceTraceDiagnosticExportTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
