import Foundation
import HTTPCore
import StaticFiles
import Testing
@testable import VirtualHosts

/// A request built the way a connection builds one, with an optional `Host` field and an
/// optional `:authority`.
struct HostRequest {
    let storage: HTTPRequestStorage
    let request: HTTPRequest

    init(host: String?, authority: String? = nil, path: String = "/") {
        let storage = HTTPRequestStorage(bufferCapacity: 512, fieldCapacity: 4)
        self.storage = storage
        storage.buffer.append(contentsOf: Array("GARBAGE ".utf8))
        func add(_ text: String) -> ByteView {
            let start = storage.buffer.writerIndex
            storage.buffer.append(contentsOf: Array(text.utf8))
            return ByteView(offset: start, length: storage.buffer.writerIndex - start)
        }
        let pathView = add(path)
        let authorityView = authority.map(add) ?? .empty
        if let host {
            let name = add("Host")
            let value = add(host)
            let hash = storage.buffer.withSpan(of: name) { ASCII.fnv1aLowercased($0) }
            storage.appendField(nameView: name, hash: hash, valueView: value)
        }
        request = HTTPRequest(method: .get, authority: authorityView, path: pathView, headers: storage.fieldsView)
    }
}

/// Answers with `code`, and echoes the matched host name (when recorded) in `Server`.
struct Respond: HTTPHandler {
    let code: Int
    init(_ code: Int) { self.code = code }
    func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse {
        var headers = HTTPFields()
        if let host = context.virtualHost {
            headers.append(.server, string: "\(host.index)|\(host.name)|\(host.isFallback)")
        }
        return HTTPResponse(status: HTTPStatus(code: code), headers: headers)
    }
}

extension VirtualHosts {
    func status(host: String?, authority: String? = nil, path: String = "/") async throws -> Int {
        let test = HostRequest(host: host, authority: authority, path: path)
        return Int(try await handle(test.request, context: RequestContext()).status.code)
    }

    func matched(_ authority: String) -> Int? {
        Array(authority.utf8).withUnsafeBufferPointer { match(authority: Span(_unsafeElements: $0)) }
    }
}

@Suite struct HostMatchingTests {
    let sites: VirtualHosts

    init() throws {
        sites = try VirtualHosts {
            VirtualHost("a.test", "www.a.test", handler: Respond(201))
            VirtualHost("*.b.test", handler: Respond(202))
            VirtualHost("*.deep.b.test", handler: Respond(203))
            VirtualHost("exact.b.test", handler: Respond(204))
            VirtualHost("[::1]", "127.0.0.1", handler: Respond(205))
            VirtualHost("xn--bcher-kva.example", handler: Respond(206))
        }
    }

    @Test func exactNames() {
        #expect(sites.matched("a.test") == 0)
        #expect(sites.matched("www.a.test") == 0)
        #expect(sites.matched("b.a.test") == nil)
        #expect(sites.matched("a.tes") == nil)
        #expect(sites.matched("aa.test") == nil)
    }

    @Test func caseInsensitive() {
        #expect(sites.matched("A.TEST") == 0)
        #expect(sites.matched("Www.A.Test") == 0)
        #expect(sites.matched("X.B.TEST") == 1)
        #expect(sites.matched("XN--BCHER-KVA.example") == 5)
    }

    @Test func portStripped() {
        #expect(sites.matched("a.test:8080") == 0)
        #expect(sites.matched("a.test:") == 0)
        #expect(sites.matched("a.test.") == 0)
        #expect(sites.matched("a.test.:443") == 0)
        #expect(sites.matched("[::1]:8443") == 4)
        #expect(sites.matched("[::1]") == 4)
        #expect(sites.matched("127.0.0.1:80") == 4)
        #expect(sites.matched("127.0.0.1") == 4)
        #expect(sites.matched("a.test:80x") == nil)
    }

    @Test func wildcards() {
        #expect(sites.matched("x.b.test") == 1)
        #expect(sites.matched("x.y.b.test") == 1)
        #expect(sites.matched("b.test") == nil, "a wildcard does not match the bare suffix")
        #expect(sites.matched(".b.test") == nil)
        #expect(sites.matched("xb.test") == nil)
        // Longest wildcard suffix wins; an exact name beats every wildcard.
        #expect(sites.matched("x.deep.b.test") == 2)
        #expect(sites.matched("deep.b.test") == 1)
        #expect(sites.matched("exact.b.test") == 3)
        #expect(sites.matched("y.exact.b.test") == 1)
    }

    @Test func punycodeIsLeftAsIs() {
        #expect(sites.matched("xn--bcher-kva.example") == 5)
        #expect(sites.matched("bücher.example") == nil)
    }

    @Test func emptyAndJunk() {
        #expect(sites.matched("") == nil)
        #expect(sites.matched(":80") == nil)
        #expect(sites.matched(".") == nil)
        #expect(sites.matched("a.test/x") == nil)
    }
}

@Suite struct VirtualHostsDispatchTests {
    @Test(.timeLimit(.minutes(1))) func routesByHostAndAuthority() async throws {
        let sites = try VirtualHosts {
            VirtualHost("a.test", handler: Respond(201))
            VirtualHost("b.test", handler: Respond(202))
        }
        #expect(try await sites.status(host: "a.test") == 201)
        #expect(try await sites.status(host: "B.test:8080") == 202)
        // `:authority` (HTTP/2, HTTP/3, absolute-form) wins over `Host`.
        #expect(try await sites.status(host: "a.test", authority: "b.test") == 202)
        #expect(try await sites.status(host: nil, authority: "a.test:443") == 201)
    }

    @Test(.timeLimit(.minutes(1))) func unknownOrMissingHostIs421WithoutDefault() async throws {
        let sites = try VirtualHosts {
            VirtualHost("a.test", handler: Respond(201))
        }
        #expect(try await sites.status(host: "c.test") == 421)
        #expect(try await sites.status(host: nil) == 421)
        #expect(try await sites.status(host: "") == 421)
    }

    @Test(.timeLimit(.minutes(1))) func defaultHost() async throws {
        let sites = try VirtualHosts {
            VirtualHost("a.test", handler: Respond(201))
            VirtualHost.default("fallback.test", handler: Respond(209))
        }
        #expect(sites.defaultHost == 1)
        #expect(try await sites.status(host: "a.test") == 201)
        #expect(try await sites.status(host: "c.test") == 209)
        #expect(try await sites.status(host: nil) == 209)
        #expect(try await sites.status(host: "fallback.test") == 209)
    }

    @Test(.timeLimit(.minutes(1))) func unmatchedNextFallsThrough() async throws {
        let sites = try VirtualHosts(unmatched: .next) {
            VirtualHost("a.test", handler: Respond(201))
        }
        let test = HostRequest(host: "c.test")
        let response = try await sites.handle(test.request, context: RequestContext(), next: Respond(299))
        #expect(response.status.code == 299)
        #expect(try await sites.status(host: "c.test") == 404)
    }

    @Test(.timeLimit(.minutes(1))) func recordsMatchedHost() async throws {
        let sites = try VirtualHosts(recordsHost: true) {
            VirtualHost("a.test", "www.a.test", handler: Respond(201))
            VirtualHost.default(handler: Respond(209))
        }
        func server(_ host: String) async throws -> String? {
            let test = HostRequest(host: host)
            return try await sites.handle(test.request, context: RequestContext()).headers.firstValueString(for: .server)
        }
        #expect(try await server("WWW.a.test") == "0|a.test|false")
        #expect(try await server("other.test") == "1||true")

        let silent = try VirtualHosts { VirtualHost("a.test", handler: Respond(201)) }
        let test = HostRequest(host: "a.test")
        let response = try await silent.handle(test.request, context: RequestContext())
        #expect(response.headers.firstValueString(for: .server) == nil)
    }

    @Test(.timeLimit(.minutes(1))) func perHostChains() async throws {
        struct Tag: HTTPMiddleware {
            let value: String
            func handle<Next: HTTPHandler>(_ request: HTTPRequest, context: RequestContext, next: Next) async throws -> HTTPResponse {
                var response = try await next.handle(request, context: context)
                response.headers.append(.via, string: value)
                return response
            }
        }
        let sites = try VirtualHosts {
            VirtualHost("a.test") {
                Tag(value: "a")
                Respond(200)
            }
            VirtualHost("b.test") {
                Tag(value: "b1")
                Tag(value: "b2")
                Respond(200)
            }
        }
        let a = HostRequest(host: "a.test"), b = HostRequest(host: "b.test")
        #expect(try await sites.handle(a.request, context: RequestContext()).headers.firstValueString(for: .via) == "a")
        #expect(try await sites.handle(b.request, context: RequestContext()).headers.firstValueString(for: .via) == "b2")

        var elements = 0
        sites.forEachChainElement { _ in elements += 1 }
        #expect(elements == 2)
    }

    @Test(.timeLimit(.minutes(1))) func perHostStaticFilesRoots() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("vhosts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        for (site, file) in [("a", "only-a.txt"), ("b", "only-b.txt")] {
            let dir = base.appendingPathComponent(site)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("site \(site)\n".utf8).write(to: dir.appendingPathComponent(file))
        }
        let a = try StaticFiles(root: base.appendingPathComponent("a").path)
        let b = try StaticFiles(root: base.appendingPathComponent("b").path)
        let sites = try VirtualHosts {
            VirtualHost("a.test", handler: a)
            VirtualHost("b.test", handler: b)
        }
        #expect(try await sites.status(host: "a.test", path: "/only-a.txt") == 200)
        #expect(try await sites.status(host: "a.test", path: "/only-b.txt") == 404)
        #expect(try await sites.status(host: "b.test:8080", path: "/only-b.txt") == 200)
        #expect(try await sites.status(host: "b.test", path: "/only-a.txt") == 404)
        #expect(try await sites.status(host: "c.test", path: "/only-a.txt") == 421)
    }
}

@Suite struct VirtualHostsConfigurationTests {
    func failure(_ hosts: [VirtualHost]) -> VirtualHostsError? {
        do {
            _ = try VirtualHosts(hosts)
            return nil
        } catch {
            return error
        }
    }

    @Test func rejectsBadNames() {
        for name in ["", "a.test:8080", "a*.test", "*", "*.", "foo.*.test", "a..test", "bücher.example", "[zz]", "a b"] {
            #expect(failure([VirtualHost(name, handler: Respond(200))]) != nil, "\(name)")
        }
    }

    @Test func rejectsDuplicatesAndTwoDefaults() {
        #expect(failure([VirtualHost("a.test", handler: Respond(200)), VirtualHost("A.TEST.", handler: Respond(200))])
            == .duplicateName("a.test"))
        #expect(failure([VirtualHost("*.a.test", handler: Respond(200)), VirtualHost("*.a.test", handler: Respond(200))])
            == .duplicateName("*.a.test"))
        #expect(failure([VirtualHost.default(handler: Respond(200)), VirtualHost.default(handler: Respond(200))])
            == .multipleDefaults)
    }

    @Test func manyHostsSurviveCollisions() throws {
        var hosts: [VirtualHost] = []
        for i in 0..<300 { hosts.append(VirtualHost("site\(i).test", "*.w\(i).test", handler: Respond(200))) }
        let sites = try VirtualHosts(hosts)
        for i in 0..<300 {
            #expect(sites.matched("SITE\(i).test:80") == i)
            #expect(sites.matched("x.w\(i).test") == i)
        }
        #expect(sites.matched("site300.test") == nil)
    }
}
