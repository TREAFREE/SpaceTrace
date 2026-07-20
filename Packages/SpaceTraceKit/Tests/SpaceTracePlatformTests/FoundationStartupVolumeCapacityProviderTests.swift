import Foundation
import Testing
@testable import SpaceTracePlatform

struct FoundationStartupVolumeCapacityProviderTests {
    @Test("The startup data volume sample reports current capacity without inventing values")
    func samplesContainingVolume() async throws {
        let timestamp = Date(timeIntervalSince1970: 1_750_000_000)
        let provider = FoundationStartupVolumeCapacityProvider(
            dataDirectoryURL: FileManager.default.temporaryDirectory,
            now: { timestamp }
        )

        let snapshot = await provider.snapshot()

        #expect(snapshot.observedAt == timestamp)
        let total = try #require(snapshot.totalBytes)
        let available = try #require(snapshot.availableBytes)
        #expect(total.value > 0)
        #expect(available <= total)
    }

    @Test("Unavailable resource values remain unknown rather than becoming zero")
    func preservesUnknownCapacity() async {
        let provider = FoundationStartupVolumeCapacityProvider(
            dataDirectoryURL: URL(string: "https://example.invalid/not-a-volume")!
        )

        let snapshot = await provider.snapshot()

        #expect(snapshot.totalBytes == nil)
        #expect(snapshot.availableBytes == nil)
        #expect(snapshot.availableForImportantUsageBytes == nil)
    }
}
