import CoreServices
import Darwin
import Foundation
import SpaceTraceApplication

/// Resolution boundary used by the stream supervisor. Production resolves
/// public filesystem metadata; tests can provide a fixed mounted-device view.
public protocol FSEventDeviceScopeResolving: Sendable {
    func resolve(watchedURLs: [URL]) throws -> ResolvedFSEventDeviceScope
}

/// A set of watch paths proven to belong to one currently-mounted device.
public struct ResolvedFSEventDeviceScope: Sendable, Equatable {
    public let deviceTarget: FSEventDeviceTarget
    public let volumeUUID: UUID?
    public let journalUUID: UUID?

    init(
        deviceTarget: FSEventDeviceTarget,
        volumeUUID: UUID?,
        journalUUID: UUID?
    ) {
        self.deviceTarget = deviceTarget
        self.volumeUUID = volumeUUID
        self.journalUUID = journalUUID
    }

    /// A durable cursor identity exists only while FSEvents exposes a journal
    /// UUID for this device. Read-only or unsupported volumes may not have one.
    public var persistentIdentity: PersistentEventStreamIdentity? {
        guard let volumeUUID, let journalUUID else { return nil }
        return PersistentEventStreamIdentity(
            volumeUUID: volumeUUID,
            journalUUID: journalUUID
        )
    }

    public func configuration(
        replayPosition: FSEventReplayPosition = .sinceNow,
        latency: TimeInterval = 1,
        bufferCapacity: Int = 512,
        excludeEventsFromThisProcess: Bool = true
    ) throws -> FSEventStreamConfiguration {
        if case .after = replayPosition, persistentIdentity == nil {
            throw FSEventDeviceScopeError.persistentHistoryUnavailable
        }
        return FSEventStreamConfiguration(
            deviceTarget: deviceTarget,
            replayPosition: replayPosition,
            latency: latency,
            bufferCapacity: bufferCapacity,
            excludeEventsFromThisProcess: excludeEventsFromThisProcess
        )
    }
}

/// Resolves user-approved directory scopes into one per-device FSEvents target.
/// The resolver performs no mounting and never broadens a scope to another volume.
public struct FSEventDeviceScopeResolver: Sendable {
    public init() {}

    public func resolve(watchedURLs: [URL]) throws -> ResolvedFSEventDeviceScope {
        guard watchedURLs.isEmpty == false else {
            throw FSEventDeviceScopeError.noWatchedURLs
        }

        let resolved = try watchedURLs.enumerated().map { index, url in
            try resolve(url: url, index: index)
        }
        let first = resolved[0]
        for (index, scope) in resolved.enumerated().dropFirst()
        where scope.deviceID != first.deviceID || scope.volumeUUID != first.volumeUUID {
            throw FSEventDeviceScopeError.watchPathsSpanVolumes(index: index)
        }

        let relativePaths = try resolved.enumerated().map { index, scope in
            try relativePath(
                of: scope.url.path,
                beneath: first.mountPath,
                index: index
            )
        }
        let journalUUID = try journalUUID(for: first.deviceID)

        return ResolvedFSEventDeviceScope(
            deviceTarget: FSEventDeviceTarget(
                deviceID: UInt64(first.deviceID),
                mountPath: first.mountPath,
                relativePaths: relativePaths
            ),
            volumeUUID: first.volumeUUID,
            journalUUID: journalUUID
        )
    }

    private func resolve(url: URL, index: Int) throws -> ResolvedURL {
        guard url.isFileURL else {
            throw FSEventDeviceScopeError.notFileURL(index: index)
        }
        let resolvedURL = try canonicalURL(url, index: index)
        let values: URLResourceValues
        do {
            values = try resolvedURL.resourceValues(
                forKeys: [.isDirectoryKey, .volumeURLKey, .volumeUUIDStringKey]
            )
        } catch {
            throw FSEventDeviceScopeError.unavailablePath(index: index)
        }
        guard values.isDirectory == true else {
            throw FSEventDeviceScopeError.watchPathMustBeDirectory(index: index)
        }
        guard let volumeURL = values.volume else {
            throw FSEventDeviceScopeError.volumeRootUnavailable(index: index)
        }
        let mountURL = try canonicalURL(volumeURL, index: index)
        let volumeUUID: UUID?
        if let volumeUUIDString = values.volumeUUIDString {
            guard let parsed = UUID(uuidString: volumeUUIDString) else {
                throw FSEventDeviceScopeError.invalidPersistentVolumeUUID(index: index)
            }
            volumeUUID = parsed
        } else {
            volumeUUID = nil
        }

        var information = stat()
        let result = resolvedURL.path.withCString { pointer in
            lstat(pointer, &information)
        }
        guard result == 0 else {
            throw FSEventDeviceScopeError.unavailablePath(index: index)
        }
        guard information.st_dev > 0 else {
            throw FSEventDeviceScopeError.invalidDeviceIdentifier(index: index)
        }

        return ResolvedURL(
            url: resolvedURL,
            mountPath: mountURL.path,
            volumeUUID: volumeUUID,
            deviceID: information.st_dev
        )
    }

    private func canonicalURL(_ url: URL, index: Int) throws -> URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved = url.path.withCString { source in
            buffer.withUnsafeMutableBufferPointer { destination in
                realpath(source, destination.baseAddress)
            }
        }
        guard resolved != nil else {
            throw FSEventDeviceScopeError.unavailablePath(index: index)
        }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
    }

    private func relativePath(
        of path: String,
        beneath mountPath: String,
        index: Int
    ) throws -> String {
        if path == mountPath {
            return ""
        }
        if mountPath == "/", path.first == "/" {
            return String(path.dropFirst())
        }
        let prefix = mountPath + "/"
        guard path.hasPrefix(prefix) else {
            throw FSEventDeviceScopeError.pathOutsideVolumeRoot(index: index)
        }
        return String(path.dropFirst(prefix.count))
    }

    private func journalUUID(for deviceID: dev_t) throws -> UUID? {
        guard let value = FSEventsCopyUUIDForDevice(deviceID) else {
            return nil
        }
        let rawValue = CFUUIDCreateString(kCFAllocatorDefault, value) as String
        guard let uuid = UUID(uuidString: rawValue) else {
            throw FSEventDeviceScopeError.invalidJournalUUID
        }
        return uuid
    }
}

extension FSEventDeviceScopeResolver: FSEventDeviceScopeResolving {}

private struct ResolvedURL {
    let url: URL
    let mountPath: String
    let volumeUUID: UUID?
    let deviceID: dev_t
}

public enum FSEventDeviceScopeError: Error, Sendable, Equatable {
    case noWatchedURLs
    case notFileURL(index: Int)
    case unavailablePath(index: Int)
    case watchPathMustBeDirectory(index: Int)
    case volumeRootUnavailable(index: Int)
    case invalidPersistentVolumeUUID(index: Int)
    case invalidDeviceIdentifier(index: Int)
    case watchPathsSpanVolumes(index: Int)
    case pathOutsideVolumeRoot(index: Int)
    case invalidJournalUUID
    case persistentHistoryUnavailable
}
