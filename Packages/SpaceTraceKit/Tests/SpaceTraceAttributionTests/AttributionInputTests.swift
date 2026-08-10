import Testing
@testable import SpaceTraceAttribution

struct AttributionInputTests {
    @Test("Normalizes separators and dot components without filesystem access")
    func normalizesLexically() throws {
        let input = try AttributionInput(
            absolutePath: "/Users//alex/./Library/Caches/",
            homeDirectory: "/Users/alex"
        )

        #expect(input.absolutePathComponents == ["Users", "alex", "Library", "Caches"])
        #expect(input.homeRelativePathComponents == ["Library", "Caches"])
    }

    @Test("Home-relative features survive a renamed account")
    func survivesRenamedHome() throws {
        let original = try AttributionInput(
            absolutePath: "/Users/alex/Library/Developer/Xcode/DerivedData/App-a",
            homeDirectory: "/Users/alex"
        )
        let renamed = try AttributionInput(
            absolutePath: "/Users/renamed-account/Library/Developer/Xcode/DerivedData/App-a",
            homeDirectory: "/Users/renamed-account"
        )

        #expect(original.homeRelativePathComponents == renamed.homeRelativePathComponents)
    }

    @Test("Home matching uses complete path components")
    func usesComponentBoundaryForHome() throws {
        let input = try AttributionInput(
            absolutePath: "/Users/alex-archive/Library/Caches",
            homeDirectory: "/Users/alex"
        )

        #expect(input.homeRelativePathComponents == nil)
    }

    @Test("The home root itself has an empty relative path")
    func supportsHomeRoot() throws {
        let input = try AttributionInput(
            absolutePath: "/Users/alex/",
            homeDirectory: "/Users/alex"
        )

        #expect(input.homeRelativePathComponents == [])
    }

    @Test("Unicode path components are preserved exactly")
    func preservesUnicode() throws {
        let input = try AttributionInput(
            absolutePath: "/Users/测试/Library/Caches/绘图",
            homeDirectory: "/Users/测试"
        )

        #expect(input.homeRelativePathComponents == ["Library", "Caches", "绘图"])
    }

    @Test("Rejects relative paths", arguments: ["", ".", "Users/alex", "Library/Caches"])
    func rejectsRelativePaths(path: String) {
        #expect(throws: AttributionInputError.pathMustBeAbsolute) {
            try AttributionInput(absolutePath: path)
        }
    }

    @Test("Rejects parent traversal in either path", arguments: [
        PathPair(path: "/Users/alex/../shared", home: "/Users/alex"),
        PathPair(path: "/Users/alex/Library", home: "/Users/../alex"),
    ])
    func rejectsParentTraversal(pair: PathPair) {
        #expect(throws: AttributionInputError.parentTraversalNotAllowed) {
            try AttributionInput(absolutePath: pair.path, homeDirectory: pair.home)
        }
    }

    @Test("Rejects root as a home directory")
    func rejectsRootHome() {
        #expect(throws: AttributionInputError.invalidHomeDirectory) {
            try AttributionInput(absolutePath: "/Library/Caches", homeDirectory: "/")
        }
    }

    @Test("Rejects path-like or blank bundle identifiers", arguments: ["", " ", "com.example/app"])
    func rejectsInvalidBundleIdentifier(value: String) {
        #expect(throws: AttributionInputError.invalidBundleIdentifier) {
            try AttributionInput(absolutePath: "/Library/Caches", bundleIdentifier: value)
        }
    }

    @Test("Rejects a null byte in a path component")
    func rejectsNullByte() {
        #expect(throws: AttributionInputError.invalidPathComponent) {
            try AttributionInput(absolutePath: "/Users/alex/Library/Caches/bad\0name")
        }
    }

    @Test("Carries only explicit volume context")
    func carriesExplicitContext() throws {
        let input = try AttributionInput(
            absolutePath: "/.MobileBackups",
            volumeContext: .init(snapshotFactorObservation: .timeMachineLocalSnapshot)
        )

        #expect(input.volumeContext.snapshotFactorObservation == .timeMachineLocalSnapshot)
        #expect(input.bundleIdentifier == nil)
    }
}

struct PathPair: Sendable, CustomTestStringConvertible {
    let path: String
    let home: String

    var testDescription: String { "path=\(path), home=\(home)" }
}
