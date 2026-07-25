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
        .executable(
            name: "SpaceTracePersistenceBenchmark",
            targets: ["SpaceTracePersistenceBenchmark"]
        ),
        .executable(
            name: "SpaceTraceSoakAnalyzer",
            targets: ["SpaceTraceSoakAnalyzer"]
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
        .executableTarget(
            name: "SpaceTracePersistenceBenchmark",
            dependencies: [
                "SpaceTraceApplication",
                "SpaceTracePersistence",
            ],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "SpaceTraceSoakAnalyzer",
            dependencies: ["SpaceTraceApplication"]
        ),
        .target(
            name: "SpaceTracePlatform",
            dependencies: [
                "SpaceTraceApplication",
                "SpaceTraceDomain",
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("DiskArbitration"),
                .linkedFramework("IOKit"),
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
            ],
            resources: [.copy("Fixtures")]
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
