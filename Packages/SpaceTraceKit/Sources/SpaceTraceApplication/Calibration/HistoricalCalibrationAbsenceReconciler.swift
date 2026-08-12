import Foundation
import SpaceTraceDomain

/// Adds only explicit, parent-proven disappearance evidence to a complete
/// current scan candidate. A missing row is never enough by itself: the prior
/// endpoint must have been complete, and the unchanged direct parent must have
/// complete current measurement and direct-child enumeration coverage.
package struct HistoricalCalibrationAbsenceReconciler: Sendable {
    package init() {}

    package func reconcile(
        current: HistoricalPairedObservationCandidate,
        previousLogicalFrame: HistoricalFindingObservationFrame
    ) throws(HistoricalFindingPersistenceModelError) -> HistoricalPairedObservationCandidate {
        guard hasCompatibleContext(current: current, previous: previousLogicalFrame) else {
            return current
        }

        let currentBySubject = Dictionary(
            uniqueKeysWithValues: current.nodes.map { ($0.subjectID, $0) }
        )
        let previousBySubject = Dictionary(
            uniqueKeysWithValues: previousLogicalFrame.nodes.map {
                ($0.endpoint.subjectID, $0)
            }
        )
        let occupiedPaths = Set(current.nodes.map { Data($0.path.utf8) })
        let occupiedLocations = Set(current.nodes.map(\.locationID))
        var reconciledNodes = current.nodes

        for previousNode in previousLogicalFrame.nodes {
            let subjectID = previousNode.endpoint.subjectID
            guard currentBySubject[subjectID] == nil,
                  let parentSubjectID = previousNode.parentSubjectID,
                  let previousParent = previousBySubject[parentSubjectID],
                  let currentParent = currentBySubject[parentSubjectID],
                  case .present(_, .complete) = previousNode.endpoint.state,
                  case .present(_, _, .complete) = currentParent.state,
                  currentParent.directChildrenCoverage == .complete,
                  previousParent.endpoint.locationID == currentParent.locationID,
                  binaryEqual(previousParent.path, currentParent.path),
                  occupiedPaths.contains(Data(previousNode.path.utf8)) == false,
                  occupiedLocations.contains(previousNode.endpoint.locationID) == false else {
                continue
            }

            reconciledNodes.append(
                try HistoricalPairedObservationNodeCandidate(
                    subjectID: subjectID,
                    identityBasis: previousNode.endpoint.identityBasis,
                    parentSubjectID: parentSubjectID,
                    locationID: previousNode.endpoint.locationID,
                    path: previousNode.path,
                    displayName: previousNode.displayName,
                    observedAt: currentParent.observedAt,
                    state: .absent,
                    directChildrenCoverage: .unknown,
                    classification: nil,
                    stableIdentityEvidence: previousNode.stableIdentityEvidence
                )
            )
        }

        guard reconciledNodes.count != current.nodes.count else { return current }
        return try HistoricalPairedObservationCandidate(
            rootSubjectID: current.rootSubjectID,
            rootPath: current.rootPath,
            nodes: reconciledNodes,
            scopeID: current.scopeID,
            volumeID: current.volumeID,
            mountGenerationID: current.mountGenerationID,
            coverageEpochID: current.coverageEpochID,
            pathSemanticsVersion: current.pathSemanticsVersion,
            measurementSemanticsVersion: current.measurementSemanticsVersion
        )
    }

    private func hasCompatibleContext(
        current: HistoricalPairedObservationCandidate,
        previous: HistoricalFindingObservationFrame
    ) -> Bool {
        previous.metric == .logical
            && previous.scopeID == current.scopeID
            && previous.volumeID == current.volumeID
            && previous.mountGenerationID == current.mountGenerationID
            && previous.coverageEpochID == current.coverageEpochID
            && previous.pathSemanticsVersion == current.pathSemanticsVersion
            && previous.measurementSemanticsVersion == current.measurementSemanticsVersion
            && previous.rootSubjectID == current.rootSubjectID
            && binaryEqual(previous.rootPath, current.rootPath)
    }
}
