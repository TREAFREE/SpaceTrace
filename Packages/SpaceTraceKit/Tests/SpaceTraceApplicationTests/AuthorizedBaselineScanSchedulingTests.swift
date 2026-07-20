import Testing
@testable import SpaceTraceApplication

struct AuthorizedBaselineScanSchedulingTests {
    struct Fixture: Sendable {
        let snapshot: ScanSchedulingSnapshot
        let expectedReason: AuthorizedBaselineScanDeferralReason?
    }

    @Test(
        "Policy produces deterministic typed eligibility",
        arguments: [
            Fixture(
                snapshot: .unconstrained,
                expectedReason: nil
            ),
            Fixture(
                snapshot: ScanSchedulingSnapshot(
                    powerSource: .battery,
                    isLowPowerModeEnabled: false,
                    thermalPressure: .fair,
                    systemActivity: .awake
                ),
                expectedReason: nil
            ),
            Fixture(
                snapshot: ScanSchedulingSnapshot(
                    powerSource: .external,
                    isLowPowerModeEnabled: true,
                    thermalPressure: .nominal,
                    systemActivity: .awake
                ),
                expectedReason: .lowPowerMode
            ),
            Fixture(
                snapshot: ScanSchedulingSnapshot(
                    powerSource: .external,
                    isLowPowerModeEnabled: false,
                    thermalPressure: .serious,
                    systemActivity: .awake
                ),
                expectedReason: .thermalPressure(.serious)
            ),
            Fixture(
                snapshot: ScanSchedulingSnapshot(
                    powerSource: .external,
                    isLowPowerModeEnabled: true,
                    thermalPressure: .critical,
                    systemActivity: .sleeping
                ),
                expectedReason: .systemSleeping
            ),
        ]
    )
    func policyDecision(fixture: Fixture) {
        let decision = AuthorizedBaselineScanSchedulingPolicy()
            .decision(for: fixture.snapshot)
        switch (decision, fixture.expectedReason) {
        case (.runnable, nil):
            break
        case let (.deferred(reason, _), expectedReason?):
            #expect(reason == expectedReason)
        default:
            Issue.record("Decision did not match the expected eligibility.")
        }
    }

    @Test("Gate replays current state and suppresses duplicate snapshots")
    func gateReplaysAndDeduplicates() async {
        let gate = AuthorizedBaselineScanSchedulingGate()
        let stream = await gate.decisions()
        let recorder = SchedulingDecisionRecorder()
        let observation = Task {
            for await decision in stream {
                await recorder.record(decision)
                if await recorder.count == 2 { return }
            }
        }

        await gate.update(.unconstrained)
        await gate.update(
            ScanSchedulingSnapshot(
                powerSource: .battery,
                isLowPowerModeEnabled: true,
                thermalPressure: .nominal,
                systemActivity: .awake
            )
        )
        await observation.value

        #expect(await recorder.count == 2)
        #expect(await recorder.lastReason == .lowPowerMode)
    }
}

private actor SchedulingDecisionRecorder {
    private var decisions: [AuthorizedBaselineScanSchedulingDecision] = []

    var count: Int { decisions.count }

    var lastReason: AuthorizedBaselineScanDeferralReason? {
        guard case let .deferred(reason, _) = decisions.last else { return nil }
        return reason
    }

    func record(_ decision: AuthorizedBaselineScanSchedulingDecision) {
        decisions.append(decision)
    }
}
