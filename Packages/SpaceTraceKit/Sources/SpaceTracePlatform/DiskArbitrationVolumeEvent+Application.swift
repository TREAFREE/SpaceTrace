import SpaceTraceApplication

public extension DiskArbitrationVolumeEvent {
    /// Erases Disk Arbitration types before the event enters the application
    /// layer. Display names are intentionally absent: same-name volumes are
    /// distinguished by their persistent UUIDs.
    func lifecycleSignal() throws -> VolumeLifecycleSignal {
        switch self {
        case let .appeared(snapshot):
            return .available(try snapshot.applicationObservation())
        case let .descriptionChanged(snapshot):
            return .changed(try snapshot.applicationObservation())
        case let .disappeared(snapshot):
            return .unavailable(try snapshot.applicationObservation())
        case .callbackBridgeOverflow:
            return .continuityLost
        }
    }
}

private extension DiskArbitrationVolumeSnapshot {
    func applicationObservation() throws -> VolumeMountObservation {
        try VolumeMountObservation(
            runtimeID: bsdName.map(RuntimeVolumeID.init),
            evidence: mountEvidence(),
            volumeUUID: volumeUUID
        )
    }
}
