import SpaceTraceDomain

public enum AttributionExpectedUnknownReason: Sendable, Equatable, Hashable {
    case noMatchingRule
    case ambiguous
}

public enum AttributionEvaluationExpectation: Sendable, Equatable, Hashable {
    case classified(StorageAttributionCategory)
    case unknown(AttributionExpectedUnknownReason)
}

public struct AttributionEvaluationCase: Sendable, Equatable, Hashable {
    public let id: String
    public let input: AttributionInput
    public let expected: AttributionEvaluationExpectation

    public init(
        id: String,
        input: AttributionInput,
        expected: AttributionEvaluationExpectation
    ) {
        self.id = id
        self.input = input
        self.expected = expected
    }
}

public struct KnownAttributionMetrics: Sendable, Equatable {
    public let expected: Int
    public let predicted: Int
    public let correct: Int

    public var precision: Double? {
        guard predicted > 0 else { return nil }
        return Double(correct) / Double(predicted)
    }

    public var recall: Double? {
        guard expected > 0 else { return nil }
        return Double(correct) / Double(expected)
    }
}

public struct UnknownAttributionMetrics: Sendable, Equatable {
    public let total: Int
    public let correct: Int

    public var accuracy: Double? {
        guard total > 0 else { return nil }
        return Double(correct) / Double(total)
    }
}

public struct AttributionEvaluationReport: Sendable, Equatable {
    public let known: KnownAttributionMetrics
    public let knownByCategory: [StorageAttributionCategory: KnownAttributionMetrics]
    public let unknown: UnknownAttributionMetrics
}

public struct AttributionFixtureEvaluator: Sendable {
    public init() {}

    public func evaluate(
        _ cases: [AttributionEvaluationCase],
        with classifier: DeterministicAttributionClassifier
    ) -> AttributionEvaluationReport {
        var knownExpected = 0
        var knownPredicted = 0
        var knownCorrect = 0
        var categoryCounts: [StorageAttributionCategory: (expected: Int, predicted: Int, correct: Int)] = [:]
        var unknownTotal = 0
        var unknownCorrect = 0

        for evaluationCase in cases {
            let actual = classifier.classify(evaluationCase.input)
            if case .classified(let attribution) = actual {
                knownPredicted += 1
                var counts = categoryCounts[attribution.category, default: (0, 0, 0)]
                counts.predicted += 1
                categoryCounts[attribution.category] = counts
            }

            switch evaluationCase.expected {
            case .classified(let expectedCategory):
                knownExpected += 1
                var counts = categoryCounts[expectedCategory, default: (0, 0, 0)]
                counts.expected += 1
                if case .classified(let attribution) = actual,
                   attribution.category == expectedCategory {
                    knownCorrect += 1
                    counts.correct += 1
                }
                categoryCounts[expectedCategory] = counts

            case .unknown(let expectedReason):
                unknownTotal += 1
                if Self.matches(expectedReason, actual: actual) {
                    unknownCorrect += 1
                }
            }
        }

        let perCategory = categoryCounts.mapValues {
            KnownAttributionMetrics(
                expected: $0.expected,
                predicted: $0.predicted,
                correct: $0.correct
            )
        }
        return AttributionEvaluationReport(
            known: KnownAttributionMetrics(
                expected: knownExpected,
                predicted: knownPredicted,
                correct: knownCorrect
            ),
            knownByCategory: perCategory,
            unknown: UnknownAttributionMetrics(total: unknownTotal, correct: unknownCorrect)
        )
    }

    private static func matches(
        _ expected: AttributionExpectedUnknownReason,
        actual: AttributionClassificationResult
    ) -> Bool {
        switch (expected, actual) {
        case (.noMatchingRule, .unknown(.noMatchingRule)):
            true
        case (.ambiguous, .unknown(.ambiguous)):
            true
        default:
            false
        }
    }
}
