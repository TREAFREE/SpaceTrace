import Foundation
import Observation
import SpaceTraceApplication
import struct SpaceTraceDomain.ObservationInstant

enum DiagnosticExportViewState: Equatable {
    case unavailable
    case ready
    case saving
    case saved(fileName: String)
    case failed
}

struct DiagnosticExportFindingSelection: Identifiable, Equatable {
    let id: HistoricalFindingRecordID
    let title: String
    let kind: HistoricalFindingKind
    let isSelected: Bool
}

@MainActor
protocol DiagnosticExportDestinationSelecting: AnyObject {
    func selectDestination(suggestedFileName: String) async -> URL?
    func cancel()
}

@MainActor
@Observable
final class DiagnosticExportViewModel {
    @ObservationIgnored
    private var writer: (any DiagnosticExportWriting)?
    @ObservationIgnored
    private let destinationSelector: any DiagnosticExportDestinationSelecting
    @ObservationIgnored
    private let makeExportID: () -> UUID
    @ObservationIgnored
    private let homeDirectory: String?
    @ObservationIgnored
    private var source: DiagnosticExportSource?
    @ObservationIgnored
    private var selectedIDs: Set<HistoricalFindingRecordID> = []
    @ObservationIgnored
    private var rawPathAuthorization: DiagnosticRawPathAuthorization?
    @ObservationIgnored
    private var exportID: UUID
    @ObservationIgnored
    private var operation: Task<Void, Never>?

    private(set) var state: DiagnosticExportViewState = .unavailable
    private(set) var preview: DiagnosticExportPreview?
    private(set) var requiresRawPathConfirmation = false
    private(set) var recoveryIssue = false

    init(
        writer: (any DiagnosticExportWriting)? = nil,
        destinationSelector: (any DiagnosticExportDestinationSelecting)? = nil,
        exportID: @escaping () -> UUID = { UUID() },
        homeDirectory: String? = NSHomeDirectory()
    ) {
        self.writer = writer
        self.destinationSelector = destinationSelector
            ?? SystemDiagnosticExportDestinationSelector()
        makeExportID = exportID
        self.homeDirectory = homeDirectory
        self.exportID = exportID()
    }

    var findingSelections: [DiagnosticExportFindingSelection] {
        guard let source else { return [] }
        return source.scopes
            .flatMap(\.findings)
            .sorted { $0.id < $1.id }
            .map { item in
                DiagnosticExportFindingSelection(
                    id: item.id,
                    title: item.comparisonDisplayName,
                    kind: item.kind,
                    isSelected: selectedIDs.contains(item.id)
                )
            }
    }

    var selectedFindingCount: Int { selectedIDs.count }

    func connect(_ writer: any DiagnosticExportWriting) {
        self.writer = writer
        rebuildPreview()
    }

    func configure(source: DiagnosticExportSource?) {
        guard let source else {
            self.source = nil
            selectedIDs = []
            preview = nil
            state = .unavailable
            return
        }
        self.source = source
        selectedIDs = Set(
            source.scopes
                .flatMap(\.findings)
                .sorted { $0.id < $1.id }
                .prefix(DiagnosticExportBuilder.maximumSelectedFindingCount)
                .map(\.id)
        )
        rawPathAuthorization = nil
        requiresRawPathConfirmation = false
        state = writer == nil ? .unavailable : .ready
        rebuildPreview()
    }

    func toggleFinding(_ id: HistoricalFindingRecordID) {
        guard state != .saving else { return }
        if selectedIDs.remove(id) == nil {
            guard selectedIDs.count
                    < DiagnosticExportBuilder.maximumSelectedFindingCount else {
                return
            }
            selectedIDs.insert(id)
        }
        rebuildPreview()
    }

    func requestFullPaths() {
        guard state != .saving else { return }
        requiresRawPathConfirmation = true
    }

    func confirmFullPaths() {
        guard state != .saving else { return }
        rawPathAuthorization = .confirmed(for: exportID)
        requiresRawPathConfirmation = false
        rebuildPreview()
    }

    func useRedactedPaths() {
        guard state != .saving else { return }
        rawPathAuthorization = nil
        requiresRawPathConfirmation = false
        rebuildPreview()
    }

    func dismissRawPathConfirmation() {
        requiresRawPathConfirmation = false
    }

    func beginExport() {
        guard state != .saving,
              source != nil,
              writer != nil,
              preview != nil else { return }
        state = .saving
        operation = Task { [weak self] in
            await self?.performExport()
        }
    }

    func cancelExport() {
        guard state == .saving else { return }
        destinationSelector.cancel()
        operation?.cancel()
    }

    func waitForCurrentOperation() async {
        await operation?.value
    }

    func recoverInterruptedExports() async {
        guard let writer else { return }
        do {
            _ = try await writer.recoverInterruptedExports()
            recoveryIssue = false
        } catch {
            recoveryIssue = true
        }
    }

    private func performExport() async {
        guard let writer, let source else {
            state = .unavailable
            return
        }
        do {
            let prepared = try DiagnosticExportBuilder().prepare(
                source: source,
                exportID: exportID,
                selectedFindingIDs: selectedIDs.sorted(),
                pathMode: pathMode
            )
            try Task.checkCancellation()
            guard let destination = await destinationSelector
                .selectDestination(suggestedFileName: prepared.suggestedFileName) else {
                startNewExportCycle()
                state = .ready
                return
            }
            try Task.checkCancellation()
            _ = try await writer.write(prepared, to: destination)
            let fileName = destination.lastPathComponent
            startNewExportCycle()
            state = .saved(fileName: fileName)
        } catch is CancellationError {
            startNewExportCycle()
            state = .ready
        } catch {
            startNewExportCycle()
            state = .failed
        }
    }

    private var pathMode: DiagnosticExportPathMode {
        if let rawPathAuthorization {
            return .fullPaths(authorization: rawPathAuthorization)
        }
        return .redacted(homeDirectory: homeDirectory)
    }

    private func startNewExportCycle() {
        exportID = makeExportID()
        rawPathAuthorization = nil
        requiresRawPathConfirmation = false
        rebuildPreview()
    }

    private func rebuildPreview() {
        guard let source, writer != nil else {
            preview = nil
            if state != .saving { state = .unavailable }
            return
        }
        do {
            preview = try DiagnosticExportBuilder().preview(
                source: source,
                exportID: exportID,
                selectedFindingIDs: selectedIDs.sorted(),
                pathMode: pathMode
            )
            if state == .unavailable || state == .failed {
                state = .ready
            }
        } catch {
            preview = nil
            if state != .saving { state = .failed }
        }
    }
}

enum DiagnosticExportSourceFactory {
    @MainActor
    static func make(
        from model: HistoricalFindingsViewModel,
        bundle: Bundle = .main,
        processInfo: ProcessInfo = .processInfo,
        now: Date = Date()
    ) throws -> DiagnosticExportSource? {
        guard let overview = model.overview else { return nil }
        let scopes = try overview.scopes.map { scope in
            guard let path = model.displayPath(for: scope.scopeID) else {
                throw DiagnosticExportError.invalidPath
            }
            return try DiagnosticExportScopeSource(
                scopeID: scope.scopeID,
                rootPath: path,
                availability: scope.availability,
                findings: scope.currentFindings + scope.invalidatedFindings
            )
        }
        var events: [DiagnosticExportHealthEvent] = []
        let timestamp = try ObservationInstant(
            millisecondsSince1970: Int64(now.timeIntervalSince1970 * 1_000)
        )
        let disabled = scopes.filter { $0.availability == .historyDisabled }.count
        let unavailable = scopes.filter { $0.availability == .baselineUnavailable }.count
        let invalidated = overview.invalidatedFindings.count
        if disabled > 0 {
            events.append(try DiagnosticExportHealthEvent(
                code: "history_disabled",
                severity: .notice,
                observedAt: timestamp,
                count: disabled
            ))
        }
        if unavailable > 0 {
            events.append(try DiagnosticExportHealthEvent(
                code: "baseline_unavailable",
                severity: .warning,
                observedAt: timestamp,
                count: unavailable
            ))
        }
        if invalidated > 0 {
            events.append(try DiagnosticExportHealthEvent(
                code: "finding_evidence_invalidated",
                severity: .warning,
                observedAt: timestamp,
                count: invalidated
            ))
        }
        return try DiagnosticExportSource(
            generatedAt: timestamp,
            appVersion: appVersion(bundle: bundle),
            osVersion: processInfo.operatingSystemVersionString,
            architecture: architecture,
            scopes: scopes,
            healthEvents: events
        )
    }

    private static func appVersion(bundle: Bundle) -> String {
        let version = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "development"
        guard let build = bundle.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String,
              build.isEmpty == false else { return version }
        return "\(version) (\(build))"
    }

    private static var architecture: String {
#if arch(arm64)
        "arm64"
#elseif arch(x86_64)
        "x86_64"
#else
        "unknown"
#endif
    }
}
