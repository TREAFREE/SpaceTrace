public enum SnapshotFactorObservation: String, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case none
    case localAPFSSnapshot = "local_apfs_snapshot"
    case timeMachineLocalSnapshot = "time_machine_local_snapshot"
}

public struct AttributionVolumeContext: Sendable, Equatable, Hashable, Codable {
    public let snapshotFactorObservation: SnapshotFactorObservation

    public init(snapshotFactorObservation: SnapshotFactorObservation = .none) {
        self.snapshotFactorObservation = snapshotFactorObservation
    }

    public static let none = AttributionVolumeContext()
}

/// Pure lexical features supplied to the deterministic classifier.
///
/// Construction does not touch the filesystem, resolve links, infer a volume,
/// or read file contents. Paths remain transient inputs and must not be logged.
public struct AttributionInput: Sendable, Equatable, Hashable {
    public let absolutePathComponents: [String]
    public let homeRelativePathComponents: [String]?
    public let bundleIdentifier: String?
    public let volumeContext: AttributionVolumeContext

    public init(
        absolutePath: String,
        homeDirectory: String? = nil,
        bundleIdentifier: String? = nil,
        volumeContext: AttributionVolumeContext = .none
    ) throws(AttributionInputError) {
        let absolutePathComponents = try Self.normalizeAbsolutePath(absolutePath)

        let homeRelativePathComponents: [String]?
        if let homeDirectory {
            let homeComponents = try Self.normalizeAbsolutePath(homeDirectory)
            guard homeComponents.isEmpty == false else {
                throw .invalidHomeDirectory
            }

            if absolutePathComponents.starts(with: homeComponents) {
                homeRelativePathComponents = Array(absolutePathComponents.dropFirst(homeComponents.count))
            } else {
                homeRelativePathComponents = nil
            }
        } else {
            homeRelativePathComponents = nil
        }

        if let bundleIdentifier {
            guard bundleIdentifier.allSatisfy(\.isWhitespace) == false,
                  bundleIdentifier.contains("/") == false,
                  bundleIdentifier.contains("\\") == false,
                  bundleIdentifier.contains("\0") == false
            else {
                throw .invalidBundleIdentifier
            }
        }

        self.absolutePathComponents = absolutePathComponents
        self.homeRelativePathComponents = homeRelativePathComponents
        self.bundleIdentifier = bundleIdentifier
        self.volumeContext = volumeContext
    }

    private static func normalizeAbsolutePath(_ path: String) throws(AttributionInputError) -> [String] {
        guard path.first == "/" else {
            throw .pathMustBeAbsolute
        }

        var components: [String] = []
        components.reserveCapacity(8)

        for rawComponent in path.split(separator: "/", omittingEmptySubsequences: true) {
            let component = String(rawComponent)
            switch component {
            case ".":
                continue
            case "..":
                throw .parentTraversalNotAllowed
            default:
                guard component.contains("\0") == false else {
                    throw .invalidPathComponent
                }
                components.append(component)
            }
        }

        return components
    }
}

public enum AttributionInputError: Error, Sendable, Equatable {
    case pathMustBeAbsolute
    case parentTraversalNotAllowed
    case invalidPathComponent
    case invalidHomeDirectory
    case invalidBundleIdentifier
}
