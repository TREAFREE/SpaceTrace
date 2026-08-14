import Testing
import SpaceTraceDomain
@testable import SpaceTraceApplication

struct CalibrationScanModelTests {
    @Test("Scan budgets reject every unbounded or non-progressing limit")
    func rejectsInvalidBudgets() {
        #expect(throws: CalibrationScanModelError.invalidMaximumEntries) {
            try CalibrationScanBudget(
                maximumEntries: 0,
                maximumDepth: 1,
                maximumDurationMilliseconds: 1,
                stageBatchSize: 1,
                yieldEveryEntries: 1
            )
        }
        #expect(throws: CalibrationScanModelError.invalidMaximumDepth) {
            try CalibrationScanBudget(
                maximumEntries: 1,
                maximumDepth: -1,
                maximumDurationMilliseconds: 1,
                stageBatchSize: 1,
                yieldEveryEntries: 1
            )
        }
        #expect(throws: CalibrationScanModelError.invalidMaximumDuration) {
            try CalibrationScanBudget(
                maximumEntries: 1,
                maximumDepth: 1,
                maximumDurationMilliseconds: 0,
                stageBatchSize: 1,
                yieldEveryEntries: 1
            )
        }
        #expect(throws: CalibrationScanModelError.invalidStageBatchSize) {
            try CalibrationScanBudget(
                maximumEntries: 1,
                maximumDepth: 1,
                maximumDurationMilliseconds: 1,
                stageBatchSize: 0,
                yieldEveryEntries: 1
            )
        }
        #expect(throws: CalibrationScanModelError.invalidYieldInterval) {
            try CalibrationScanBudget(
                maximumEntries: 1,
                maximumDepth: 1,
                maximumDurationMilliseconds: 1,
                stageBatchSize: 1,
                yieldEveryEntries: 0
            )
        }
    }

    @Test("Complete aggregate truth requires both byte metrics")
    func completeAggregateRequiresMetrics() throws {
        let path = try DirtyRegionPath("/fixture")

        #expect(throws: CalibrationScanModelError.completeAggregateRequiresBothMetrics) {
            try DirectoryMetadataAggregate(
                path: path,
                logicalBytes: nil,
                allocatedBytes: .zero,
                descendantCount: 0,
                coverage: .complete
            )
        }
        #expect(throws: CalibrationScanModelError.negativeDescendantCount(-1)) {
            try DirectoryMetadataAggregate(
                path: path,
                logicalBytes: .zero,
                allocatedBytes: .zero,
                descendantCount: -1,
                coverage: .partial
            )
        }
    }

    @Test("A complete report must describe staged, gap-free directory truth")
    func completeReportRequiresEvidence() throws {
        let gap = CalibrationGap(
            path: try DirtyRegionPath("/fixture"),
            reason: .metadataUnavailable
        )

        #expect(throws: CalibrationScanModelError.completeReportRequiresStagedDirectory) {
            try CalibrationReport(
                coverage: .complete,
                entriesVisited: 1,
                directoriesStaged: 0,
                gaps: []
            )
        }
        #expect(throws: CalibrationScanModelError.completeReportCannotContainGaps) {
            try CalibrationReport(
                coverage: .complete,
                entriesVisited: 1,
                directoriesStaged: 1,
                gaps: [gap]
            )
        }
    }
}
