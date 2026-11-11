import Testing
import HTTPCore

private func validate(_ kind: PseudoHeaderValidator.MessageKind, _ fields: [(String, String)]) -> PseudoHeaderValidator.Violation? {
    var validator = PseudoHeaderValidator(kind: kind)
    for (name, value) in fields {
        var n = Array(name.utf8)
        var v = Array(value.utf8)
        let violation = n.withUnsafeMutableBufferPointer { nb in
            v.withUnsafeMutableBufferPointer { vb in validator.handle(name: nb.span, value: vb.span) }
        }
        if let violation { return violation }
    }
    return validator.finish()
}

private let get = [(":method", "GET"), (":scheme", "https"), (":path", "/"), (":authority", "example.com")]

@Suite struct PseudoHeaderValidatorTests {
    @Test func validRequestsAndResponses() {
        #expect(validate(.request, get + [("accept", "*/*"), ("te", "trailers")]) == nil)
        #expect(validate(.request, [(":method", "GET"), (":scheme", "https"), (":path", "/"), ("host", "h")]) == nil)
        #expect(validate(.request, [(":method", "CONNECT"), (":authority", "h:443")]) == nil)
        #expect(validate(.request, [(":method", "CONNECT"), (":protocol", "websocket"), (":scheme", "https"),
                                    (":path", "/chat"), (":authority", "h")]) == nil)
        #expect(validate(.request, [(":method", "OPTIONS"), (":scheme", "https"), (":path", "*"), (":authority", "h")]) == nil)
        #expect(validate(.response, [(":status", "200"), ("content-type", "text/html")]) == nil)
    }

    @Test func pseudoHeaderOrderingAndDuplicates() {
        #expect(validate(.request, [(":method", "GET"), ("accept", "x"), (":path", "/")]) == .pseudoHeaderAfterRegularField)
        #expect(validate(.request, get + [(":path", "/again")]) == .duplicatePseudoHeader(.pseudoPath))
        #expect(validate(.request, [(":foo", "x")]) == .unknownPseudoHeader)
        #expect(validate(.request, [(":PATH", "/")]) == .unknownPseudoHeader)
        #expect(validate(.request, get + [(":status", "200")]) == .pseudoHeaderNotAllowed(.pseudoStatus))
        #expect(validate(.response, [(":status", "200"), (":path", "/")]) == .pseudoHeaderNotAllowed(.pseudoPath))
    }

    @Test func requiredPseudoHeaders() {
        #expect(validate(.request, [(":scheme", "https"), (":path", "/")]) == .missingPseudoHeader(.pseudoMethod))
        #expect(validate(.request, [(":method", "GET"), (":path", "/"), (":authority", "h")]) == .missingPseudoHeader(.pseudoScheme))
        #expect(validate(.request, [(":method", "GET"), (":scheme", "https"), (":authority", "h")]) == .missingPseudoHeader(.pseudoPath))
        #expect(validate(.request, [(":method", "GET"), (":scheme", "https"), (":path", "/")]) == .missingPseudoHeader(.pseudoAuthority))
        #expect(validate(.response, [("server", "x")]) == .missingPseudoHeader(.pseudoStatus))
        #expect(validate(.response, [(":status", "20")]) == .invalidStatus)
    }

    @Test func pathAndMethodRules() {
        #expect(validate(.request, [(":method", "GET"), (":scheme", "https"), (":path", ""), (":authority", "h")]) == .emptyPath)
        #expect(validate(.request, [(":method", "GET"), (":scheme", "https"), (":path", "*"), (":authority", "h")]) == .asteriskPathRequiresOptions)
        #expect(validate(.request, [(":method", "G T")]) == .invalidMethod)
        #expect(validate(.request, get + [(":protocol", "websocket")]) == .protocolRequiresConnect)
        #expect(validate(.request, [(":method", "CONNECT"), (":authority", "h"), (":path", "/")]) == .pseudoHeaderNotAllowed(.pseudoPath))
        #expect(validate(.request, [(":method", "CONNECT")]) == .missingPseudoHeader(.pseudoAuthority))
    }

    @Test func regularFieldRules() {
        #expect(validate(.request, get + [("Accept", "x")]) == .invalidFieldName)
        #expect(validate(.request, get + [("bad name", "x")]) == .invalidFieldName)
        #expect(validate(.request, get + [("accept", " x")]) == .invalidFieldValue)
        #expect(validate(.request, get + [("accept", "x\r\ny")]) == .invalidFieldValue)
        #expect(validate(.request, get + [("connection", "close")]) == .connectionSpecificField(.connection))
        #expect(validate(.request, get + [("transfer-encoding", "chunked")]) == .connectionSpecificField(.transferEncoding))
        #expect(validate(.request, get + [("upgrade", "h2c")]) == .connectionSpecificField(.upgrade))
        #expect(validate(.request, get + [("te", "gzip")]) == .invalidTE)
    }
}
