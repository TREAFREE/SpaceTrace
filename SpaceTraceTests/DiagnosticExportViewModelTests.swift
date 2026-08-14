import Foundation
import SpaceTraceApplication
import SpaceTraceDomain
import Testing
@testable import SpaceTrace

@MainActor
struct DiagnosticExportViewModelTests {
    @Test("Configuration creates a redacted preview before any write")
    func configuresRedactedPreview() throws {
        let destination = DiagnosticExportDestinationSelectorFake(results: [])
        let writer = DiagnosticExportWriterFake()
        let model = DiagnosticExportViewModel(
            writer: writer,
            destinationSelector: destination,
            exportID: { exportID(1) }
        )

        model.configure(source: try source())

        #expect(model.state == .ready)
        #expect(model.preview?.pathMode == .redacted)
        #expect(model.preview?.sections.map(\.kind) == [
            .system, .coverage, .healthEvents, .selectedFindings,
        ])
        #expect(model.requiresRawPathConfirmation == false)
    }

    @Test("Full paths remain disabled until this export receives confirmation")
    func rawPathsRequireConfirmation() throws {
        let model = DiagnosticExportViewModel(
            writer: DiagnosticExportWriterFake(),
            destinationSelector: DiagnosticExportDestinationSelectorFake(results: []),
            exportID: { exportID(2) }
        )
        model.configure(source: try source())

        model.requestFullPaths()
        #expect(model.requiresRawPathConfirmation)
        #expect(model.preview?.pathMode == .redacted)

        model.confirmFullPaths()
        #expect(model.requiresRawPathConfirmation == false)
        #expect(model.preview?.pathMode == .fullPaths)

        model.useRedactedPaths()
        #expect(model.preview?.pathMode == .redacted)
    }

    @Test("Cancelling the save panel writes nothing and invalidates raw consent")
    func savePanelCancellationWritesNothing() async throws {
        let selector = DiagnosticExportDestinationSelectorFake(results: [nil])
        let writer = DiagnosticExportWriterFake()
        let IDs = [exportID(3), exportID(4)]
        var iterator = IDs.makeIterator()
        let model = DiagnosticExportViewModel(
            writer: writer,
            destinationSelector: selector,
            exportID: { iterator.next()! }
        )
        model.configure(source: try source())
        model.requestFullPaths()
        model.confirmFullPaths()

        model.beginExport()
        await model.waitForCurrentOperation()

        #expect(model.state == .ready)
        #expect(model.preview?.exportID == exportID(4))
        #expect(model.preview?.pathMode == .redacted)
        #expect(await writer.writeCount() == 0)
    }

    @Test("A successful write reports only the chosen filename and starts a new consent cycle")
    func writesPreparedExport() async throws {
        let fixture = try DiagnosticExportViewModelTemporaryDirectory()
        defer { fixture.remove() }
        let output = fixture.url.appendingPathComponent("Diagnostics.json")
        let selector = DiagnosticExportDestinationSelectorFake(results: [output])
        let writer = DiagnosticExportWriterFake()
        let IDs = [exportID(5), exportID(6)]
        var iterator = IDs.makeIterator()
        let model = DiagnosticExportViewModel(
            writer: writer,
            destinationSelector: selector,
            exportID: { iterator.next()! }
        )
        model.configure(source: try source())

        model.beginExport()
        await model.waitForCurrentOperation()

        #expect(model.state == .saved(fileName: "Diagnostics.json"))
        #expect(await writer.writeCount() == 1)
        #expect(await writer.lastDestination() == output)
        #expect(model.preview?.exportID == exportID(6))
        #expect(model.preview?.pathMode == .redacted)
    }

    @Test("Cancel stops an in-flight writer and restores a usable preview")
    func cancelsInFlightWrite() async throws {
        let fixture = try DiagnosticExportViewModelTemporaryDirectory()
        defer { fixture.remove() }
        let output = fixture.url.appendingPathComponent("Diagnostics.json")
        let selector = DiagnosticExportDestinationSelectorFake(results: [output])
        let writer = DiagnosticExportWriterFake(suspends: true)
        let model = DiagnosticExportViewModel(
            writer: writer,
            destinationSelector: selector,
            exportID: { UUID() }
        )
        model.configure(source: try source())

        model.beginExport()
        await writer.waitUntilWriteStarts()
        model.cancelExport()
        await model.waitForCurrentOperation()

        #expect(model.state == .ready)
        #expect(selector.cancelCount == 1)
        #expect(await writer.completedWriteCount() == 0)
    }
}

@MainActor
private final class DiagnosticExportDestinationSelectorFake:
    DiagnosticExportDestinationSelecting
{
    private var results: [URL?]
    private(set) var cancelCount = 0

    init(results: [URL?]) {
        self.results = results
    }

    func selectDestination(suggestedFileName: String) async -> URL? {
        _ = suggestedFileName
        guard results.isEmpty == false else { return nil }
        return results.removeFirst()
    }

    func cancel() {
        cancelCount += 1
    }
}

private actor DiagnosticExportWriterFake: DiagnosticExportWriting {
    private let suspends: Bool
    private var started = false
    private var writes: [(PreparedDiagnosticExport, URL)] = []

    init(suspends: Bool = false) {
        self.suspends = suspends
    }

    func write(
        _ export: PreparedDiagnosticExport,
        to destinationURL: URL
    ) async throws -> DiagnosticExportWriteReceipt {
        started = true
        if suspends {
            try await Task.sleep(for: .seconds(30))
        }
        writes.append((export, destinationURL))
        return DiagnosticExportWriteReceipt(
            destinationURL: destinationURL,
            byteCount: export.data.count
        )
    }

    func recoverInterruptedExports() async throws -> Int { 0 }

    func waitUntilWriteStarts() async {
        while started == false { await Task.yield() }
    }

    func writeCount() -> Int { writes.count }
    func completedWriteCount() -> Int { writes.count }
    func lastDestination() -> URL? { writes.last?.1 }
}

private func source() throws -> DiagnosticExportSource {
    try DiagnosticExportSource(
        generatedAt: ObservationInstant(millisecondsSince1970: 1_800_000_000_000),
        appVersion: "1.0.0 (1)",
        osVersion: "macOS 15.6",
        architecture: "arm64",
        scopes: [
            try DiagnosticExportScopeSource(
                scopeID: WatchedScopeID("scope-export"),
                rootPath: "/Fixtures/Export",
                availability: .available,
                findings: []
            ),
        ],
        healthEvents: []
    )
}

private func exportID(_ suffix: UInt8) -> UUID {
    UUID(uuid: (
        0x99, 0x00, 0x00, suffix,
        0x00, 0x00,
        0x40, 0x00,
        0x80, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, suffix
    ))
}

private struct DiagnosticExportViewModelTemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SpaceTraceDiagnosticExportViewModel-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
