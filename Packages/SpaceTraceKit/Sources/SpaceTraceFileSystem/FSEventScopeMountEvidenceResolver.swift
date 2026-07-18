import Foundation
import SpaceTraceApplication

/// Resolves persistent volume evidence through the exact approved scope before
/// a mount generation is activated. This closes the gap where Disk
/// Arbitration reports a mount path before its callback description contains
/// the volume UUID.
public struct FSEventScopeMountEvidenceResolver: ScopeMountEvidenceResolver {
    private let resolver: FSEventDeviceScopeResolver

    public init(resolver: FSEventDeviceScopeResolver = FSEventDeviceScopeResolver()) {
        self.resolver = resolver
    }

    public func resolve(
        _ evidence: VolumeMountEvidence,
        for scope: WatchedScope
    ) async throws -> VolumeMountEvidence {
        let resolved = try resolver.resolve(
            watchedURLs: [URL(fileURLWithPath: scope.root.rawValue, isDirectory: true)]
        )
        let resolvedMountPath = Self.applicationPath(resolved.deviceTarget.mountPath)
        guard resolvedMountPath == scope.mountPath.rawValue,
              resolvedMountPath == evidence.mountPath.rawValue else {
            throw FSEventScopeMountEvidenceResolverError.mountPathChanged
        }
        if let observedUUID = evidence.volumeUUID,
           let resolvedUUID = resolved.volumeUUID,
           observedUUID != resolvedUUID {
            throw FSEventScopeMountEvidenceResolverError.volumeChanged
        }
        return try VolumeMountEvidence(
            mountPath: evidence.mountPath,
            volumeUUID: resolved.volumeUUID ?? evidence.volumeUUID
        )
    }

    private static func applicationPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

public enum FSEventScopeMountEvidenceResolverError: Error, Sendable, Equatable {
    case mountPathChanged
    case volumeChanged
}
