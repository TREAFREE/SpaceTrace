/// A non-negative byte measurement that is safe to persist in a signed
/// 64-bit SQLite integer.
public struct ByteCount: Sendable, Equatable, Hashable, Comparable, Codable {
    public static let zero = ByteCount(uncheckedValue: 0)

    public let value: Int64

    public init(_ value: Int64) throws(ByteCountError) {
        guard value >= 0 else {
            throw .negativeValue(value)
        }

        self.value = value
    }

    public init(unsignedValue: UInt64) throws(ByteCountError) {
        guard unsignedValue <= UInt64(Int64.max) else {
            throw .valueExceedsStorageLimit(unsignedValue)
        }

        self.value = Int64(unsignedValue)
    }

    public func adding(_ other: ByteCount) throws(ByteCountError) -> ByteCount {
        let (sum, overflowed) = value.addingReportingOverflow(other.value)

        guard overflowed == false else {
            throw .additionOverflow(lhs: value, rhs: other.value)
        }

        return ByteCount(uncheckedValue: sum)
    }

    public func subtracting(_ other: ByteCount) throws(ByteCountError) -> ByteCount {
        guard value >= other.value else {
            throw .subtractionUnderflow(lhs: value, rhs: other.value)
        }

        return ByteCount(uncheckedValue: value - other.value)
    }

    public static func < (lhs: ByteCount, rhs: ByteCount) -> Bool {
        lhs.value < rhs.value
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let decodedValue = try container.decode(Int64.self)

        do {
            try self.init(decodedValue)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "ByteCount must be a non-negative signed 64-bit integer."
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    private init(uncheckedValue: Int64) {
        value = uncheckedValue
    }
}

public enum ByteCountError: Error, Sendable, Equatable {
    case negativeValue(Int64)
    case valueExceedsStorageLimit(UInt64)
    case additionOverflow(lhs: Int64, rhs: Int64)
    case subtractionUnderflow(lhs: Int64, rhs: Int64)
}
