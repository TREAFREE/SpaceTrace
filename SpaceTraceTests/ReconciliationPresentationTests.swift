import SpaceTraceApplication
import SpaceTraceDomain
import Testing
@testable import SpaceTrace

@Suite("Reconciliation status presentation")
@MainActor
struct ReconciliationPresentationTests {
    @Test("Every durable and lifecycle state has text, an icon, and a non-color semantic tone")
    func presentsEveryStateWithoutColorOnlyMeaning() throws {
        let scopeID = try WatchedScopeID("scope-presentation")
        let instant = try ObservationInstant(millisecondsSince1970: 1_800_000_000_000)
        let success = ReconciliationSuccess(
            scopeID: scopeID,
            sequence: try ReconciliationRevisionSequence(8),
            completedAt: instant
        )
        let revision = try DirtyRegionRevision(9)
        let states: [ReconciliationStatusState] = [
            .current(success),
            .pending(lastSuccess: success, oldestPendingRevision: revision, pendingSince: instant),
            .pending(lastSuccess: success, oldestPendingRevision: nil, pendingSince: nil),
            .partial(lastSuccess: success, attemptedRevision: revision, attemptedAt: instant),
            .failed(lastSuccess: success, attemptedRevision: revision, attemptedAt: instant),
            .permissionRequired(lastSuccess: success),
            .volumeUnavailable(lastSuccess: success),
            .historyDisabled,
            .baselineUnavailable,
        ]

        let presentations = states.map(ReconciliationStatusPresentation.init)

        #expect(presentations.allSatisfy { $0.detail.isEmpty == false })
        #expect(presentations.allSatisfy { $0.symbolName.isEmpty == false })
        #expect(presentations.map(\.tone) == [
            .success,
            .attention,
            .attention,
            .attention,
            .failure,
            .attention,
            .attention,
            .neutral,
            .neutral,
        ])
        #expect(presentations[0].detail.contains("修订 8"))
        #expect(presentations[1].detail.contains("dirty revision 9"))
        #expect(presentations[2].detail.contains("路径已按隐私保留策略移除"))
        #expect(presentations[5].detail.contains("重新授权"))
        #expect(presentations[6].detail.contains("卷当前不可用"))
    }
}
