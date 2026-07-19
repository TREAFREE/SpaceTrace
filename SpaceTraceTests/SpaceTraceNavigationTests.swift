import SpaceTraceApplication
import Testing
@testable import SpaceTrace

@MainActor
struct SpaceTraceNavigationTests {
    @Test("The ordinary app shell exposes only implemented top-level destinations")
    func topLevelDestinationsStayHonest() {
        #expect(SpaceTraceSection.allCases == [.overview, .permissions])
        #expect(Set(SpaceTraceSection.allCases.map(\.accessibilityIdentifier)).count == 2)
    }

    @Test("Overview readiness never presents an unavailable grant as ready")
    func readinessRequiresAnActiveScope() {
        #expect(OverviewReadiness(status: .loading) == .preparing)
        #expect(OverviewReadiness(status: .unconfigured) == .needsAuthorization)
        #expect(
            OverviewReadiness(status: .authorized(path: "/Volumes/Fixture/Selected"))
                == .ready(path: "/Volumes/Fixture/Selected")
        )
        #expect(OverviewReadiness(status: .unavailable) == .needsAttention)
        #expect(
            OverviewReadiness(
                status: .requiresReauthorization(reason: .volumeIdentityChanged)
            ) == .needsAttention
        )
        #expect(OverviewReadiness(status: .failed) == .needsAttention)
    }
}
