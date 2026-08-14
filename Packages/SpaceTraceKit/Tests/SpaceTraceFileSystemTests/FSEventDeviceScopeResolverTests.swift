import Foundation
import Testing
@testable import SpaceTraceFileSystem

struct FSEventDeviceScopeResolverTests {
    @Test("Device scope resolution rejects an empty watch list")
    func rejectsEmptyWatchList() {
        #expect(throws: FSEventDeviceScopeError.noWatchedURLs) {
            try FSEventDeviceScopeResolver().resolve(watchedURLs: [])
        }
    }

    @Test("Device scope resolution accepts only file URLs")
    func rejectsNonFileURL() throws {
        let networkURL = try #require(URL(string: "https://example.invalid/scope"))

        #expect(throws: FSEventDeviceScopeError.notFileURL(index: 0)) {
            try FSEventDeviceScopeResolver().resolve(watchedURLs: [networkURL])
        }
    }

    @Test("A device without persistent identity cannot replay an old cursor")
    func unavailableHistoryRejectsReplay() {
        let scope = ResolvedFSEventDeviceScope(
            deviceTarget: FSEventDeviceTarget(
                deviceID: 1,
                mountPath: "/Volumes/Ephemeral",
                relativePaths: [""]
            ),
            volumeUUID: nil,
            journalUUID: nil
        )

        #expect(scope.persistentIdentity == nil)
        #expect(throws: FSEventDeviceScopeError.persistentHistoryUnavailable) {
            try scope.configuration(
                replayPosition: .after(FSEventID(rawValue: 42))
            )
        }
        #expect(throws: Never.self) {
            _ = try scope.configuration(replayPosition: .sinceNow)
        }
    }
}
