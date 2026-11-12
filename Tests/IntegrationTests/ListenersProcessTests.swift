import Foundation
import HTTPCore
import HTTPTestSupport
import NetworkTransport
import Testing

/// The shipped `SwiftWebServer` serving cleartext HTTP/1.1, HTTPS and HTTP/3 from one config
/// (#0089, #0103), launched as a child process on 127.0.0.1 with every port 0. The TLS
/// identity is the gitignored test identity from `scripts/make-test-identity.sh`, which the
/// server imports in memory only. Clients are the system curl (`-k`) and Homebrew curl for
/// HTTP/3, run through `ChildProcess`.
@Suite struct ListenersProcessTests {
    static let h3Curl = "/opt/homebrew/opt/curl/bin/curl"
    static var hasH3Curl: Bool { FileManager.default.isExecutableFile(atPath: h3Curl) }

    /// The test identity's path (created on first use).
    static func identityPath() throws -> String {
        try TestIdentity.load().directory + "/server.p12"
    }

    /// `tls` and `http3` keys serving the test identity on TLS port 0.
    static func tlsConfig(http3: String? = "true", drainTimeout: Int = 2) throws -> String {
        var config = #"{"drainTimeout": \#(drainTimeout), "tls": {"identity": "\#(try identityPath())", "password": "\#(TestIdentity.password)", "port": 0}"#
        if let http3 { config += #", "http3": \#(http3)"# }
        return config + "}"
    }

    /// The bound ports from the `listening` lines: cleartext, then `(https)` and `(h3)`.
    struct Ports {
        var http: UInt16
        var https: UInt16?
        var h3: UInt16?
    }

    /// Waits for the last `listening` line (`(h3)` for three listeners), then reads them all.
    static func ports(_ child: ChildProcess, expecting count: Int) async throws -> Ports {
        // The parse closure runs under ChildProcess's lock, so it looks only at its own line.
        let last = count == 3 ? "(h3)" : count == 2 ? "(https)" : ""
        _ = try await child.waitForLine { line in
            line.hasPrefix("listening ") && line.hasSuffix(last) ? true : nil
        }
        var ports = Ports(http: 0)
        for line in child.stdout.split(separator: "\n") where line.hasPrefix("listening ") {
            let words = line.split(separator: " ")
            guard words.count >= 2, let colon = words[1].lastIndex(of: ":"),
                  let port = UInt16(words[1][words[1].index(after: colon)...]) else { continue }
            switch words.count > 2 ? words[2] : "" {
            case "(https)": ports.https = port
            case "(h3)": ports.h3 = port
            default: ports.http = port
            }
        }
        return ports
    }

    func curl(_ arguments: [String], h3: Bool = false) async throws -> ChildProcess.Output {
        try await ChildProcess.run(URL(fileURLWithPath: h3 ? Self.h3Curl : "/usr/bin/curl"),
                                   ["-sS", "--max-time", "10"] + arguments, timeout: .seconds(30))
    }

    // MARK: Serving

    /// One config, three listeners: `curl http://`, `curl -k https://` and
    /// `curl --http3-only -k https://` all get the file; TCP and UDP share the TLS port number
    /// even though it was 0; the password comes from `passwordEnv`; SIGTERM exits 0.
    @Test(.timeLimit(.minutes(1)), .enabled(if: hasH3Curl))
    func cleartextHTTPSAndHTTP3FromOneConfig() async throws {
        let config = #"{"drainTimeout": 2, "tls": {"identity": "\#(try Self.identityPath())", "passwordEnv": "SWS_TEST_TLS_PASSWORD", "port": 0}, "http3": {"enabled": true}}"#
        let fixture = try ParityTests.Fixture(config: config)
        let child = try ParityTests.launch(["--config", fixture.configPath, "--port", "0"],
                                           environment: ["SWS_TEST_TLS_PASSWORD": TestIdentity.password])
        defer { child.kill() }
        let ports = try await Self.ports(child, expecting: 3)
        let https = try #require(ports.https)
        #expect(ports.h3 == https, "HTTP/3 defaults to the TLS port number: \(child.stdout)")
        #expect(ports.http != https)

        var output = try await curl(["-w", " %{http_code} %{http_version}", "http://127.0.0.1:\(ports.http)/"])
        #expect(output.stdout == "<h1>home</h1> 200 1.1", "\(output.stderr)")
        output = try await curl(["-k", "-w", " %{http_code} %{http_version}", "https://127.0.0.1:\(https)/"])
        #expect(output.stdout == "<h1>home</h1> 200 1.1", "\(output.stderr)")
        output = try await curl(["-k", "--http3-only", "-w", " %{http_code} %{http_version}", "https://127.0.0.1:\(https)/"], h3: true)
        #expect(output.stdout == "<h1>home</h1> 200 3", "\(output.stderr)")
        output = try await curl(["-k", "--http3-only", "-w", "%{http_code}", "-o", "/dev/null", "https://127.0.0.1:\(https)/missing"], h3: true)
        #expect(output.stdout == "404")

        child.signal(SIGTERM)
        #expect(try await child.waitForExit(timeout: .seconds(15)) == 0, "\(child.stderr)")
    }

    /// The `alt-svc` header values in a `curl -i`/`-I` head.
    func altSvc(_ output: String) -> [String] {
        output.split(separator: "\r\n").filter { $0.lowercased().hasPrefix("alt-svc: ") }.map { String($0.dropFirst(9)) }
    }

    /// #0103: HTTPS responses advertise HTTP/3 on the UDP port with the configured max age;
    /// cleartext and HTTP/3 responses do not. Homebrew curl with an alt-svc cache uses HTTP/1.1
    /// first and HTTP/3 for the second request.
    @Test(.timeLimit(.minutes(1)), .enabled(if: hasH3Curl))
    func altSvcOnHTTPSOnlyAndCurlUpgradesToHTTP3() async throws {
        let fixture = try ParityTests.Fixture(config: try Self.tlsConfig(http3: #"{"altSvcMaxAge": 600}"#))
        let child = try ParityTests.launch(["--config", fixture.configPath, "--port", "0"])
        defer { child.kill() }
        let ports = try await Self.ports(child, expecting: 3)
        let https = try #require(ports.https)
        let h3 = try #require(ports.h3)

        var output = try await curl(["-k", "-i", "https://127.0.0.1:\(https)/"])
        #expect(altSvc(output.stdout) == ["h3=\":\(h3)\"; ma=600"], "\(output.stdout)")
        output = try await curl(["-k", "-I", "https://127.0.0.1:\(https)/missing"])
        #expect(altSvc(output.stdout) == ["h3=\":\(h3)\"; ma=600"], "error pages too: \(output.stdout)")
        output = try await curl(["-i", "http://127.0.0.1:\(ports.http)/"])
        #expect(output.stdout.hasPrefix("HTTP/1.1 200"), "\(output.stdout)")
        #expect(altSvc(output.stdout).isEmpty, "never on cleartext")
        output = try await curl(["-k", "-i", "--http3-only", "https://127.0.0.1:\(h3)/"], h3: true)
        #expect(output.stdout.hasPrefix("HTTP/3 200"), "\(output.stdout)")
        #expect(altSvc(output.stdout).isEmpty, "never on HTTP/3 itself")

        // curl --alt-svc: the first request learns the alternative, the second uses it.
        let cache = fixture.root.appending(path: "altsvc.txt").path
        var versions: [String] = []
        for _ in 0..<2 {
            output = try await curl(["-k", "--alt-svc", cache, "-o", "/dev/null", "-w", "%{http_version}",
                                     "https://127.0.0.1:\(https)/"], h3: true)
            versions.append(output.stdout)
        }
        #expect(versions == ["1.1", "3"], "\(output.stderr)")

        child.signal(SIGTERM)
        #expect(try await child.waitForExit(timeout: .seconds(15)) == 0, "\(child.stderr)")
    }

    /// Without `http3` there is no `Alt-Svc`, even over TLS.
    @Test(.timeLimit(.minutes(1)))
    func noAltSvcWithoutHTTP3() async throws {
        let fixture = try ParityTests.Fixture(config: try Self.tlsConfig(http3: nil))
        let child = try ParityTests.launch(["--config", fixture.configPath, "--port", "0"])
        defer { child.kill() }
        let ports = try await Self.ports(child, expecting: 2)
        #expect(ports.h3 == nil)
        let output = try await curl(["-k", "-i", "https://127.0.0.1:\(try #require(ports.https))/"])
        #expect(output.stdout.hasPrefix("HTTP/1.1 200"), "\(output.stdout)")
        #expect(altSvc(output.stdout).isEmpty)
        child.signal(SIGTERM)
        #expect(try await child.waitForExit(timeout: .seconds(15)) == 0, "\(child.stderr)")
    }

    /// `http3.port` set apart from the TLS port.
    @Test(.timeLimit(.minutes(1)), .enabled(if: hasH3Curl))
    func http3OnItsOwnPort() async throws {
        let fixture = try ParityTests.Fixture(config: try Self.tlsConfig(http3: #"{"port": 0}"#))
        let child = try ParityTests.launch(["--config", fixture.configPath, "--port", "0"])
        defer { child.kill() }
        let ports = try await Self.ports(child, expecting: 3)
        let h3 = try #require(ports.h3)
        let output = try await curl(["-k", "--http3-only", "-w", " %{http_version}", "https://127.0.0.1:\(h3)/"], h3: true)
        #expect(output.stdout == "<h1>home</h1> 3", "\(output.stderr)")
        child.signal(SIGTERM)
        #expect(try await child.waitForExit(timeout: .seconds(15)) == 0, "\(child.stderr)")
    }

    /// SIGTERM while an HTTP/3 download is in flight: the server sends GOAWAY, the download
    /// completes, and the process exits 0.
    @Test(.timeLimit(.minutes(1)), .enabled(if: hasH3Curl))
    func sigtermDuringAnHTTP3DownloadFinishesItAndExitsZero() async throws {
        let fixture = try ParityTests.Fixture(config: try Self.tlsConfig(drainTimeout: 30))
        let size: UInt64 = 24 * 1024 * 1024
        let large = fixture.publicDirectory.appending(path: "large.bin")
        FileManager.default.createFile(atPath: large.path, contents: nil)
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: size)   // sparse
        try handle.close()

        let child = try ParityTests.launch(["--config", fixture.configPath, "--port", "0"])
        defer { child.kill() }
        let h3 = try #require(try await Self.ports(child, expecting: 3).h3)

        // About 3 s at 8 MB/s.
        let download = try ChildProcess(executable: URL(fileURLWithPath: Self.h3Curl), arguments: [
            "-sSk", "--http3-only", "--max-time", "30", "--limit-rate", "8M", "-o", "/dev/null",
            "-w", "%{http_code} %{size_download} %{http_version}", "https://127.0.0.1:\(h3)/large.bin"])
        defer { download.kill() }
        try await Task.sleep(for: .milliseconds(800))
        #expect(download.exitStatus == nil, "the download is still running when SIGTERM arrives")
        let signalled = ContinuousClock.now
        child.signal(SIGTERM)

        #expect(try await download.waitForExit(timeout: .seconds(40)) == 0, "\(download.stderr)")
        #expect(download.stdout == "200 \(size) 3", "\(download.stderr)")
        #expect(try await child.waitForExit(timeout: .seconds(40)) == 0, "\(child.stderr)")
        #expect(ContinuousClock.now - signalled > .seconds(1), "the drain waited for the download")
    }

    // MARK: Startup failures

    /// The TLS port is in use: the process exits 1 and the cleartext port it had bound is not
    /// left listening.
    @Test(.timeLimit(.minutes(1)))
    func tlsPortInUseExitsOneAndClosesTheCleartextPort() async throws {
        let tcp = TCPConfiguration(allowLocalEndpointReuse: false)
        let holder = try TCPListener(configuration: .init(host: "127.0.0.1", port: 0, tcp: tcp))
        let held = try await holder.start()
        // A port that was free a moment ago, for the cleartext listener.
        let probe = try TCPListener(configuration: .init(host: "127.0.0.1", port: 0, tcp: tcp))
        let cleartext = try await probe.start()
        await probe.close()

        let config = #"{"drainTimeout": 1, "tls": {"identity": "\#(try Self.identityPath())", "password": "\#(TestIdentity.password)", "port": \#(held)}}"#
        let fixture = try ParityTests.Fixture(config: config)
        let child = try ParityTests.launch(["--config", fixture.configPath, "--port", String(cleartext)])
        defer { child.kill() }
        #expect(try await child.waitForExit(timeout: .seconds(10)) == 1)
        #expect(child.stderr.contains("cannot serve on"), "\(child.stderr)")
        #expect(child.stdout.isEmpty)
        await holder.close()

        let lsof = try await ChildProcess.run(URL(fileURLWithPath: "/usr/sbin/lsof"),
                                              ["-nP", "-iTCP:\(cleartext)", "-sTCP:LISTEN"], timeout: .seconds(20))
        #expect(lsof.stdout.isEmpty, "port \(cleartext) still listening: \(lsof.stdout)")
    }

    /// Configuration errors for `tls` and `http3` exit 1 with a message naming the problem.
    @Test(.timeLimit(.minutes(1)), arguments: [
        (#"{"http3": true}"#, "\"http3\" needs \"tls\""),
        (#"{"tls": {"password": "x"}}"#, "\"tls.identity\""),
        (#"{"tls": {"identity": "id.p12"}}"#, "\"tls.password\""),
        (#"{"tls": {"identity": "id.p12", "password": "x", "passwordEnv": "Y"}}"#, "not both"),
        (#"{"tls": {"identity": "id.p12", "password": "x", "port": 70000}}"#, "\"tls.port\""),
        (#"{"port": 9123, "tls": {"identity": "id.p12", "password": "x", "port": 9123}}"#, "\"tls.port\" 9123"),
        (#"{"tls": {"identity": "missing.p12", "password": "x", "port": 0}}"#, "cannot load TLS identity"),
        (#"{"tls": {"identity": "id.p12", "passwordEnv": "SWS_TEST_UNSET_VARIABLE", "port": 0}}"#, "SWS_TEST_UNSET_VARIABLE is not set"),
        ("WRONG_PASSWORD", "wrong password"),
        (#"{"tls": {"identity": "id.p12", "password": "x"}, "http3": {"altSvcMaxAge": -1}}"#, "\"http3.altSvcMaxAge\""),
        (#"{"tls": {"identity": "id.p12", "password": "x"}, "http3": {"port": "443"}}"#, "\"http3.port\""),
    ])
    func tlsAndHTTP3ConfigErrorsExitOne(config: String, message: String) async throws {
        let text = config == "WRONG_PASSWORD"
            ? #"{"tls": {"identity": "\#(try Self.identityPath())", "password": "not-the-password", "port": 0}}"#
            : config
        let fixture = try ParityTests.Fixture(config: text)
        // Keep the config's cleartext port when the case is about it; `--port` would override it.
        let portFlag = text.hasPrefix(#"{"port""#) ? [] : ["--port", "0"]
        let child = try ParityTests.launch(["--config", fixture.configPath] + portFlag)
        defer { child.kill() }
        #expect(try await child.waitForExit(timeout: .seconds(10)) == 1)
        #expect(child.stderr.contains(message), "stderr: \(child.stderr)")
        #expect(child.stdout.isEmpty)
    }
}
