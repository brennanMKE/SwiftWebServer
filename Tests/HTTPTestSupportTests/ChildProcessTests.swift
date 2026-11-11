import Foundation
import HTTPTestSupport
import Testing

/// #0114: child-process waits never block the cooperative pool, have hard deadlines, observe
/// cancellation, and leave no child behind.
@Suite(.timeLimit(.minutes(1)))
struct ChildProcessTests {
    static let sleep = URL(fileURLWithPath: "/bin/sleep")
    static let shell = URL(fileURLWithPath: "/bin/sh")

    @Test func runCapturesOutputAndStatus() async throws {
        let output = try await ChildProcess.run(Self.shell, ["-c", "echo out; echo err >&2; exit 3"],
                                                timeout: .seconds(20))
        #expect(output.status == 3)
        #expect(output.stdout == "out\n")
        #expect(output.stderr == "err\n")
    }

    @Test func mergedStandardErrorGoesToStdout() async throws {
        let output = try await ChildProcess.run(Self.shell, ["-c", "echo a; echo b >&2"],
                                                timeout: .seconds(20), mergeStandardError: true)
        #expect(output.stdout.contains("a\n") && output.stdout.contains("b\n"))
        #expect(output.stderr.isEmpty)
    }

    @Test func timeoutKillsAndReapsTheChild() async throws {
        let child = try ChildProcess(executable: Self.sleep, arguments: ["60"])
        let start = ContinuousClock.now
        await #expect(throws: ChildProcess.Failure.self) {
            try await child.waitForExit(timeout: .milliseconds(200))
        }
        #expect(ContinuousClock.now - start < .seconds(10))
        #expect(child.terminationReason == .uncaughtSignal)
        #expect(Foundation.kill(child.pid, 0) == -1)
    }

    @Test func cancellationKillsAndReapsTheChild() async throws {
        let child = try ChildProcess(executable: Self.sleep, arguments: ["60"])
        let waiter = Task { try await child.waitForExit(timeout: .seconds(60)) }
        try await Task.sleep(for: .milliseconds(100))
        let start = ContinuousClock.now
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(ContinuousClock.now - start < .seconds(10))
        #expect(child.terminationReason == .uncaughtSignal)
        #expect(Foundation.kill(child.pid, 0) == -1)
    }

    @Test func waitForLineFailsWhenTheChildExitsFirst() async throws {
        let child = try ChildProcess(executable: Self.shell, arguments: ["-c", "echo nope; echo why >&2; exit 2"])
        defer { child.kill() }
        do {
            _ = try await child.waitForLine(timeout: .seconds(20)) { $0 == "ready" ? true : nil }
            Issue.record("expected exitedEarly")
        } catch ChildProcess.Failure.exitedEarly(let status, let stderr) {
            #expect(status == 2)
            #expect(stderr == "why\n")
        }
    }

    @Test func waitForLineFindsALineFromALiveChild() async throws {
        let child = try ChildProcess(executable: Self.shell, arguments: ["-c", "echo listening 7; exec sleep 60"])
        defer { child.kill() }
        let value = try await child.waitForLine(timeout: .seconds(20)) { line in
            line.hasPrefix("listening ") ? Int(line.dropFirst(10)) : nil
        }
        #expect(value == 7)
        child.kill()
        await #expect(throws: Never.self) { try await child.waitForExit(timeout: .seconds(10)) }
        #expect(child.terminationReason == .uncaughtSignal)
    }
}
