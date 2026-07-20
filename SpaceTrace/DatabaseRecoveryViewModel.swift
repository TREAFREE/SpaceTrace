import Observation
import SpaceTracePersistence

@MainActor
@Observable
final class DatabaseRecoveryViewModel {
    private(set) var overview: SQLiteReadOnlyRecoveryOverview?

    func activate(_ overview: SQLiteReadOnlyRecoveryOverview) {
        self.overview = overview
    }
}
