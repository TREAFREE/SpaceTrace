import Foundation
import Darwin
import SpaceTraceApplication
import SpaceTraceFileSystem
import SpaceTraceMonitoring
import SpaceTracePersistence
import Testing

extension Tag {
    @Tag static var apfsDiskImage: Self
}

@Suite(
    "APFS disk-image lifecycle integration",
    .serialized,
    .tags(.apfsDiskImage)
)
struct APFSDiskImageLifecycleIntegrationTests {
    @Test(
        "APFS directory identity survives rename while location changes",
        .enabled(if: ProcessInfo.processInfo.environment["SPACETRACE_RUN_APFS_IMAGE_TESTS"] == "1"),
        .timeLimit(.minutes(3))
    )
    func directoryIdentitySurvivesRename() async throws {
        let fixture = try APFSDiskImageFixture()
        defer { fixture.remove() }
        try fixture.prepareImages()
        let mounted = try fixture.attachFirstImage()
        let before = fixture.watchedRoot.appendingPathComponent("Before", isDirectory: true)
        let after = fixture.watchedRoot.appendingPathComponent("After", isDirectory: true)
        let linkAttempt = fixture.watchedRoot.appendingPathComponent(
            "DirectoryLinkAttempt",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: before,
            withIntermediateDirectories: false
        )

        let scanner = FoundationMetadataCalibrationScanner()
        let beforeEvidence = try await scanHistoricalEvidence(
            root: fixture.watchedRoot,
            scanner: scanner,
            cursor: 1
        )
        let linkAttemptExists: Bool
        do {
            try FileManager.default.linkItem(
                at: before,
                to: linkAttempt
            )
            linkAttemptExists = true
        } catch {
            linkAttemptExists = false
        }
        try FileManager.default.moveItem(at: before, to: after)
        let afterEvidence = try await scanHistoricalEvidence(
            root: fixture.watchedRoot,
            scanner: scanner,
            cursor: 2
        )

        let context = try HistoricalCalibrationContext(
            watchedScopeID: WatchedScopeID("apfs-identity-qualification"),
            volumeUUID: mounted.volumeUUID,
            mountGenerationID: MountGenerationID("mounted-generation-a"),
            homeDirectoryPath: nil
        )
        let builder = HistoricalCalibrationCandidateBuilder()
        let beforeCandidate = try builder.build(beforeEvidence, context: context)
        let afterCandidate = try builder.build(afterEvidence, context: context)
        let beforeNode = try #require(
            beforeCandidate.nodes.first { $0.path == before.standardizedFileURL.path }
        )
        let afterNode = try #require(
            afterCandidate.nodes.first { $0.path == after.standardizedFileURL.path }
        )

        #expect(beforeNode.identityBasis == .stableFileSystemObject)
        #expect(beforeNode.stableIdentityEvidence?.linkStatus == .unique)
        #expect(beforeNode.subjectID == afterNode.subjectID)
        #expect(beforeNode.locationID != afterNode.locationID)
        #expect(beforeNode.stableIdentityEvidence == afterNode.stableIdentityEvidence)
        if linkAttemptExists {
            let distinctObject = try #require(
                afterCandidate.nodes.first {
                    $0.path == linkAttempt.standardizedFileURL.path
                }
            )
            // Foundation may satisfy linkItem for an APFS directory by
            // creating a distinct directory object. It must never share the
            // stable object identity used to prove a move.
            #expect(distinctObject.subjectID != afterNode.subjectID)
        }
        try fixture.detachMountedImage()
    }

    @Test(
        "Unmount, remount, and same-name replacement restart isolated generations",
        .enabled(if: ProcessInfo.processInfo.environment["SPACETRACE_RUN_APFS_IMAGE_TESTS"] == "1"),
        .timeLimit(.minutes(3))
    )
    func unmountRemountAndSameNameReplacement() async throws {
        let fixture = try APFSDiskImageFixture()
        defer { fixture.remove() }
        try fixture.prepareImages()

        let repository = try SQLiteEventJournalRepository(databaseURL: fixture.databaseURL)
        let scope = try WatchedScope(
            id: WatchedScopeID("apfs-image-qualification"),
            root: DirtyRegionPath(fixture.watchedRoot.path),
            mountPath: DirtyRegionPath(fixture.mountPoint.path)
        )
        let catalog = try ConfiguredWatchedScopeCatalog(scopes: [scope])
        let runtime = NativeVolumeMonitoringRuntime(
            catalog: catalog,
            repository: repository,
            scanner: FoundationMetadataCalibrationScanner(),
            eventBufferCapacity: 64,
            fseventLatency: 0.01,
            fseventBufferCapacity: 256,
            excludeEventsFromThisProcess: false
        )
        let runtimeFailure = RuntimeFailureRecorder()
        let runtimeTask = Task {
            do {
                try await runtime.run()
            } catch {
                await runtimeFailure.record(String(reflecting: error))
                throw error
            }
        }
        defer { runtimeTask.cancel() }

        try await eventually(step: "Disk Arbitration source startup") {
            await runtime.isObservingVolumeEvents()
        }

        let firstMount = try fixture.attachFirstImage()
        let firstGeneration = try await activeGeneration(
            scopeID: scope.id,
            configuredMountPath: scope.mountPath,
            volumeUUID: firstMount.volumeUUID,
            repository: repository,
            runtime: runtime,
            runtimeFailure: runtimeFailure
        )
        let firstStatus = try #require(await runtime.activeStatus(for: scope.id))
        if let identity = firstStatus.persistentIdentity {
            #expect(identity.volumeUUID == firstMount.volumeUUID)
        } else {
            #expect(firstStatus.streamID.rawValue.hasPrefix("fsevents-live/v1/"))
        }

        _ = try fixture.createFile(named: "first-volume-event.bin")
        try await fseventEvidence(
            step: "first-volume FSEvents delivery",
            scopeID: scope.id,
            streamID: firstStatus.streamID,
            repository: repository,
            runtime: runtime
        )

        try fixture.detachMountedImage()
        try await inactiveGeneration(
            scopeID: scope.id,
            repository: repository,
            runtime: runtime
        )

        let remount = try fixture.attachFirstImage()
        #expect(remount.volumeUUID == firstMount.volumeUUID)
        let remountedGeneration = try await activeGeneration(
            scopeID: scope.id,
            configuredMountPath: scope.mountPath,
            volumeUUID: remount.volumeUUID,
            excluding: firstGeneration.generationID,
            repository: repository,
            runtime: runtime,
            runtimeFailure: runtimeFailure
        )
        #expect(remountedGeneration.generationID != firstGeneration.generationID)

        try fixture.detachMountedImage()
        try await inactiveGeneration(
            scopeID: scope.id,
            repository: repository,
            runtime: runtime
        )

        let replacement = try fixture.attachSecondImage()
        #expect(replacement.volumeName == firstMount.volumeName)
        #expect(replacement.volumeUUID != firstMount.volumeUUID)
        let replacementGeneration = try await activeGeneration(
            scopeID: scope.id,
            configuredMountPath: scope.mountPath,
            volumeUUID: replacement.volumeUUID,
            excluding: remountedGeneration.generationID,
            repository: repository,
            runtime: runtime,
            runtimeFailure: runtimeFailure
        )
        let replacementStatus = try #require(await runtime.activeStatus(for: scope.id))
        #expect(replacementGeneration.generationID != remountedGeneration.generationID)
        if let identity = replacementStatus.persistentIdentity {
            #expect(identity.volumeUUID == replacement.volumeUUID)
        } else {
            #expect(replacementStatus.streamID.rawValue.hasPrefix("fsevents-live/v1/"))
        }
        #expect(replacementStatus.streamID != firstStatus.streamID)

        _ = try fixture.createFile(named: "replacement-volume-event.bin")
        try await fseventEvidence(
            step: "replacement-volume FSEvents delivery",
            scopeID: scope.id,
            streamID: replacementStatus.streamID,
            repository: repository,
            runtime: runtime
        )

        runtimeTask.cancel()
        _ = await runtimeTask.result
        try fixture.detachMountedImage()
    }

    private func activeGeneration(
        scopeID: WatchedScopeID,
        configuredMountPath: DirtyRegionPath,
        volumeUUID: UUID,
        excluding previous: MountGenerationID? = nil,
        repository: SQLiteEventJournalRepository,
        runtime: NativeVolumeMonitoringRuntime,
        runtimeFailure: RuntimeFailureRecorder
    ) async throws -> ScopeMountGeneration {
        do {
            return try await eventuallyValue(step: "active generation for \(volumeUUID.uuidString)") {
                if let failure = await runtimeFailure.failure() {
                    throw APFSDiskImageFixtureError.runtimeFailed(failure)
                }
                guard let generation = try await repository.scopeMountGeneration(for: scopeID),
                      generation.isActive,
                      generation.volumeUUID == volumeUUID,
                      generation.generationID != previous,
                      await runtime.activeStatus(for: scopeID)?.generationID == generation.generationID else {
                    return nil
                }
                return generation
            }
        } catch {
            let storedGeneration = try? await repository.scopeMountGeneration(for: scopeID)
            let activeStatus = await runtime.activeStatus(for: scopeID)
            let streamFailure = await runtime.lastStreamFailure(for: scopeID)
            let result = await runtime.lastResult()
            throw APFSDiskImageFixtureError.activationFailed(
                cause: String(reflecting: error),
                lastSignal: String(reflecting: await runtime.lastVolumeSignal()),
                storedGeneration: String(reflecting: storedGeneration),
                activeStatus: String(reflecting: activeStatus),
                streamFailure: String(reflecting: streamFailure),
                monitoringResult: String(reflecting: result),
                configuredMountPath: configuredMountPath.rawValue
            )
        }
    }

    private func inactiveGeneration(
        scopeID: WatchedScopeID,
        repository: SQLiteEventJournalRepository,
        runtime: NativeVolumeMonitoringRuntime
    ) async throws {
        try await eventually(step: "inactive generation for \(scopeID.rawValue)") {
            let generation = try await repository.scopeMountGeneration(for: scopeID)
            let status = await runtime.activeStatus(for: scopeID)
            return generation?.isActive == false
                && status == nil
        }
    }

    private func fseventEvidence(
        step: String,
        scopeID: WatchedScopeID,
        streamID: EventStreamID,
        repository: SQLiteEventJournalRepository,
        runtime: NativeVolumeMonitoringRuntime
    ) async throws {
        do {
            try await eventually(step: step) {
                if let failure = await runtime.lastStreamFailure(for: scopeID) {
                    throw APFSDiskImageFixtureError.runtimeFailed(failure)
                }
                return try await repository.dirtyRegions(for: streamID)
                    .contains { $0.reasons.contains(.created) }
            }
        } catch {
            let dirty = try? await repository.dirtyRegions(for: streamID)
            throw APFSDiskImageFixtureError.fseventEvidenceFailed(
                cause: String(reflecting: error),
                dirtyRegions: String(reflecting: dirty),
                streamFailure: String(reflecting: await runtime.lastStreamFailure(for: scopeID))
            )
        }
    }
}

private func scanHistoricalEvidence(
    root: URL,
    scanner: FoundationMetadataCalibrationScanner,
    cursor: UInt64
) async throws -> HistoricalCalibrationScanEvidence {
    let path = try DirtyRegionPath(root.standardizedFileURL.path)
    let request = CalibrationRequest(
        streamID: try EventStreamID("apfs-identity-scan"),
        workItem: DirtyRegionWorkItem(
            region: try DirtyRegion(
                path: path,
                reasons: [.requiresCalibration],
                maximumCursor: EventJournalCursor(cursor)
            ),
            revision: try DirtyRegionRevision(cursor)
        )
    )
    let result = try await scanner.scanHistorical(request) { _ in }
    #expect(result.report.coverage == .complete)
    return try #require(result.evidence)
}

private actor RuntimeFailureRecorder {
    private var recordedFailure: String?

    func record(_ failure: String) {
        recordedFailure = failure
    }

    func failure() -> String? {
        recordedFailure
    }
}

private final class APFSDiskImageFixture {
    struct MountedVolume {
        let volumeUUID: UUID
        let volumeName: String
    }

    let root: URL
    let mountPoint: URL
    let watchedRoot: URL
    let databaseURL: URL
    private let firstImage: URL
    private let secondImage: URL
    private let temporaryRoot: URL
    private var mountedDevice: String?

    init() throws {
        let fileManager = FileManager.default
        let temporaryRoot = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .standardizedFileURL
        let root = temporaryRoot
            .appendingPathComponent("SpaceTraceAPFSImageTests-\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        guard Self.isSafe(root, within: temporaryRoot) else {
            throw APFSDiskImageFixtureError.unsafeFixturePath
        }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: false)
        let mountPoint = root.appendingPathComponent("Mount", isDirectory: true)
        try fileManager.createDirectory(at: mountPoint, withIntermediateDirectories: false)

        self.root = root
        self.mountPoint = mountPoint
        self.watchedRoot = mountPoint.appendingPathComponent("Watched", isDirectory: true)
        self.databaseURL = root.appendingPathComponent("journal.sqlite", isDirectory: false)
        self.firstImage = root.appendingPathComponent("first.dmg", isDirectory: false)
        self.secondImage = root.appendingPathComponent("second.dmg", isDirectory: false)
        self.temporaryRoot = temporaryRoot
    }

    func prepareImages() throws {
        try createImage(at: firstImage)
        try createImage(at: secondImage)
        for image in [firstImage, secondImage] {
            _ = try attach(image)
            try FileManager.default.createDirectory(
                at: watchedRoot,
                withIntermediateDirectories: false
            )
            try detachMountedImage()
        }
    }

    func attachFirstImage() throws -> MountedVolume { try attach(firstImage) }
    func attachSecondImage() throws -> MountedVolume { try attach(secondImage) }

    func createFile(named name: String) throws -> URL {
        guard name.isEmpty == false,
              name.contains("/") == false,
              name != ".",
              name != ".." else {
            throw APFSDiskImageFixtureError.invalidFileName
        }
        let target = watchedRoot.appendingPathComponent(name, isDirectory: false)
        guard FileManager.default.createFile(
            atPath: target.path,
            contents: Data([0x53, 0x54])
        ) else {
            throw APFSDiskImageFixtureError.fileCreationFailed
        }
        return target
    }

    func detachMountedImage() throws {
        guard let mountedDevice else { return }
        guard Self.isSafeDevice(mountedDevice) else {
            throw APFSDiskImageFixtureError.unsafeDeviceIdentifier
        }
        _ = try Self.run("/usr/bin/hdiutil", ["detach", mountedDevice])
        self.mountedDevice = nil
    }

    func remove() {
        if let mountedDevice, Self.isSafeDevice(mountedDevice) {
            if (try? Self.run("/usr/bin/hdiutil", ["detach", mountedDevice])) == nil {
                _ = try? Self.run("/usr/bin/hdiutil", ["detach", mountedDevice, "-force"])
            }
            self.mountedDevice = nil
        }
        guard Self.isSafe(root, within: temporaryRoot) else { return }
        try? FileManager.default.removeItem(at: root)
    }

    private func createImage(at url: URL) throws {
        guard Self.isSafe(url, within: root), url.pathExtension == "dmg" else {
            throw APFSDiskImageFixtureError.unsafeFixturePath
        }
        _ = try Self.run(
            "/usr/bin/hdiutil",
            [
                "create",
                "-size", "64m",
                "-fs", "APFS",
                "-volname", "SpaceTraceQualification",
                "-ov",
                url.path,
            ]
        )
    }

    private func attach(_ image: URL) throws -> MountedVolume {
        guard mountedDevice == nil,
              Self.isSafe(image, within: root),
              Self.isSafe(mountPoint, within: root) else {
            throw APFSDiskImageFixtureError.unsafeFixturePath
        }
        let output = try Self.run(
            "/usr/bin/hdiutil",
            [
                "attach", image.path,
                "-mountpoint", mountPoint.path,
                "-nobrowse",
                "-noautoopen",
                "-plist",
            ]
        )
        let plist = try PropertyListSerialization.propertyList(from: output, format: nil)
        guard let root = plist as? [String: Any],
              let entities = root["system-entities"] as? [[String: Any]],
              let mounted = entities.first(where: {
                  guard let returnedPath = $0["mount-point"] as? String else { return false }
                  return URL(fileURLWithPath: returnedPath).standardizedFileURL.path
                      == mountPoint.standardizedFileURL.path
              }),
              let device = mounted["dev-entry"] as? String,
              Self.isSafeDevice(device) else {
            throw APFSDiskImageFixtureError.invalidAttachResponse(
                expectedMountPath: mountPoint.path,
                propertyList: String(describing: plist)
            )
        }
        mountedDevice = device

        var currentMountURL = URL(
            fileURLWithPath: mountPoint.path,
            isDirectory: true
        )
        currentMountURL.removeAllCachedResourceValues()
        let values = try currentMountURL.resourceValues(
            forKeys: [.volumeUUIDStringKey, .volumeNameKey]
        )
        guard let uuidText = values.volumeUUIDString,
              let volumeUUID = UUID(uuidString: uuidText),
              let volumeName = values.volumeName else {
            throw APFSDiskImageFixtureError.missingVolumeEvidence
        }
        return MountedVolume(volumeUUID: volumeUUID, volumeName: volumeName)
    }

    private static func run(_ executable: String, _ arguments: [String]) throws -> Data {
        let output = Pipe()
        let error = Pipe()
        var fileActions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&fileActions) == 0 else {
            throw APFSDiskImageFixtureError.commandFailed(
                executable: executable,
                status: -1,
                message: "spawn actions unavailable"
            )
        }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        guard posix_spawn_file_actions_adddup2(
            &fileActions,
            output.fileHandleForWriting.fileDescriptor,
            STDOUT_FILENO
        ) == 0,
        posix_spawn_file_actions_adddup2(
            &fileActions,
            error.fileHandleForWriting.fileDescriptor,
            STDERR_FILENO
        ) == 0 else {
            throw APFSDiskImageFixtureError.commandFailed(
                executable: executable,
                status: -1,
                message: "spawn output unavailable"
            )
        }

        var argumentPointers: [UnsafeMutablePointer<CChar>?] =
            ([executable] + arguments).map { strdup($0) }
        argumentPointers.append(nil)
        defer {
            for case let pointer? in argumentPointers { free(pointer) }
        }
        var processID: pid_t = 0
        let spawnStatus = executable.withCString { executablePointer in
            argumentPointers.withUnsafeMutableBufferPointer { buffer in
                posix_spawn(
                    &processID,
                    executablePointer,
                    &fileActions,
                    nil,
                    buffer.baseAddress,
                    environ
                )
            }
        }
        output.fileHandleForWriting.closeFile()
        error.fileHandleForWriting.closeFile()
        guard spawnStatus == 0 else {
            throw APFSDiskImageFixtureError.commandFailed(
                executable: executable,
                status: Int32(spawnStatus),
                message: "spawn failed"
            )
        }
        var waitStatus: Int32 = 0
        guard waitpid(processID, &waitStatus, 0) == processID else {
            throw APFSDiskImageFixtureError.commandFailed(
                executable: executable,
                status: -1,
                message: "wait failed"
            )
        }
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        let terminationStatus = (waitStatus >> 8) & 0xff
        guard waitStatus & 0x7f == 0, terminationStatus == 0 else {
            throw APFSDiskImageFixtureError.commandFailed(
                executable: executable,
                status: terminationStatus,
                message: String(decoding: errorData, as: UTF8.self)
            )
        }
        return outputData
    }

    private static func isSafe(_ candidate: URL, within root: URL) -> Bool {
        let candidatePath = candidate.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return candidatePath != "/"
            && candidatePath != rootPath
            && candidatePath.hasPrefix(rootPath + "/")
    }

    private static func isSafeDevice(_ device: String) -> Bool {
        guard device.hasPrefix("/dev/disk") else { return false }
        let suffix = device.dropFirst("/dev/disk".count)
        guard suffix.isEmpty == false, suffix.first?.isNumber == true else { return false }
        return suffix.allSatisfy {
            $0.isNumber || $0 == "s"
        }
    }
}

private func eventually(
    step: String,
    timeout: Duration = .seconds(15),
    pollInterval: Duration = .milliseconds(50),
    condition: @escaping @Sendable () async throws -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if try await condition() { return }
        try await Task.sleep(for: pollInterval)
    }
    throw APFSDiskImageFixtureError.timedOut(step: step)
}

private func eventuallyValue<Value: Sendable>(
    step: String,
    timeout: Duration = .seconds(15),
    pollInterval: Duration = .milliseconds(50),
    value: @escaping @Sendable () async throws -> Value?
) async throws -> Value {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if let value = try await value() { return value }
        try await Task.sleep(for: pollInterval)
    }
    throw APFSDiskImageFixtureError.timedOut(step: step)
}

private enum APFSDiskImageFixtureError: Error, Sendable {
    case unsafeFixturePath
    case unsafeDeviceIdentifier
    case invalidFileName
    case fileCreationFailed
    case invalidAttachResponse(expectedMountPath: String, propertyList: String)
    case missingVolumeEvidence
    case commandFailed(executable: String, status: Int32, message: String)
    case runtimeFailed(String)
    case fseventEvidenceFailed(cause: String, dirtyRegions: String, streamFailure: String)
    case activationFailed(
        cause: String,
        lastSignal: String,
        storedGeneration: String,
        activeStatus: String,
        streamFailure: String,
        monitoringResult: String,
        configuredMountPath: String
    )
    case timedOut(step: String)
}
