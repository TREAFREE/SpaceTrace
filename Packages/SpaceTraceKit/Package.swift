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
            dependencies: ["SpaceTraceApplication"]
        ),
        .target(
            name: "SpaceTracePersistence",
            dependencies: ["SpaceTraceApplication"],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "SpaceTraceDomainTests",
            dependencies: ["SpaceTraceDomain"]
        ),
        .testTarget(
            name: "SpaceTraceApplicationTests",
            dependencies: ["SpaceTraceApplication"]
        ),
        .testTarget(
            name: "SpaceTraceFileSystemTests",
            dependencies: ["SpaceTraceFileSystem"]
        ),
        .testTarget(
            name: "SpaceTracePersistenceTests",
            dependencies: [
                "SpaceTraceApplication",
                "SpaceTracePersistence",
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
