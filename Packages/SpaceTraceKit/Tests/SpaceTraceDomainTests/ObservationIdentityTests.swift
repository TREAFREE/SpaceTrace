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

    @Test("Opaque scope and subject identities use exact UTF-8 bytes")
    func identitiesDoNotFoldCanonicalUnicodeEquivalents() throws {
        let composed = "\u{00E9}"
        let decomposed = "e\u{0301}"
        let composedScope = try ScopeID(composed)
        let decomposedScope = try ScopeID(decomposed)
        let composedSubject = try SubjectID(composed)
        let decomposedSubject = try SubjectID(decomposed)

        #expect(composedScope != decomposedScope)
        #expect(Set([composedScope, decomposedScope]).count == 2)
        #expect(composedSubject != decomposedSubject)
        #expect(Set([composedSubject, decomposedSubject]).count == 2)
    }
}
