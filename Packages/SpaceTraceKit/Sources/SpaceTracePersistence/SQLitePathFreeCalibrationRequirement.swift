import Foundation
import SpaceTraceApplication

public struct PathFreeCalibrationRequirement: Sendable, Equatable {
    public let streamID: EventStreamID
    public let scopeID: WatchedScopeID?
    public let reasons: DirtyRegionReason
    public let createdAt: Date
}
