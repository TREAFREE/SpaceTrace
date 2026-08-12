import SpaceTraceApplication
import SpaceTraceDomain
import Testing

struct ReconciliationStatusTests {
    @Test("Current status always carries a durable success sequence")
    func currentStatus() throws {
        let currentSuccess = try success(
            scopeID: "scope-a",
            sequence: 5,
            completedAt: 20_000
        )
        let status = try ReconciliationStatus(
            scopeID: WatchedScopeID("scope-a"),
            state: .current(currentSuccess)
        )

        #expect(status.state == .current(currentSuccess))
    }

    @Test("Pending state remains ordered by dirty revision across wall-clock rollback")
    func pendingClockRollback() throws {
        let status = try ReconciliationStatus(
            scopeID: WatchedScopeID("scope-a"),
            state: .pending(
                lastSuccess: success(scopeID: "scope-a", sequence: 5, completedAt: 20_000),
                oldestPendingRevision: DirtyRegionRevision(6),
                pendingSince: ObservationInstant(millisecondsSince1970: 10_000)
            )
        )

        guard case let .pending(lastSuccess, revision, pendingSince) = status.state else {
            Issue.record("Expected pending state")
            return
        }
        #expect(lastSuccess?.sequence.rawValue == 5)
        #expect(revision.rawValue == 6)
        #expect(pendingSince?.millisecondsSince1970 == 10_000)
    }

    @Test("A status cannot attach another scope's success evidence")
    func scopeMismatch() throws {
        #expect(throws: ReconciliationStatusModelError.successScopeMismatch) {
            try ReconciliationStatus(
                scopeID: WatchedScopeID("scope-a"),
                state: .failed(
                    lastSuccess: success(
                        scopeID: "scope-b",
                        sequence: 5,
                        completedAt: 20_000
                    ),
                    attemptedRevision: DirtyRegionRevision(6),
                    attemptedAt: ObservationInstant(millisecondsSince1970: 21_000)
                )
            )
        }
    }

    @Test("Permission, volume, history, and baseline states are explicit")
    func explicitUnavailabilityStates() throws {
        let scopeID = try WatchedScopeID("scope-a")
        let states: [ReconciliationStatusState] = [
            .permissionRequired(lastSuccess: nil),
            .volumeUnavailable(lastSuccess: nil),
            .historyDisabled,
            .baselineUnavailable,
        ]

        for state in states {
            let status = try ReconciliationStatus(scopeID: scopeID, state: state)
            #expect(status.state == state)
        }
    }

    @Test("Partial status carries the attempted revision instead of an optional date sentinel")
    func partialStatus() throws {
        let status = try ReconciliationStatus(
            scopeID: WatchedScopeID("scope-a"),
            state: .partial(
                lastSuccess: nil,
                attemptedRevision: DirtyRegionRevision(8),
                attemptedAt: ObservationInstant(millisecondsSince1970: 30_000)
            )
        )

        guard case let .partial(lastSuccess, revision, attemptedAt) = status.state else {
            Issue.record("Expected partial state")
            return
        }
        #expect(lastSuccess == nil)
        #expect(revision.rawValue == 8)
        #expect(attemptedAt.millisecondsSince1970 == 30_000)
    }
}

private func success(
    scopeID: String,
    sequence: Int64,
    completedAt: Int64
) throws -> ReconciliationSuccess {
    try ReconciliationSuccess(
        scopeID: WatchedScopeID(scopeID),
        sequence: ReconciliationRevisionSequence(sequence),
        completedAt: ObservationInstant(millisecondsSince1970: completedAt)
    )
}
