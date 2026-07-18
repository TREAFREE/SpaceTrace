public struct ScopeID: Sendable, Equatable, Hashable, Codable {
    public let rawValue: String

    public init(_ rawValue: String) throws(ObservationIdentityError) {
        guard rawValue.allSatisfy(\.isWhitespace) == false else {
            throw .emptyScopeID
        }

        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)

        do {
            try self.init(rawValue)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "ScopeID must contain at least one non-whitespace character."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct SubjectID: Sendable, Equatable, Hashable, Codable {
    public let rawValue: String

    public init(_ rawValue: String) throws(ObservationIdentityError) {
        guard rawValue.allSatisfy(\.isWhitespace) == false else {
            throw .emptySubjectID
        }

        self.rawValue = rawValue
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)

        do {
            try self.init(rawValue)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "SubjectID must contain at least one non-whitespace character."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum ObservationIdentityError: Error, Sendable, Equatable {
    case emptyScopeID
    case emptySubjectID
}

/// UTC Unix time expressed as milliseconds, matching SpaceTrace's durable
/// observation contract without introducing a Foundation dependency.
public struct ObservationInstant: Sendable, Equatable, Hashable, Comparable, Codable {
    public let millisecondsSince1970: Int64

    public init(millisecondsSince1970: Int64) throws(ObservationInstantError) {
        guard millisecondsSince1970 >= 0 else {
            throw .beforeUnixEpoch(millisecondsSince1970)
        }

        self.millisecondsSince1970 = millisecondsSince1970
    }

    public static func < (lhs: ObservationInstant, rhs: ObservationInstant) -> Bool {
        lhs.millisecondsSince1970 < rhs.millisecondsSince1970
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let milliseconds = try container.decode(Int64.self)

        do {
            try self.init(millisecondsSince1970: milliseconds)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "ObservationInstant cannot be before the Unix epoch."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(millisecondsSince1970)
    }
}

public enum ObservationInstantError: Error, Sendable, Equatable {
    case beforeUnixEpoch(Int64)
}
