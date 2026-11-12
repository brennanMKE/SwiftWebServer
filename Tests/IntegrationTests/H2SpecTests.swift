import Foundation
import HTTPTestSupport
import Testing

/// #0061: the h2spec HTTP/2 conformance suite against `sws-bench serve --h2-only`, through
/// `scripts/h2spec.sh` (which starts the server on 127.0.0.1 port 0, runs h2spec and stops
/// the server, with a watchdog in case the script itself is killed). Skipped when h2spec is
/// not installed (`brew install h2spec`).
@Suite(.serialized) struct H2SpecTests {
    static let h2spec = ["/opt/homebrew/bin/h2spec", "/usr/local/bin/h2spec"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }
    static var hasH2Spec: Bool { h2spec != nil }

    static var script: URL {
        URL(fileURLWithPath: TestIdentity.repositoryRoot).appending(path: "scripts/h2spec.sh")
    }

    /// Runs the script (strict cases included) and returns its output.
    static func run(tls: Bool) async throws -> ChildProcess.Output {
        var arguments = ["--bin", try ChildProcess.executable().path, "--h2spec", h2spec ?? "h2spec"]
        if tls {
            _ = try TestIdentity.load()  // Creates the gitignored identity on first use.
            arguments.append("--tls")
        }
        arguments += ["--", "-S"]
        return try await ChildProcess.run(URL(fileURLWithPath: "/bin/bash"), [script.path] + arguments,
                                          timeout: .seconds(150), mergeStandardError: true)
    }

    static func check(_ output: ChildProcess.Output) {
        #expect(output.status == 0, "\(output.stdout)")
        let summary = output.stdout.split(separator: "\n").last { $0.contains(" tests, ") } ?? ""
        #expect(summary.hasSuffix(" 0 failed"), "\(output.stdout)")
    }

    @Test(.timeLimit(.minutes(3)), .enabled(if: hasH2Spec))
    func cleartextPriorKnowledgePasses() async throws {
        Self.check(try await Self.run(tls: false))
    }

    @Test(.timeLimit(.minutes(3)), .enabled(if: hasH2Spec))
    func tlsPasses() async throws {
        Self.check(try await Self.run(tls: true))
    }
}
