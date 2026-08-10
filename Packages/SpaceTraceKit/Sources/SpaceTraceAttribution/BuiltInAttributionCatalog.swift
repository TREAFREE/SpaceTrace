import SpaceTraceDomain

public enum BuiltInAttributionCatalog {
    public static func version1() throws -> AttributionRuleCatalog {
        let catalogVersion = try AttributionCatalogVersion(1)
        let ruleVersion = try AttributionRuleVersion(1)
        return try AttributionRuleCatalog(
            version: catalogVersion,
            rules: [
                try pathRule("developer.xcode.derived-data", ruleVersion, .developerTools, .high, "home.library.developer.xcode.derived-data", ["Library", "Developer", "Xcode", "DerivedData"]),
                try pathRule("developer.xcode.simulator", ruleVersion, .developerTools, .high, "home.library.developer.core-simulator", ["Library", "Developer", "CoreSimulator"]),
                try pathRule("developer.xcode.cache", ruleVersion, .developerTools, .high, "home.library.caches.xcode", ["Library", "Caches", "com.apple.dt.Xcode"]),

                try pathRule("virtualization.docker.container", ruleVersion, .virtualization, .high, "home.library.containers.docker", ["Library", "Containers", "com.docker.docker"]),
                try pathRule("virtualization.docker.group", ruleVersion, .virtualization, .high, "home.library.group-containers.docker", ["Library", "Group Containers", "group.com.docker"]),
                try pathRule("virtualization.utm", ruleVersion, .virtualization, .high, "home.library.application-support.utm", ["Library", "Application Support", "UTM"]),

                try pathRule("ai.ollama.models", ruleVersion, .aiModelsAndCaches, .high, "home.ollama.models", [".ollama", "models"]),
                try pathRule("ai.huggingface.cache", ruleVersion, .aiModelsAndCaches, .high, "home.cache.huggingface", [".cache", "huggingface"]),
                try pathRule("ai.lm-studio.models", ruleVersion, .aiModelsAndCaches, .high, "home.library.application-support.lm-studio.models", ["Library", "Application Support", "LM Studio", "models"]),

                try pathRule("creative.adobe.cache", ruleVersion, .creativeCachesAndRenderData, .high, "home.library.caches.adobe", ["Library", "Caches", "Adobe"]),
                try pathRule("creative.adobe.media-cache", ruleVersion, .creativeCachesAndRenderData, .high, "home.library.application-support.adobe.media-cache", ["Library", "Application Support", "Adobe", "Common", "Media Cache Files"]),
                try pathRule("creative.davinci.cache-clip", ruleVersion, .creativeCachesAndRenderData, .high, "home.library.application-support.davinci.cache-clip", ["Library", "Application Support", "Blackmagic Design", "DaVinci Resolve", "CacheClip"]),

                try pathRule("games.steam.steamapps", ruleVersion, .games, .high, "home.library.application-support.steam.steamapps", ["Library", "Application Support", "Steam", "steamapps"]),
                try pathRule("games.epic", ruleVersion, .games, .high, "home.library.application-support.epic", ["Library", "Application Support", "Epic"]),
                try pathRule("games.blizzard", ruleVersion, .games, .high, "home.library.application-support.blizzard", ["Library", "Application Support", "Blizzard"]),

                try pathRule("cloud.mobile-documents", ruleVersion, .cloudLocalData, .high, "home.library.mobile-documents", ["Library", "Mobile Documents"]),
                try pathRule("cloud.storage-providers", ruleVersion, .cloudLocalData, .high, "home.library.cloud-storage", ["Library", "CloudStorage"]),
                try pathRule("cloud.apple-cloud-docs", ruleVersion, .cloudLocalData, .medium, "home.library.application-support.cloud-docs", ["Library", "Application Support", "CloudDocs"]),

                try pathRule("generic.user-caches", ruleVersion, .logsAndCaches, .medium, "home.library.caches", ["Library", "Caches"], priority: 0),
                try pathRule("generic.user-logs", ruleVersion, .logsAndCaches, .medium, "home.library.logs", ["Library", "Logs"], priority: 0),
                try absolutePathRule("generic.system-caches", ruleVersion, .logsAndCaches, .medium, "absolute.library.caches", ["Library", "Caches"], priority: 0),
                try absolutePathRule("generic.system-logs", ruleVersion, .logsAndCaches, .medium, "absolute.library.logs", ["Library", "Logs"], priority: 0),

                try contextRule("snapshot.apfs.local", ruleVersion, "context.snapshot.apfs-local", .localAPFSSnapshot),
                try contextRule("snapshot.time-machine.local", ruleVersion, "context.snapshot.time-machine-local", .timeMachineLocalSnapshot),
            ]
        )
    }

    private static func pathRule(
        _ id: String,
        _ version: AttributionRuleVersion,
        _ category: StorageAttributionCategory,
        _ confidence: AttributionConfidence,
        _ evidence: String,
        _ components: [String],
        priority: Int = 100
    ) throws -> AttributionRule {
        try AttributionRule(
            id: AttributionRuleID(id),
            version: version,
            category: category,
            confidence: confidence,
            evidenceCode: AttributionEvidenceCode(evidence),
            priority: priority,
            matcher: AttributionRuleMatcher(homeRelativePrefix: components)
        )
    }

    private static func absolutePathRule(
        _ id: String,
        _ version: AttributionRuleVersion,
        _ category: StorageAttributionCategory,
        _ confidence: AttributionConfidence,
        _ evidence: String,
        _ components: [String],
        priority: Int
    ) throws -> AttributionRule {
        try AttributionRule(
            id: AttributionRuleID(id),
            version: version,
            category: category,
            confidence: confidence,
            evidenceCode: AttributionEvidenceCode(evidence),
            priority: priority,
            matcher: AttributionRuleMatcher(absolutePrefix: components)
        )
    }

    private static func contextRule(
        _ id: String,
        _ version: AttributionRuleVersion,
        _ evidence: String,
        _ observation: SnapshotFactorObservation
    ) throws -> AttributionRule {
        try AttributionRule(
            id: AttributionRuleID(id),
            version: version,
            category: .snapshotFactors,
            confidence: .high,
            evidenceCode: AttributionEvidenceCode(evidence),
            priority: 100,
            matcher: AttributionRuleMatcher(snapshotFactorObservation: observation)
        )
    }
}
