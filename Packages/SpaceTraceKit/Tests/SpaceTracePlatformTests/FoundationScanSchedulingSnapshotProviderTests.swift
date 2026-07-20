import Foundation
import Testing
@testable import SpaceTracePlatform

struct FoundationScanSchedulingSnapshotProviderTests {
    @Test("Foundation and IOKit values map into application-owned types")
    func mapsNativeValues() {
        let battery = FoundationScanSchedulingSnapshotProvider.snapshot(
            thermalState: .serious,
            isLowPowerModeEnabled: true,
            powerSourceName: "Battery Power",
            systemActivity: .sleeping
        )
        #expect(battery.powerSource == .battery)
        #expect(battery.isLowPowerModeEnabled)
        #expect(battery.thermalPressure == .serious)
        #expect(battery.systemActivity == .sleeping)

        let external = FoundationScanSchedulingSnapshotProvider.snapshot(
            thermalState: .nominal,
            isLowPowerModeEnabled: false,
            powerSourceName: "AC Power",
            systemActivity: .awake
        )
        #expect(external.powerSource == .external)
        #expect(external.isLowPowerModeEnabled == false)
        #expect(external.thermalPressure == .nominal)
        #expect(external.systemActivity == .awake)
    }

    @Test("Unknown native power sources remain unknown")
    func preservesUnknownPowerSource() {
        let snapshot = FoundationScanSchedulingSnapshotProvider.snapshot(
            thermalState: .fair,
            isLowPowerModeEnabled: false,
            powerSourceName: "Future Power Source",
            systemActivity: .awake
        )
        #expect(snapshot.powerSource == .unknown)
        #expect(snapshot.thermalPressure == .fair)
    }
}
