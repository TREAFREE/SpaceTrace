import SpaceTraceApplication
import Testing
@testable import SpaceTrace

@MainActor
struct SpaceTraceNavigationTests {
    @Test("The ordinary app shell exposes only implemented top-level destinations")
    func topLevelDestinationsStayHonest() {
        #expect(SpaceTraceSection.allCases == [.overview, .permissions, .diagnostics])
        #expect(Set(SpaceTraceSection.allCases.map(\.accessibilityIdentifier)).count == 3)
    }

    @Test("Overview readiness never presents an unavailable grant as ready")
    func readinessRequiresAnActiveScope() {
        #expect(OverviewReadiness(summary: .loading) == .preparing)
        #expect(OverviewReadiness(summary: .unconfigured) == .needsAuthorization)
        #expect(
            OverviewReadiness(summary: .ready(authorizedCount: 2))
                == .ready(authorizedCount: 2)
        )
        #expect(
            OverviewReadiness(
                summary: .needsAttention(authorizedCount: 1, issueCount: 2)
            ) == .needsAttention(authorizedCount: 1, issueCount: 2)
        )
        #expect(
            OverviewReadiness(summary: .failed)
                == .needsAttention(authorizedCount: 0, issueCount: 0)
        )
    }
}
