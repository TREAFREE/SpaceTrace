import Testing
@testable import SpaceTraceDomain

struct ByteCountTests {
    @Test("Accepts the supported signed boundaries", arguments: [Int64(0), 1, Int64.max])
    func acceptsSupportedBoundaries(value: Int64) throws {
        let count = try ByteCount(value)

        #expect(count.value == value)
    }

    @Test("Rejects negative values", arguments: [Int64.min, -2, -1])
    func rejectsNegativeValues(value: Int64) {
        #expect(throws: ByteCountError.negativeValue(value)) {
            try ByteCount(value)
        }
    }

    @Test("Accepts unsigned values through the SQLite storage boundary")
    func acceptsSupportedUnsignedBoundary() throws {
        let count = try ByteCount(unsignedValue: UInt64(Int64.max))

        #expect(count.value == Int64.max)
    }

    @Test("Rejects unsigned values that cannot be persisted")
    func rejectsUnsupportedUnsignedValues() {
        let value = UInt64(Int64.max) + 1

        #expect(throws: ByteCountError.valueExceedsStorageLimit(value)) {
            try ByteCount(unsignedValue: value)
        }
    }

    @Test("Adds values without wrapping")
    func addsValues() throws {
        let lhs = try ByteCount(40)
        let rhs = try ByteCount(2)

        let result = try lhs.adding(rhs)

        #expect(result.value == 42)
    }

    @Test("Allows addition at the exact upper boundary")
    func addsAtUpperBoundary() throws {
        let maximum = try ByteCount(Int64.max)

        let result = try maximum.adding(.zero)

        #expect(result == maximum)
    }

    @Test("Reports addition overflow instead of wrapping")
    func reportsAdditionOverflow() throws {
        let maximum = try ByteCount(Int64.max)
        let one = try ByteCount(1)

        #expect(throws: ByteCountError.additionOverflow(lhs: Int64.max, rhs: 1)) {
            try maximum.adding(one)
        }
    }

    @Test("Subtracts when the result remains non-negative")
    func subtractsValues() throws {
        let lhs = try ByteCount(42)
        let rhs = try ByteCount(40)

        let result = try lhs.subtracting(rhs)

        #expect(result.value == 2)
    }

    @Test("Reports subtraction underflow instead of creating a negative count")
    func reportsSubtractionUnderflow() throws {
        let lhs = try ByteCount(1)
        let rhs = try ByteCount(2)

        #expect(throws: ByteCountError.subtractionUnderflow(lhs: 1, rhs: 2)) {
            try lhs.subtracting(rhs)
        }
    }
}
