import AppKit
import SpaceTraceApplication
import SpaceTraceDomain
import SpaceTraceMonitoring
import SpaceTracePersistence
import SpaceTracePlatform

@MainActor
final class SpaceTraceAppDelegate: NSObject, NSApplicationDelegate {
    let authorizationModel = DirectoryAuthorizationViewModel()
    let baselineScanModel = BaselineScanViewModel()
    let directoryHistoryModel = DirectoryHistoryViewModel()
    let historicalFindingsModel = HistoricalFindingsViewModel()
    let diagnosticExportModel = DiagnosticExportViewModel()
    let databaseRecoveryModel = DatabaseRecoveryViewModel()
    let menuBarStatusModel = MenuBarStatusViewModel()

    private var compositionRoot: SpaceTraceCompositionRoot?
    private var recoverySession: SQLiteReadOnlyRecoverySession?
    private var startupTask: Task<Void, Never>?
    private var storageHistoryStartupTask: Task<Void, Never>?
    private var storageHistoryObservationTask: Task<Void, Never>?
    private var storageHistorySoakTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = notification
#if DEBUG
        if authorizationModel.loadUITestScenarioIfConfigured() {
            directoryHistoryModel.connect(UITestStorageHistoryLoader())
            historicalFindingsModel.connect(UITestHistoricalFindingOverviewService())
            historicalFindingsModel.connectReconciliationStatus(
                UITestReconciliationStatusLoader()
            )
            menuBarStatusModel.loadUITestFixture()
            if let writer = try? AtomicDiagnosticExportWriter(
                stagingDirectoryURL: FileManager.default.temporaryDirectory
                    .appendingPathComponent("SpaceTrace-UI-Export", isDirectory: true)
            ) {
                diagnosticExportModel.connect(writer)
            }
            return
        }
#endif
        do {
            let diagnosticsRequested = ProcessInfo.processInfo.environment[
                "SPACETRACE_BACKGROUND_SOAK_DIAGNOSTICS"
            ] == "1"
            switch try SpaceTraceCompositionRoot.bootstrap(
                enableSoakDiagnostics: diagnosticsRequested
            ) {
            case let .operational(compositionRoot):
                self.compositionRoot = compositionRoot
                authorizationModel.connect(compositionRoot.authorizationCoordinator)
                baselineScanModel.connect(compositionRoot.baselineScanCoordinator)
                directoryHistoryModel.connect(compositionRoot.storageHistoryQuery)
                historicalFindingsModel.connect(
                    compositionRoot.historicalFindingOverviewQuery
                )
                historicalFindingsModel.connectReconciliationStatus(
                    compositionRoot.reconciliationStatusQuery
                )
                diagnosticExportModel.connect(
                    compositionRoot.diagnosticExportWriter
                )
                menuBarStatusModel.connect(
                    compositionRoot.startupVolume24HourStatusQuery
                )
                menuBarStatusModel.setQualificationDiagnosticsActive(
                    compositionRoot.storageHistorySoakRecorder != nil
                )
                startupTask = Task { [weak self] in
                    await self?.diagnosticExportModel.recoverInterruptedExports()
                    await self?.authorizationModel.start()
                }
                storageHistoryObservationTask = Task { [weak self] in
                    await self?.menuBarStatusModel.monitor(
                        background:
                            compositionRoot.storageHistoryBackgroundCoordinator
                    )
                }
                storageHistoryStartupTask = Task {
                    await compositionRoot.storageHistoryBackgroundCoordinator
                        .start()
                    guard Task.isCancelled == false else { return }
                    compositionRoot.storageHistoryLifecycleMonitor.start()
                }
                if let recorder =
                    compositionRoot.storageHistorySoakRecorder {
                    storageHistorySoakTask = Task {
                        await recorder.run()
                    }
                }
            case let .recovery(session):
                recoverySession = session
                databaseRecoveryModel.activate(session.overview)
                authorizationModel.handleCompositionFailure()
                baselineScanModel.handleCompositionFailure()
                directoryHistoryModel.handleCompositionFailure()
                historicalFindingsModel.handleCompositionFailure()
                menuBarStatusModel.handleCompositionFailure()
            }
        } catch {
            authorizationModel.handleCompositionFailure()
            baselineScanModel.handleCompositionFailure()
            directoryHistoryModel.handleCompositionFailure()
            historicalFindingsModel.handleCompositionFailure()
            menuBarStatusModel.handleCompositionFailure()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        _ = notification
        Task { [weak self] in
            await self?.authorizationModel.refreshIfNeeded()
            await self?.menuBarStatusModel.refresh()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        _ = sender
        guard let compositionRoot else {
            recoverySession?.close()
            return .terminateNow
        }
        guard shutdownTask == nil else {
            return .terminateLater
        }

        startupTask?.cancel()
        storageHistoryStartupTask?.cancel()
        storageHistoryObservationTask?.cancel()
        storageHistorySoakTask?.cancel()
        compositionRoot.storageHistoryLifecycleMonitor.stop()
        compositionRoot.scanSchedulingMonitor.stop()
        let authorizationCoordinator = compositionRoot.authorizationCoordinator
        let baselineScanCoordinator = compositionRoot.baselineScanCoordinator
        let storageHistoryBackgroundCoordinator =
            compositionRoot.storageHistoryBackgroundCoordinator
        let storageHistorySoakTask = storageHistorySoakTask
        shutdownTask = Task { @concurrent in
            await baselineScanCoordinator.cancel()
            await storageHistoryBackgroundCoordinator.stop()
            await storageHistorySoakTask?.value
            await authorizationCoordinator.stop()
            await MainActor.run {
                NSApplication.shared.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }
}

#if DEBUG
private struct UITestStorageHistoryLoader: StorageHistoryOverviewLoading {
    nonisolated func loadOverview(
        contexts: [AuthorizedBaselineScanContext],
        window: DirectoryHistoryWindow,
        through end: Date,
        growthLimit: Int
    ) throws -> StorageHistoryOverview {
        _ = contexts
        _ = growthLimit
        let start = end.addingTimeInterval(-window.duration)
        let volumeUUID = UUID(
            uuidString: "88888888-8888-8888-8888-888888888888"
        )
        let startingAvailable = try ByteCount(100 * 1_073_741_824)
        let endingAvailable = try ByteCount(98 * 1_073_741_824)
        let points = [
            StartupVolumeHistoryPoint(
                bucketStart: start,
                sampledAt: start,
                sequence: 1,
                volumeUUID: volumeUUID,
                totalBytes: try ByteCount(256 * 1_073_741_824),
                availableBytes: startingAvailable,
                availableForImportantUsageBytes: nil,
                coverage: .complete
            ),
            StartupVolumeHistoryPoint(
                bucketStart: end,
                sampledAt: end,
                sequence: 2,
                volumeUUID: volumeUUID,
                totalBytes: try ByteCount(256 * 1_073_741_824),
                availableBytes: endingAvailable,
                availableForImportantUsageBytes: nil,
                coverage: .partial
            ),
        ]
        let directories = DirectoryHistoryOverview(
            window: window,
            start: start,
            end: end,
            bucket: window.bucket,
            series: [],
            growthSources: [],
            coverage: .unavailable
        )
        return StorageHistoryOverview(
            window: window,
            start: start,
            end: end,
            bucket: window.bucket,
            volume: StartupVolumeHistorySeries(
                points: points,
                coverage: .partial,
                identityDiscontinuity: false
            ),
            directories: directories,
            reconciliation: StorageReconciliationSummary(
                firstObservedAt: start,
                lastObservedAt: end,
                startingAvailableBytes: startingAvailable,
                endingAvailableBytes: endingAvailable,
                diskSpaceLoss: try ByteCount(2 * 1_073_741_824),
                observedDirectoryAllocatedGrowth: nil,
                explainedDiskSpaceLoss: nil,
                unattributedDiskSpaceLoss: nil,
                comparableScopeCount: 0,
                excludedNestedScopeCount: 0,
                excludedExternalScopeCount: 0,
                unknownVolumeScopeCount: 0,
                coverage: .partial
            )
        )
    }
}

private struct UITestHistoricalFindingOverviewService:
    HistoricalFindingOverviewServing
{
    nonisolated func loadFindingOverview(
        scopeIDs: [WatchedScopeID],
        currentLimit: Int,
        auditLimit: Int
    ) throws -> HistoricalFindingOverview {
        _ = currentLimit
        _ = auditLimit
        let scenario = ProcessInfo.processInfo.environment[
            "SPACETRACE_UI_TEST_SCENARIO"
        ]
        let availability: HistoricalPathHistoryAvailability
        let retentionDays: Int
        switch scenario {
        case "history-disabled":
            availability = .historyDisabled
            retentionDays = 0
        case "baseline-unavailable":
            availability = .baselineUnavailable
            retentionDays = 30
        default:
            availability = .available
            retentionDays = 30
        }

        let current: [HistoricalFindingOverviewItem]
        let invalidated: [HistoricalFindingOverviewItem]
        if availability == .available {
            current = [
                try Self.item(
                    id: 1,
                    kind: .growth,
                    delta: 1_073_741_824,
                    baselinePath: "/Volumes/SpaceTraceFixture/Selected/Cache",
                    comparisonPath: "/Volumes/SpaceTraceFixture/Selected/Cache",
                    baselineName: "Cache",
                    comparisonName: "Cache",
                    rank: 1,
                    validity: .currentEffective
                ),
                try Self.item(
                    id: 2,
                    kind: .move,
                    delta: 0,
                    baselinePath: "/Volumes/SpaceTraceFixture/Selected/Before",
                    comparisonPath: "/Volumes/SpaceTraceFixture/Selected/After",
                    baselineName: "Before",
                    comparisonName: "After",
                    rank: nil,
                    validity: .currentEffective
                ),
                try Self.item(
                    id: 3,
                    kind: .disappearance,
                    delta: -536_870_912,
                    baselinePath: "/Volumes/SpaceTraceFixture/Selected/Old",
                    comparisonPath: "/Volumes/SpaceTraceFixture/Selected/Old",
                    baselineName: "Old",
                    comparisonName: "Old",
                    rank: nil,
                    validity: .currentEffective
                ),
            ]
            invalidated = [
                try Self.item(
                    id: 4,
                    kind: .growth,
                    delta: 268_435_456,
                    baselinePath: "/Volumes/SpaceTraceFixture/Selected/Invalidated",
                    comparisonPath: "/Volumes/SpaceTraceFixture/Selected/Invalidated",
                    baselineName: "Invalidated",
                    comparisonName: "Invalidated",
                    rank: 2,
                    validity: .evidenceInvalidated(
                        at: ObservationInstant(millisecondsSince1970: 1_800_000_100_000)
                    )
                ),
            ]
        } else {
            current = []
            invalidated = []
        }

        return try HistoricalFindingOverview(
            retentionDays: retentionDays,
            scopes: try scopeIDs.map {
                try HistoricalFindingScopeOverview(
                    scopeID: $0,
                    availability: availability,
                    currentFindings: current,
                    invalidatedFindings: invalidated
                )
            }
        )
    }

    nonisolated func setHistoryEnabled(_ enabled: Bool) {
        _ = enabled
    }

    private static func item(
        id: Int64,
        kind: HistoricalFindingKind,
        delta: Int64,
        baselinePath: String,
        comparisonPath: String,
        baselineName: String,
        comparisonName: String,
        rank: Int?,
        validity: HistoricalFindingOverviewItemValidity
    ) throws -> HistoricalFindingOverviewItem {
        try HistoricalFindingOverviewItem(
            id: HistoricalFindingRecordID(id),
            kind: kind,
            metric: .logical,
            inclusiveDeltaBytes: delta,
            rankingContributionBytes: rank == nil ? nil : delta,
            positiveRank: rank,
            baselinePath: baselinePath,
            comparisonPath: comparisonPath,
            baselineDisplayName: baselineName,
            comparisonDisplayName: comparisonName,
            baselineTime: ObservationInstant(
                millisecondsSince1970: 1_799_996_400_000 + id
            ),
            comparisonTime: ObservationInstant(
                millisecondsSince1970: 1_800_000_000_000 + id
            ),
            classification: id == 1
                ? .classified(
                    category: .logsAndCaches,
                    confidence: .high,
                    ruleID: AttributionRuleID("logs.fixture"),
                    ruleVersion: AttributionRuleVersion(1),
                    catalogVersion: AttributionCatalogVersion(1),
                    evidenceCode: AttributionEvidenceCode("fixture.logs")
                )
                : .unknownNoMatchingRule(
                    catalogVersion: AttributionCatalogVersion(1)
                ),
            validity: validity
        )
    }
}

private struct UITestReconciliationStatusLoader: ReconciliationStatusLoading {
    nonisolated func load(
        scopeID: WatchedScopeID,
        readiness: ReconciliationScopeReadiness
    ) throws -> ReconciliationStatus {
        let scenario = ProcessInfo.processInfo.environment[
            "SPACETRACE_UI_TEST_SCENARIO"
        ]
        let success = ReconciliationSuccess(
            scopeID: scopeID,
            sequence: try ReconciliationRevisionSequence(8),
            completedAt: try ObservationInstant(
                millisecondsSince1970: 1_800_000_000_000
            )
        )
        let state: ReconciliationStatusState
        if scenario == "history-disabled" {
            state = .historyDisabled
        } else if scenario == "baseline-unavailable" {
            state = .baselineUnavailable
        } else {
            switch readiness {
            case .ready:
                state = .current(success)
            case .permissionRequired:
                state = .permissionRequired(lastSuccess: success)
            case .volumeUnavailable:
                state = .volumeUnavailable(lastSuccess: success)
            }
        }
        return try ReconciliationStatus(scopeID: scopeID, state: state)
    }
}
#endif
