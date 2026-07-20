// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SpaceTraceKit",
    platforms: [
        .macOS("15.6"),
    ],
    products: [
        .library(
            name: "SpaceTraceKit",
            targets: [
                "SpaceTraceDomain",
                "SpaceTraceApplication",
                "SpaceTraceFileSystem",
                "SpaceTracePersistence",
                "SpaceTracePlatform",
                "SpaceTraceMonitoring",
            ]
        ),
    ],
    targets: [
        .target(name: "SpaceTraceDomain"),
        .target(
            name: "SpaceTraceApplication",
            dependencies: ["SpaceTraceDomain"]
        ),
        .target(
            name: "SpaceTraceFileSystem",
            dependencies: [
                "SpaceTraceApplication",
                "SpaceTraceDomain",
            ]
        ),
        .target(
            name: "SpaceTracePersistence",
            dependencies: [
                "SpaceTraceApplication",
                "SpaceTraceDomain",
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .target(
            name: "SpaceTracePlatform",
            dependencies: [
                "SpaceTraceApplication",
                "SpaceTraceDomain",
            ],
            linkerSettings: [
                .linkedFramework("DiskArbitration"),
            ]
        ),
        .target(
            name: "SpaceTraceMonitoring",
            dependencies: [
                "SpaceTraceApplication",
                "SpaceTraceFileSystem",
                "SpaceTracePlatform",
            ]
        ),
        .testTarget(
            name: "SpaceTraceDomainTests",
            dependencies: ["SpaceTraceDomain"]
        ),
        .testTarget(
            name: "SpaceTraceApplicationTests",
            dependencies: [
                "SpaceTraceApplication",
                "SpaceTraceDomain",
            ]
        ),
        .testTarget(
            name: "SpaceTraceFileSystemTests",
            dependencies: ["SpaceTraceFileSystem"]
        ),
        .testTarget(
            name: "SpaceTracePersistenceTests",
            dependencies: [
                "SpaceTraceApplication",
                "SpaceTraceDomain",
                "SpaceTraceFileSystem",
                "SpaceTracePersistence",
            ]
        ),
        .testTarget(
            name: "SpaceTracePlatformTests",
            dependencies: ["SpaceTracePlatform"]
        ),
        .testTarget(
            name: "SpaceTraceMonitoringTests",
            dependencies: [
                "SpaceTraceApplication",
                "SpaceTraceFileSystem",
                "SpaceTraceMonitoring",
                "SpaceTracePersistence",
                "SpaceTracePlatform",
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
