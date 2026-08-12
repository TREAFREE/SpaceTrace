import CryptoKit
import Foundation
import SpaceTraceDomain

public enum DiagnosticExportError: Error, Sendable, Equatable {
    case invalidMetadata
    case invalidPath
    case invalidHealthEvent
    case duplicateScopeID
    case duplicateFindingID
    case duplicateFindingSelection
    case unknownFindingSelection
    case tooManySelectedFindings
    case tooManyScopes
    case tooManyHealthEvents
    case rawPathAuthorizationMismatch
    case invalidRedactionSalt
    case encodedBundleTooLarge
}

public enum DiagnosticExportHealthSeverity: String, Sendable, Equatable, Codable {
    case notice
    case warning
    case error
}

public struct DiagnosticExportHealthEvent: Sendable, Equatable {
    public let code: String
    public let severity: DiagnosticExportHealthSeverity
    public let observedAt: ObservationInstant
    public let count: Int

    public init(
        code: String,
        severity: DiagnosticExportHealthSeverity,
        observedAt: ObservationInstant,
        count: Int
    ) throws {
        guard code.isEmpty == false,
              code.utf8.count <= 96,
              code.utf8.allSatisfy({ byte in
                  (byte >= 97 && byte <= 122)
                      || (byte >= 48 && byte <= 57)
                      || byte == 45
                      || byte == 46
                      || byte == 95
              }),
              (1...1_000_000).contains(count) else {
            throw DiagnosticExportError.invalidHealthEvent
        }
        self.code = code
        self.severity = severity
        self.observedAt = observedAt
        self.count = count
    }
}

public struct DiagnosticExportScopeSource: Sendable, Equatable {
    public let scopeID: WatchedScopeID
    public let rootPath: String
    public let availability: HistoricalPathHistoryAvailability
    public let findings: [HistoricalFindingOverviewItem]

    public init(
        scopeID: WatchedScopeID,
        rootPath: String,
        availability: HistoricalPathHistoryAvailability,
        findings: [HistoricalFindingOverviewItem]
    ) throws {
        guard Self.isValidAbsolutePath(rootPath) else {
            throw DiagnosticExportError.invalidPath
        }
        self.scopeID = scopeID
        self.rootPath = rootPath
        self.availability = availability
        self.findings = findings
    }

    private static func isValidAbsolutePath(_ path: String) -> Bool {
        path.first == "/"
            && path.utf8.count <= 4_096
            && path.utf8.contains(0) == false
            && path.split(separator: "/", omittingEmptySubsequences: true)
                .allSatisfy { $0 != "." && $0 != ".." }
    }
}

public struct DiagnosticExportSource: Sendable, Equatable {
    public static let maximumScopeCount = 16
    public static let maximumHealthEventCount = 1_000

    public let generatedAt: ObservationInstant
    public let appVersion: String
    public let osVersion: String
    public let architecture: String
    public let scopes: [DiagnosticExportScopeSource]
    public let healthEvents: [DiagnosticExportHealthEvent]

    public init(
        generatedAt: ObservationInstant,
        appVersion: String,
        osVersion: String,
        architecture: String,
        scopes: [DiagnosticExportScopeSource],
        healthEvents: [DiagnosticExportHealthEvent]
    ) throws {
        guard Self.isValidMetadata(appVersion, maximumBytes: 256),
              Self.isValidMetadata(osVersion, maximumBytes: 512),
              Self.isValidMetadata(architecture, maximumBytes: 64) else {
            throw DiagnosticExportError.invalidMetadata
        }
        guard scopes.count <= Self.maximumScopeCount else {
            throw DiagnosticExportError.tooManyScopes
        }
        guard healthEvents.count <= Self.maximumHealthEventCount else {
            throw DiagnosticExportError.tooManyHealthEvents
        }
        let scopeBytes = scopes.map { Data($0.scopeID.rawValue.utf8) }
        guard Set(scopeBytes).count == scopeBytes.count else {
            throw DiagnosticExportError.duplicateScopeID
        }
        let findingIDs = scopes.flatMap { $0.findings.map(\.id) }
        guard Set(findingIDs).count == findingIDs.count else {
            throw DiagnosticExportError.duplicateFindingID
        }
        self.generatedAt = generatedAt
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.architecture = architecture
        self.scopes = scopes
        self.healthEvents = healthEvents
    }

    private static func isValidMetadata(
        _ value: String,
        maximumBytes: Int
    ) -> Bool {
        value.isEmpty == false
            && value.utf8.count <= maximumBytes
            && value.utf8.contains(0) == false
    }
}

public struct DiagnosticRawPathAuthorization: Sendable, Equatable {
    public let exportID: UUID

    private init(exportID: UUID) {
        self.exportID = exportID
    }

    /// Must be called only after the user accepts the per-export raw-path
    /// warning. Binding consent to one UUID prevents reuse by a later export.
    public static func confirmed(for exportID: UUID) -> Self {
        Self(exportID: exportID)
    }
}

public enum DiagnosticExportPathMode: Sendable, Equatable {
    case redacted(homeDirectory: String?)
    case fullPaths(authorization: DiagnosticRawPathAuthorization)
}

public enum DiagnosticExportPreviewPathMode: String, Sendable, Equatable, Codable {
    case redacted
    case fullPaths = "full_paths"
}

public enum DiagnosticExportPreviewSectionKind: String, Sendable, Equatable, Codable {
    case system
    case coverage
    case healthEvents = "health_events"
    case selectedFindings = "selected_findings"
}

public struct DiagnosticExportPreviewSection: Sendable, Equatable {
    public let kind: DiagnosticExportPreviewSectionKind
    public let itemCount: Int

    public init(kind: DiagnosticExportPreviewSectionKind, itemCount: Int) {
        self.kind = kind
        self.itemCount = itemCount
    }
}

public struct DiagnosticExportPreview: Sendable, Equatable {
    public let exportID: UUID
    public let pathMode: DiagnosticExportPreviewPathMode
    public let sections: [DiagnosticExportPreviewSection]
    public let includesFileContents: Bool
    public let uploadsAutomatically: Bool
}

public struct PreparedDiagnosticExport: Sendable, Equatable {
    public static let maximumByteCount = 2 * 1_024 * 1_024

    public let preview: DiagnosticExportPreview
    public let data: Data
    public let suggestedFileName: String
}

public struct DiagnosticExportDocument: Sendable, Equatable, Codable {
    public let schemaVersion: Int
    public let generatedAtMilliseconds: Int64
    public let system: DiagnosticExportSystem
    public let privacy: DiagnosticExportPrivacy
    public let coverage: [DiagnosticExportCoverage]
    public let healthEvents: [DiagnosticExportHealthEventDocument]
    public let findings: [DiagnosticExportFinding]

    /// Deliberately never populated. Keeping this optional decoding seam makes
    /// tests prove that the export-specific secret is not disclosed.
    public let redactionSalt: String?
}

public struct DiagnosticExportSystem: Sendable, Equatable, Codable {
    public let appVersion: String
    public let osVersion: String
    public let architecture: String
}

public struct DiagnosticExportPrivacy: Sendable, Equatable, Codable {
    public let pathMode: DiagnosticExportPreviewPathMode
    public let includesFileContents: Bool
    public let uploadsAutomatically: Bool
}

public enum DiagnosticExportCoverageAvailability: String, Sendable, Equatable, Codable {
    case available
    case baselineUnavailable = "baseline_unavailable"
    case historyDisabled = "history_disabled"
}

public struct DiagnosticExportCoverage: Sendable, Equatable, Codable {
    public let scope: String
    public let rootPath: String
    public let availability: DiagnosticExportCoverageAvailability
}

public struct DiagnosticExportHealthEventDocument: Sendable, Equatable, Codable {
    public let code: String
    public let severity: DiagnosticExportHealthSeverity
    public let observedAtMilliseconds: Int64
    public let count: Int
}

public enum DiagnosticExportClassificationKind: String, Sendable, Equatable, Codable {
    case classified
    case unknownNoMatchingRule = "unknown_no_matching_rule"
    case unknownAmbiguous = "unknown_ambiguous"
}

public struct DiagnosticExportClassification: Sendable, Equatable, Codable {
    public let kind: DiagnosticExportClassificationKind
    public let category: StorageAttributionCategory?
    public let confidence: AttributionConfidence?
    public let ruleID: String?
    public let ruleVersion: Int?
    public let catalogVersion: Int
    public let evidenceCode: String?
    public let ambiguousRuleIDs: [String]?
}

public enum DiagnosticExportFindingValidityKind: String, Sendable, Equatable, Codable {
    case currentEffective = "current_effective"
    case evidenceInvalidated = "evidence_invalidated"
}

public struct DiagnosticExportFindingValidity: Sendable, Equatable, Codable {
    public let kind: DiagnosticExportFindingValidityKind
    public let invalidatedAtMilliseconds: Int64?
}

public struct DiagnosticExportFinding: Sendable, Equatable, Codable {
    public let finding: String
    public let scope: String
    public let kind: HistoricalFindingKind
    public let metric: StorageMetric
    public let inclusiveDeltaBytes: Int64
    public let rankingContributionBytes: Int64?
    public let positiveRank: Int?
    public let baselinePath: String
    public let comparisonPath: String
    public let baselineDisplayName: String
    public let comparisonDisplayName: String
    public let baselineTimeMilliseconds: Int64
    public let comparisonTimeMilliseconds: Int64
    public let classification: DiagnosticExportClassification
    public let validity: DiagnosticExportFindingValidity
}

public struct DiagnosticExportBuilder: Sendable {
    public static let maximumSelectedFindingCount = 100

    public init() {}

    public func preview(
        source: DiagnosticExportSource,
        exportID: UUID,
        selectedFindingIDs: [HistoricalFindingRecordID],
        pathMode: DiagnosticExportPathMode
    ) throws -> DiagnosticExportPreview {
        let selected = try validateSelection(
            source: source,
            selectedFindingIDs: selectedFindingIDs
        )
        return try makePreview(
            source: source,
            exportID: exportID,
            selectedCount: selected.count,
            pathMode: pathMode
        )
    }

    public func prepare(
        source: DiagnosticExportSource,
        exportID: UUID,
        selectedFindingIDs: [HistoricalFindingRecordID],
        pathMode: DiagnosticExportPathMode
    ) throws -> PreparedDiagnosticExport {
        try prepare(
            source: source,
            exportID: exportID,
            selectedFindingIDs: selectedFindingIDs,
            pathMode: pathMode,
            redactionSalt: nil
        )
    }

    func prepare(
        source: DiagnosticExportSource,
        exportID: UUID,
        selectedFindingIDs: [HistoricalFindingRecordID],
        pathMode: DiagnosticExportPathMode,
        redactionSalt: Data?
    ) throws -> PreparedDiagnosticExport {
        let selected = try validateSelection(
            source: source,
            selectedFindingIDs: selectedFindingIDs
        )
        let preview = try makePreview(
            source: source,
            exportID: exportID,
            selectedCount: selected.count,
            pathMode: pathMode
        )

        let sortedScopes = source.scopes.sorted {
            $0.scopeID.rawValue.utf8.lexicographicallyPrecedes(
                $1.scopeID.rawValue.utf8
            )
        }
        let scopeKeys = Dictionary(
            uniqueKeysWithValues: sortedScopes.enumerated().map { offset, scope in
                (scope.scopeID, String(format: "scope_%02d", offset + 1))
            }
        )
        let selectedIDs = Set(selectedFindingIDs)
        let pathProjector: DiagnosticPathProjector
        switch pathMode {
        case let .redacted(homeDirectory):
            let salt = redactionSalt ?? Self.randomSalt()
            guard salt.count == 32 else {
                throw DiagnosticExportError.invalidRedactionSalt
            }
            pathProjector = try .redacted(
                salt: salt,
                homeDirectory: homeDirectory,
                sortedScopes: sortedScopes,
                scopeKeys: scopeKeys
            )
        case .fullPaths:
            pathProjector = .fullPaths
        }

        let coverage = try sortedScopes.map { scope in
            DiagnosticExportCoverage(
                scope: scopeKeys[scope.scopeID]!,
                rootPath: try pathProjector.path(scope.rootPath),
                availability: Self.coverageAvailability(scope.availability)
            )
        }
        var selectedFindings: [(scope: DiagnosticExportScopeSource, item: HistoricalFindingOverviewItem)] = []
        for scope in sortedScopes {
            for item in scope.findings where selectedIDs.contains(item.id) {
                selectedFindings.append((scope, item))
            }
        }
        selectedFindings.sort { $0.item.id < $1.item.id }

        let findings = try selectedFindings.enumerated().map { offset, pair in
            try Self.findingDocument(
                pair.item,
                findingKey: String(format: "finding_%03d", offset + 1),
                scopeKey: scopeKeys[pair.scope.scopeID]!,
                pathProjector: pathProjector
            )
        }
        let healthEvents = source.healthEvents.sorted {
            if $0.observedAt != $1.observedAt {
                return $0.observedAt < $1.observedAt
            }
            return $0.code.utf8.lexicographicallyPrecedes($1.code.utf8)
        }.map {
            DiagnosticExportHealthEventDocument(
                code: $0.code,
                severity: $0.severity,
                observedAtMilliseconds: $0.observedAt.millisecondsSince1970,
                count: $0.count
            )
        }
        let document = DiagnosticExportDocument(
            schemaVersion: 1,
            generatedAtMilliseconds: source.generatedAt.millisecondsSince1970,
            system: DiagnosticExportSystem(
                appVersion: source.appVersion,
                osVersion: source.osVersion,
                architecture: source.architecture
            ),
            privacy: DiagnosticExportPrivacy(
                pathMode: preview.pathMode,
                includesFileContents: false,
                uploadsAutomatically: false
            ),
            coverage: coverage,
            healthEvents: healthEvents,
            findings: findings,
            redactionSalt: nil
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)
        guard data.count <= PreparedDiagnosticExport.maximumByteCount else {
            throw DiagnosticExportError.encodedBundleTooLarge
        }
        return PreparedDiagnosticExport(
            preview: preview,
            data: data,
            suggestedFileName: "SpaceTrace-Diagnostics-\(exportID.uuidString.lowercased()).json"
        )
    }

    private func validateSelection(
        source: DiagnosticExportSource,
        selectedFindingIDs: [HistoricalFindingRecordID]
    ) throws -> [HistoricalFindingRecordID] {
        guard selectedFindingIDs.count <= Self.maximumSelectedFindingCount else {
            throw DiagnosticExportError.tooManySelectedFindings
        }
        guard Set(selectedFindingIDs).count == selectedFindingIDs.count else {
            throw DiagnosticExportError.duplicateFindingSelection
        }
        let available = Set(source.scopes.flatMap { $0.findings.map(\.id) })
        guard selectedFindingIDs.allSatisfy(available.contains) else {
            throw DiagnosticExportError.unknownFindingSelection
        }
        return selectedFindingIDs
    }

    private func makePreview(
        source: DiagnosticExportSource,
        exportID: UUID,
        selectedCount: Int,
        pathMode: DiagnosticExportPathMode
    ) throws -> DiagnosticExportPreview {
        let previewMode: DiagnosticExportPreviewPathMode
        switch pathMode {
        case .redacted:
            previewMode = .redacted
        case let .fullPaths(authorization):
            guard authorization.exportID == exportID else {
                throw DiagnosticExportError.rawPathAuthorizationMismatch
            }
            previewMode = .fullPaths
        }
        return DiagnosticExportPreview(
            exportID: exportID,
            pathMode: previewMode,
            sections: [
                DiagnosticExportPreviewSection(kind: .system, itemCount: 1),
                DiagnosticExportPreviewSection(
                    kind: .coverage,
                    itemCount: source.scopes.count
                ),
                DiagnosticExportPreviewSection(
                    kind: .healthEvents,
                    itemCount: source.healthEvents.count
                ),
                DiagnosticExportPreviewSection(
                    kind: .selectedFindings,
                    itemCount: selectedCount
                ),
            ],
            includesFileContents: false,
            uploadsAutomatically: false
        )
    }

    private static func randomSalt() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in
            UInt8.random(in: UInt8.min...UInt8.max, using: &generator)
        })
    }

    private static func coverageAvailability(
        _ availability: HistoricalPathHistoryAvailability
    ) -> DiagnosticExportCoverageAvailability {
        switch availability {
        case .available: .available
        case .baselineUnavailable: .baselineUnavailable
        case .historyDisabled: .historyDisabled
        }
    }

    private static func findingDocument(
        _ item: HistoricalFindingOverviewItem,
        findingKey: String,
        scopeKey: String,
        pathProjector: DiagnosticPathProjector
    ) throws -> DiagnosticExportFinding {
        let validity: DiagnosticExportFindingValidity
        switch item.validity {
        case .currentEffective:
            validity = DiagnosticExportFindingValidity(
                kind: .currentEffective,
                invalidatedAtMilliseconds: nil
            )
        case let .evidenceInvalidated(at):
            validity = DiagnosticExportFindingValidity(
                kind: .evidenceInvalidated,
                invalidatedAtMilliseconds: at.millisecondsSince1970
            )
        }
        return DiagnosticExportFinding(
            finding: findingKey,
            scope: scopeKey,
            kind: item.kind,
            metric: item.metric,
            inclusiveDeltaBytes: item.inclusiveDeltaBytes,
            rankingContributionBytes: item.rankingContributionBytes,
            positiveRank: item.positiveRank,
            baselinePath: try pathProjector.path(item.baselinePath),
            comparisonPath: try pathProjector.path(item.comparisonPath),
            baselineDisplayName: pathProjector.displayName(item.baselineDisplayName),
            comparisonDisplayName: pathProjector.displayName(item.comparisonDisplayName),
            baselineTimeMilliseconds: item.baselineTime.millisecondsSince1970,
            comparisonTimeMilliseconds: item.comparisonTime.millisecondsSince1970,
            classification: classificationDocument(item.classification),
            validity: validity
        )
    }

    private static func classificationDocument(
        _ classification: HistoricalFindingOverviewClassification
    ) -> DiagnosticExportClassification {
        switch classification {
        case let .classified(
            category,
            confidence,
            ruleID,
            ruleVersion,
            catalogVersion,
            evidenceCode
        ):
            DiagnosticExportClassification(
                kind: .classified,
                category: category,
                confidence: confidence,
                ruleID: ruleID.rawValue,
                ruleVersion: ruleVersion.rawValue,
                catalogVersion: catalogVersion.rawValue,
                evidenceCode: evidenceCode.rawValue,
                ambiguousRuleIDs: nil
            )
        case let .unknownNoMatchingRule(catalogVersion):
            DiagnosticExportClassification(
                kind: .unknownNoMatchingRule,
                category: nil,
                confidence: nil,
                ruleID: nil,
                ruleVersion: nil,
                catalogVersion: catalogVersion.rawValue,
                evidenceCode: nil,
                ambiguousRuleIDs: nil
            )
        case let .unknownAmbiguous(catalogVersion, ruleIDs):
            DiagnosticExportClassification(
                kind: .unknownAmbiguous,
                category: nil,
                confidence: nil,
                ruleID: nil,
                ruleVersion: nil,
                catalogVersion: catalogVersion.rawValue,
                evidenceCode: nil,
                ambiguousRuleIDs: ruleIDs.map(\.rawValue)
            )
        }
    }
}

private enum DiagnosticPathProjector: Sendable {
    case fullPaths
    case redacted(DiagnosticPathRedactor)

    static func redacted(
        salt: Data,
        homeDirectory: String?,
        sortedScopes: [DiagnosticExportScopeSource],
        scopeKeys: [WatchedScopeID: String]
    ) throws -> Self {
        let roots = sortedScopes.compactMap { scope -> DiagnosticPathRedactor.Root? in
            guard let key = scopeKeys[scope.scopeID] else { return nil }
            return DiagnosticPathRedactor.Root(
                path: scope.rootPath,
                replacement: "$\(key.uppercased())"
            )
        }
        return .redacted(
            try DiagnosticPathRedactor(
                salt: salt,
                homeDirectory: homeDirectory,
                roots: roots
            )
        )
    }

    func path(_ path: String) throws -> String {
        switch self {
        case .fullPaths: path
        case let .redacted(redactor): try redactor.redact(path)
        }
    }

    func displayName(_ displayName: String) -> String {
        switch self {
        case .fullPaths: displayName
        case let .redacted(redactor): redactor.token(for: displayName)
        }
    }
}

private struct DiagnosticPathRedactor: Sendable {
    struct Root: Sendable {
        let path: String
        let replacement: String
    }

    private struct ParsedRoot: Sendable {
        let components: [String]
        let replacement: String
    }

    private let salt: Data
    private let home: ParsedRoot?
    private let roots: [ParsedRoot]

    init(salt: Data, homeDirectory: String?, roots: [Root]) throws {
        guard salt.count == 32 else {
            throw DiagnosticExportError.invalidRedactionSalt
        }
        self.salt = salt
        if let homeDirectory {
            self.home = ParsedRoot(
                components: try Self.components(homeDirectory),
                replacement: "$HOME"
            )
        } else {
            self.home = nil
        }
        self.roots = try roots.map {
            ParsedRoot(
                components: try Self.components($0.path),
                replacement: $0.replacement
            )
        }.sorted { $0.components.count > $1.components.count }
    }

    func redact(_ path: String) throws -> String {
        let pathComponents = try Self.components(path)
        if let home, pathComponents.starts(with: home.components) {
            return projected(
                pathComponents,
                below: home.components,
                replacement: home.replacement
            )
        }
        if let root = roots.first(where: {
            pathComponents.starts(with: $0.components)
        }) {
            return projected(
                pathComponents,
                below: root.components,
                replacement: root.replacement
            )
        }
        let tokens = pathComponents.map(token)
        return (["$ABS"] + tokens).joined(separator: "/")
    }

    func token(for component: String) -> String {
        var payload = salt
        payload.append(0)
        var count = UInt64(component.utf8.count).bigEndian
        withUnsafeBytes(of: &count) { payload.append(contentsOf: $0) }
        payload.append(contentsOf: component.utf8)
        let digest = SHA256.hash(data: payload)
        return "p_" + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private func projected(
        _ pathComponents: [String],
        below rootComponents: [String],
        replacement: String
    ) -> String {
        let suffix = pathComponents.dropFirst(rootComponents.count).map(token)
        return ([replacement] + suffix).joined(separator: "/")
    }

    private static func components(_ path: String) throws -> [String] {
        guard path.first == "/",
              path.utf8.count <= 4_096,
              path.utf8.contains(0) == false else {
            throw DiagnosticExportError.invalidPath
        }
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: true
        ).map(String.init)
        guard components.allSatisfy({ $0 != "." && $0 != ".." }) else {
            throw DiagnosticExportError.invalidPath
        }
        return components
    }
}
