import Testing
@testable import SpaceTraceDomain

struct ObservationIdentityTests {
    @Test("Rejects empty scope identifiers", arguments: ["", " ", "\n\t"])
    func rejectsEmptyScopeIdentifiers(value: String) {
        #expect(throws: ObservationIdentityError.emptyScopeID) {
            try ScopeID(value)
        }
    }

    @Test("Rejects empty subject identifiers", arguments: ["", " ", "\n\t"])
    func rejectsEmptySubjectIdentifiers(value: String) {
        #expect(throws: ObservationIdentityError.emptySubjectID) {
            try SubjectID(value)
        }
    }

    @Test("Rejects instants before the Unix epoch", arguments: [Int64.min, -1])
    func rejectsInstantsBeforeUnixEpoch(value: Int64) {
        #expect(throws: ObservationInstantError.beforeUnixEpoch(value)) {
            try ObservationInstant(millisecondsSince1970: value)
        }
    }

    @Test("Accepts the timestamp storage boundaries", arguments: [Int64(0), Int64.max])
    func acceptsTimestampBoundaries(value: Int64) throws {
        let instant = try ObservationInstant(millisecondsSince1970: value)

        #expect(instant.millisecondsSince1970 == value)
    }
}
