import HTTPCore
import Testing

/// #0065 / #0107: the RFC 9218 `priority` field parser shared by HTTP/2 and HTTP/3.
@Suite struct HTTPPriorityTests {
    static func parse(_ value: String) -> HTTPPriority {
        Array(value.utf8).withUnsafeBytes { HTTPPriority(parsing: $0) }
    }

    static func isValid(_ value: String) -> Bool {
        var priority = HTTPPriority()
        return Array(value.utf8).withUnsafeBytes { priority.apply($0) }
    }

    @Test func defaults() {
        #expect(HTTPPriority.default == HTTPPriority(urgency: 3, incremental: false))
        #expect(Self.parse("") == .default)
    }

    @Test(arguments: [
        ("u=0", HTTPPriority(urgency: 0)),
        ("u=7", HTTPPriority(urgency: 7)),
        ("i", HTTPPriority(incremental: true)),
        ("i=?1", HTTPPriority(incremental: true)),
        ("i=?0", HTTPPriority(incremental: false)),
        ("u=1, i", HTTPPriority(urgency: 1, incremental: true)),
        ("i,u=5", HTTPPriority(urgency: 5, incremental: true)),
        ("  u=2 ,\ti  ", HTTPPriority(urgency: 2, incremental: true)),
        // Later members replace earlier ones.
        ("u=1, u=6", HTTPPriority(urgency: 6)),
        // Unknown keys, parameters and other item types are ignored.
        ("x=1, u=4;p=?1, foo=\"bar\", t=tok/en, b=:aGk=:, d=1.5, l=(1 2 a);q", HTTPPriority(urgency: 4)),
        ("u=2, *k-e_y.z", HTTPPriority(urgency: 2)),
        // A `u` out of range or of the wrong type is ignored, keeping the default.
        ("u=8", HTTPPriority.default),
        ("u=-1", HTTPPriority.default),
        ("u=1.0", HTTPPriority.default),
        ("u=\"1\"", HTTPPriority.default),
        ("u", HTTPPriority.default),
        ("i=1", HTTPPriority.default),
        ("u=1, u=9", HTTPPriority.default),
    ])
    func validValues(_ value: String, _ expected: HTTPPriority) {
        #expect(Self.isValid(value))
        #expect(Self.parse(value) == expected)
    }

    /// Not a Structured Field Dictionary: the whole field is ignored.
    @Test(arguments: [
        "u=1,", "u=1,,i", ",u=1", "U=1", "u=1 i", "1=u", "u==1", "u=?2", "u=\"open", "u=1;", "u=(1",
        "u=1234567890123456", "u=1.2345", "u=:not base64!:", "u=1, i=?", "u=é",
    ])
    func invalidValues(_ value: String) {
        #expect(!Self.isValid(value))
        #expect(Self.parse(value) == .default)
    }

    /// An invalid value leaves an existing priority alone; a valid one only replaces the
    /// parameters it carries (a handler's response field on top of the request's).
    @Test func applyMerges() {
        var priority = HTTPPriority(urgency: 1, incremental: true)
        let invalid = Array("u=,".utf8).withUnsafeBytes { priority.apply($0) }
        #expect(!invalid)
        #expect(priority == HTTPPriority(urgency: 1, incremental: true))
        let valid = Array("u=6".utf8).withUnsafeBytes { priority.apply($0) }
        #expect(valid)
        #expect(priority == HTTPPriority(urgency: 6, incremental: true))
    }

    @Test func appliesFromFields() {
        var fields = HTTPFields()
        fields.append(.contentType, "text/plain")
        fields.append(.priority, "u=5")
        fields.append(.priority, "i")
        var priority = HTTPPriority()
        let found = priority.apply(from: fields)
        #expect(found)
        #expect(priority == HTTPPriority(urgency: 5, incremental: true))
        var none = HTTPPriority()
        let foundNone = none.apply(from: HTTPFields())
        #expect(!foundNone)
    }

    /// Lower urgency first; non-incremental before incremental and in stream order; incremental
    /// streams of one urgency tie (they share).
    @Test func schedulingKeyOrders() {
        let urgent = HTTPPriority(urgency: 0).schedulingKey(streamID: 9)
        let normalFirst = HTTPPriority().schedulingKey(streamID: 1)
        let normalLater = HTTPPriority().schedulingKey(streamID: 3)
        let incrementalA = HTTPPriority(incremental: true).schedulingKey(streamID: 5)
        let incrementalB = HTTPPriority(incremental: true).schedulingKey(streamID: 7)
        #expect(urgent < normalFirst)
        #expect(normalFirst < normalLater)
        #expect(normalLater < incrementalA)
        #expect(incrementalA == incrementalB)
    }
}
