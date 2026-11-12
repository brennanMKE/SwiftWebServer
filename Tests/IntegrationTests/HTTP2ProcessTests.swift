import Foundation
import HTTPTestSupport
import Testing

/// The shipped `SwiftWebServer` serving HTTP/2 from its config (#0119), launched as a child
/// process on 127.0.0.1 with every port 0 and the in-memory test identity. Clients are the
/// system curl (nghttp2), run through `ChildProcess`.
@Suite struct HTTP2ProcessTests {
    typealias Listeners = ListenersProcessTests

    func curl(_ arguments: [String]) async throws -> ChildProcess.Output {
        try await ChildProcess.run(URL(fileURLWithPath: "/usr/bin/curl"),
                                   ["-sS", "--max-time", "10"] + arguments, timeout: .seconds(30))
    }

    /// A TLS config (port 0) with `extra` keys appended.
    static func config(_ extra: String = "") throws -> String {
        let base = try Listeners.tlsConfig(http3: nil)
        return extra.isEmpty ? base : String(base.dropLast()) + ", " + extra + "}"
    }

    static let version = ["-w", " %{http_code} %{http_version}"]

    /// Default config: HTTPS offers `h2` and `http/1.1` via ALPN; cleartext is HTTP/1.1 only and
    /// a prior-knowledge h2c client is refused.
    @Test(.timeLimit(.minutes(1)))
    func h2OnHTTPSByDefaultAndNoCleartextH2c() async throws {
        let fixture = try ParityTests.Fixture(config: try Self.config())
        let child = try ParityTests.launch(["--config", fixture.configPath, "--port", "0"])
        defer { child.kill() }
        let ports = try await Listeners.ports(child, expecting: 2)
        let https = try #require(ports.https)

        var output = try await curl(["-k", "--http2"] + Self.version + ["https://127.0.0.1:\(https)/"])
        #expect(output.stdout == "<h1>home</h1> 200 2", "\(output.stderr)")
        output = try await curl(["-k", "--http2", "-o", "/dev/null"] + Self.version + ["https://127.0.0.1:\(https)/missing"])
        #expect(output.stdout == " 404 2", "\(output.stderr)")
        output = try await curl(["-k", "--http1.1"] + Self.version + ["https://127.0.0.1:\(https)/"])
        #expect(output.stdout == "<h1>home</h1> 200 1.1", "\(output.stderr)")
        output = try await curl(Self.version + ["http://127.0.0.1:\(ports.http)/"])
        #expect(output.stdout == "<h1>home</h1> 200 1.1", "\(output.stderr)")
        output = try await curl(["--http2-prior-knowledge"] + Self.version + ["http://127.0.0.1:\(ports.http)/"])
        #expect(output.status != 0, "h2c is off by default: \(output.stdout)")
        #expect(!output.stdout.hasSuffix(" 2"), "\(output.stdout)")
        // The cleartext listener still serves HTTP/1.1 after the refused h2c attempt.
        output = try await curl(Self.version + ["http://127.0.0.1:\(ports.http)/"])
        #expect(output.stdout == "<h1>home</h1> 200 1.1", "\(output.stderr)")

        child.signal(SIGTERM)
        #expect(try await child.waitForExit(timeout: .seconds(15)) == 0, "\(child.stderr)")
    }

    /// `"cleartext": true`: prior-knowledge h2c on the cleartext port, HTTP/1.1 still served
    /// there, and HTTP/2 on HTTPS.
    @Test(.timeLimit(.minutes(1)))
    func cleartextH2cWhenEnabled() async throws {
        let fixture = try ParityTests.Fixture(config: try Self.config(#""http2": {"cleartext": true, "maxConcurrentStreams": 50}"#))
        let child = try ParityTests.launch(["--config", fixture.configPath, "--port", "0"])
        defer { child.kill() }
        let ports = try await Listeners.ports(child, expecting: 2)
        let https = try #require(ports.https)

        var output = try await curl(["--http2-prior-knowledge"] + Self.version + ["http://127.0.0.1:\(ports.http)/"])
        #expect(output.stdout == "<h1>home</h1> 200 2", "\(output.stderr)")
        output = try await curl(Self.version + ["http://127.0.0.1:\(ports.http)/"])
        #expect(output.stdout == "<h1>home</h1> 200 1.1", "\(output.stderr)")
        output = try await curl(["-k", "--http2"] + Self.version + ["https://127.0.0.1:\(https)/"])
        #expect(output.stdout == "<h1>home</h1> 200 2", "\(output.stderr)")

        child.signal(SIGTERM)
        #expect(try await child.waitForExit(timeout: .seconds(15)) == 0, "\(child.stderr)")
    }

    /// `"http2": false`: HTTPS negotiates HTTP/1.1 even when the client offers `h2`.
    @Test(.timeLimit(.minutes(1)))
    func http2FalseServesHTTP1Only() async throws {
        let fixture = try ParityTests.Fixture(config: try Self.config(#""http2": false"#))
        let child = try ParityTests.launch(["--config", fixture.configPath, "--port", "0"])
        defer { child.kill() }
        let https = try #require(try await Listeners.ports(child, expecting: 2).https)
        let output = try await curl(["-k", "--http2"] + Self.version + ["https://127.0.0.1:\(https)/"])
        #expect(output.stdout == "<h1>home</h1> 200 1.1", "\(output.stderr)")
        child.signal(SIGTERM)
        #expect(try await child.waitForExit(timeout: .seconds(15)) == 0, "\(child.stderr)")
    }

    /// With HTTP/3 configured, HTTP/2 responses on HTTPS still carry `Alt-Svc` (#0103).
    @Test(.timeLimit(.minutes(1)))
    func altSvcStillOnHTTPSOverHTTP2() async throws {
        let fixture = try ParityTests.Fixture(config: try Listeners.tlsConfig(http3: #"{"altSvcMaxAge": 600}"#))
        let child = try ParityTests.launch(["--config", fixture.configPath, "--port", "0"])
        defer { child.kill() }
        let ports = try await Listeners.ports(child, expecting: 3)
        let https = try #require(ports.https)
        let h3 = try #require(ports.h3)
        let output = try await curl(["-k", "--http2", "-i", "https://127.0.0.1:\(https)/"])
        #expect(output.stdout.hasPrefix("HTTP/2 200"), "\(output.stdout)")
        #expect(ListenersProcessTests().altSvc(output.stdout) == ["h3=\":\(h3)\"; ma=600"], "\(output.stdout)")
        child.signal(SIGTERM)
        #expect(try await child.waitForExit(timeout: .seconds(15)) == 0, "\(child.stderr)")
    }

    /// Bad `http2` values exit 1 naming the key.
    @Test(.timeLimit(.minutes(1)), arguments: [
        (#"{"http2": 1}"#, "\"http2\" must be true, false or an object"),
        (#"{"http2": {"cleartext": "yes"}}"#, "\"http2.cleartext\" must be true or false"),
        (#"{"http2": {"maxConcurrentStreams": 70000}}"#, "\"http2.maxConcurrentStreams\""),
        (#"{"http2": {"initialWindowSize": -1}}"#, "\"http2.initialWindowSize\""),
        (#"{"http2": {"maxRequestBodySize": "big"}}"#, "\"http2.maxRequestBodySize\""),
        (#"{"http2": {"abuseLimits": {"window": 0}}}"#, "\"http2.abuseLimits.window\""),
        (#"{"http2": {"abuseLimits": {"maxStreamsPerConnection": 0}}}"#, "\"http2.abuseLimits.maxStreamsPerConnection\""),
    ])
    func http2ConfigErrorsExitOne(config: String, message: String) async throws {
        let fixture = try ParityTests.Fixture(config: config)
        let child = try ParityTests.launch(["--config", fixture.configPath, "--port", "0"])
        defer { child.kill() }
        #expect(try await child.waitForExit(timeout: .seconds(10)) == 1)
        #expect(child.stderr.contains(message), "stderr: \(child.stderr)")
        #expect(child.stdout.isEmpty)
    }
}
