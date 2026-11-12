import HTTP3
import HTTPCore
import Testing

/// The `Alt-Svc` middleware (#0103): `h3=":<port>"; ma=<seconds>` on TLS responses only.
@Suite struct AltSvcTests {
    struct OK: HTTPHandler {
        func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse {
            HTTPResponse(status: .notFound)
        }
    }

    static let tls = ConnectionInfo(isSecure: true, negotiatedALPN: "http/1.1", tlsVersion: .v1_3)
    static let tlsNoALPN = ConnectionInfo(isSecure: true)
    static let h2 = ConnectionInfo(isSecure: true, negotiatedALPN: "h2")
    static let cleartext = ConnectionInfo()
    static let h3 = ConnectionInfo(isSecure: true, negotiatedALPN: "h3")

    /// The `alt-svc` values of the response to one request on `connection`.
    func altSvc(_ middleware: AltSvc, on connection: ConnectionInfo) async throws -> [String] {
        let request = HTTPRequest(method: .get, path: .empty, headers: HTTPFieldsView())
        let response = try await middleware.handle(request, context: RequestContext(connection: connection), next: OK())
        #expect(response.status == .notFound, "the response passes through")
        return (0..<response.headers.count).compactMap { index in
            response.headers.nameString(at: index) == "alt-svc" ? response.headers.valueString(at: index) : nil
        }
    }

    @Test func rendersTheRFC7838Value() {
        #expect(AltSvc.value(port: 8443, maxAge: 86_400) == #"h3=":8443"; ma=86400"#)
        #expect(AltSvc(port: 443, maxAge: 60).value == #"h3=":443"; ma=60"#)
        #expect(AltSvc(port: 1).maxAge == 86_400, "RFC 7838 default")
    }

    @Test func addedOnTLSResponsesOnly() async throws {
        let middleware = AltSvc(port: 8443, maxAge: 3600)
        let expected = [#"h3=":8443"; ma=3600"#]
        #expect(try await altSvc(middleware, on: Self.tls) == expected)
        #expect(try await altSvc(middleware, on: Self.tlsNoALPN) == expected)
        #expect(try await altSvc(middleware, on: Self.h2) == expected)
        #expect(try await altSvc(middleware, on: Self.cleartext).isEmpty, "never on cleartext")
        #expect(try await altSvc(middleware, on: Self.h3).isEmpty, "never on HTTP/3 itself")
    }

    @Test func advertisesNothingUntilThePortIsKnownThenTheFirstPortWins() async throws {
        let middleware = AltSvc(maxAge: 10)
        #expect(middleware.value == nil)
        #expect(try await altSvc(middleware, on: Self.tls).isEmpty)
        middleware.advertise(port: 4433)
        middleware.advertise(port: 9999)
        #expect(middleware.value == #"h3=":4433"; ma=10"#)
        // Copies share the rendered value (the chain holds a copy).
        let copy = middleware
        #expect(try await altSvc(copy, on: Self.tls) == [#"h3=":4433"; ma=10"#])
    }

    @Test func appliesOnlyToTLSWithoutH3() {
        #expect(AltSvc.applies(to: Self.tls))
        #expect(AltSvc.applies(to: Self.h2))
        #expect(!AltSvc.applies(to: Self.cleartext))
        #expect(!AltSvc.applies(to: Self.h3))
    }
}
