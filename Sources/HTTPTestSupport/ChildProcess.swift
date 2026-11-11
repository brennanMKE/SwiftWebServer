public import Foundation
import Synchronization

/// A child process for tests (#0114): a server under test, or a client such as curl.
///
/// Nothing here blocks a thread of the cooperative pool. Output arrives through
/// `FileHandle.readabilityHandler` and the exit through `Process.terminationHandler`, both on
/// Foundation's own threads, and waiters suspend on continuations. Every wait has a hard
/// deadline and observes task cancellation (the cancellation behind `.timeLimit`): on a
/// timeout or a cancellation the child gets SIGKILL. ``kill()`` (for `defer`) and `deinit`
/// SIGKILL a child that is still running; Foundation reaps it.
public final class ChildProcess: Sendable {
    public enum Failure: Error, Sendable, CustomStringConvertible {
        case executableNotFound([String])
        case exitedEarly(status: Int32, stderr: String)
        case timedOut(String)

        public var description: String {
            switch self {
            case .executableNotFound(let paths): "executable not found in \(paths)"
            case .exitedEarly(let status, let stderr): "child exited early with \(status); stderr: \(stderr)"
            case .timedOut(let what): "timed out: \(what)"
            }
        }
    }

    /// The finished run of a short-lived tool.
    public struct Output: Sendable {
        public var status: Int32
        public var stdout: String
        public var stderr: String
    }

    struct Exit {
        var status: Int32
        var reason: Process.TerminationReason
    }

    struct State {
        var exit: Exit?
        var stdout = Data()
        var stderr = Data()
        var stdoutOpen = true
        var stderrOpen = true
        var killed = false
        var waiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
        var cancelled: Set<UInt64> = []
        var nextWaiter: UInt64 = 0

        var outputClosed: Bool { !stdoutOpen && !stderrOpen }

        /// Takes every waiter, to resume outside the lock after a change.
        mutating func takeWaiters() -> [CheckedContinuation<Void, Never>] {
            defer { waiters.removeAll() }
            return Array(waiters.values)
        }
    }

    /// State shared with the Foundation handlers. Kept apart from `ChildProcess` so the
    /// handlers do not keep the child object alive.
    final class Shared: Sendable {
        let state = Mutex(State())

        func update(_ body: (inout State) -> Void) {
            let waiters = state.withLock { state in
                body(&state)
                return state.takeWaiters()
            }
            for waiter in waiters { waiter.resume() }
        }
    }

    private let process: Process
    private let shared: Shared
    /// The child's process id.
    public let pid: Int32

    /// Starts `executable` with `arguments`, standard input from /dev/null, and both output
    /// streams captured (into one buffer, `stdout`, when `mergeStandardError`).
    public init(executable: URL, arguments: [String], mergeStandardError: Bool = false) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        let shared = Shared()
        self.shared = shared
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            shared.update { if data.isEmpty { $0.stdoutOpen = false } else { $0.stdout.append(data) } }
        }
        if mergeStandardError {
            process.standardError = stdoutPipe
            shared.update { $0.stderrOpen = false }
        } else {
            let stderrPipe = Pipe()
            process.standardError = stderrPipe
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil }
                shared.update { if data.isEmpty { $0.stderrOpen = false } else { $0.stderr.append(data) } }
            }
        }
        process.terminationHandler = { process in
            let exit = Exit(status: process.terminationStatus, reason: process.terminationReason)
            shared.update { $0.exit = exit }
        }
        try process.run()
        self.process = process
        pid = process.processIdentifier
    }

    deinit { kill() }

    public var stdout: String { shared.state.withLock { String(decoding: $0.stdout, as: UTF8.self) } }
    public var stderr: String { shared.state.withLock { String(decoding: $0.stderr, as: UTF8.self) } }
    /// The exit status, once the child has exited.
    public var exitStatus: Int32? { shared.state.withLock { $0.exit?.status } }
    /// Why the child ended, once it has exited.
    public var terminationReason: Process.TerminationReason? { shared.state.withLock { $0.exit?.reason } }

    /// Sends `number` to the child if it has not exited.
    public func signal(_ number: Int32) {
        shared.state.withLock { state in
            if state.exit == nil { _ = Foundation.kill(pid, number) }
        }
    }

    /// SIGKILLs the child if it has not exited. Does not block; Foundation reaps the child.
    public func kill() {
        shared.state.withLock { state in
            if state.exit == nil, !state.killed {
                state.killed = true
                _ = Foundation.kill(pid, SIGKILL)
            }
        }
    }

    /// The exit status, once the child exits within `timeout` and its output is read. On a
    /// timeout or a cancellation the child is SIGKILLed and reaped before this throws.
    @discardableResult
    public func waitForExit(timeout: Duration) async throws -> Int32 {
        let deadline = ContinuousClock.now + timeout
        do {
            guard try await wait(until: deadline, { $0.exit != nil }) else {
                throw Failure.timedOut("child \(pid) still running after \(timeout)")
            }
        } catch {
            await killAndReap()
            throw error
        }
        // Collect what is left in the pipes; bounded in case something else holds them open.
        _ = try? await wait(until: ContinuousClock.now + .seconds(2), { $0.outputClosed })
        return shared.state.withLock { $0.exit!.status }
    }

    /// Suspends until `stdout` holds a line that `parse` accepts; fails if the child exits
    /// first or `timeout` passes, SIGKILLing it on a timeout or a cancellation.
    public func waitForLine<T: Sendable>(
        timeout: Duration = .seconds(10), _ parse: @escaping @Sendable (Substring) -> T?
    ) async throws -> T {
        let found: @Sendable (State) -> T? = { state in
            String(decoding: state.stdout, as: UTF8.self).split(separator: "\n").lazy.compactMap(parse).first
        }
        let deadline = ContinuousClock.now + timeout
        do {
            _ = try await wait(until: deadline, { found($0) != nil || $0.exit != nil })
        } catch {
            await killAndReap()
            throw error
        }
        if let value = shared.state.withLock({ found($0) }) { return value }
        if let status = exitStatus {
            _ = try? await wait(until: ContinuousClock.now + .seconds(1), { $0.outputClosed })
            throw Failure.exitedEarly(status: status, stderr: stderr)
        }
        await killAndReap()
        throw Failure.timedOut("no matching output line after \(timeout); stderr: \(stderr)")
    }

    /// Runs a short-lived tool to completion within `timeout`; SIGKILLs it on a timeout or a
    /// cancellation.
    public static func run(
        _ executable: URL, _ arguments: [String], timeout: Duration = .seconds(30), mergeStandardError: Bool = false
    ) async throws -> Output {
        let child = try ChildProcess(executable: executable, arguments: arguments, mergeStandardError: mergeStandardError)
        defer { child.kill() }
        let status = try await child.waitForExit(timeout: timeout)
        return Output(status: status, stdout: child.stdout, stderr: child.stderr)
    }

    /// SIGKILL, then wait (without honouring cancellation, bounded) for Foundation to reap.
    private func killAndReap() async {
        kill()
        let deadline = ContinuousClock.now + .seconds(5)
        await Task { [self] in _ = try? await wait(until: deadline, { $0.exit != nil }) }.value
    }

    /// Suspends until `condition` holds (true) or `deadline` passes (false). Cancellation
    /// throws `CancellationError`.
    private func wait(
        until deadline: ContinuousClock.Instant, _ condition: @escaping @Sendable (State) -> Bool
    ) async throws -> Bool {
        if shared.state.withLock({ condition($0) }) { return true }
        try Task.checkCancellation()
        let shared = shared
        _ = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                await Self.changes(of: shared, until: condition)
                return true
            }
            group.addTask {
                try await Task.sleep(until: deadline, clock: .continuous)
                return false
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
        if shared.state.withLock({ condition($0) }) { return true }
        try Task.checkCancellation()
        return false
    }

    /// Suspends until `condition` holds or the task is cancelled.
    private static func changes(of shared: Shared, until condition: @Sendable (State) -> Bool) async {
        while !Task.isCancelled {
            let id = shared.state.withLock { state in
                defer { state.nextWaiter += 1 }
                return state.nextWaiter
            }
            await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    let resumeNow = shared.state.withLock { state -> Bool in
                        if condition(state) || state.cancelled.remove(id) != nil { return true }
                        state.waiters[id] = continuation
                        return false
                    }
                    if resumeNow { continuation.resume() }
                }
            } onCancel: {
                let waiter = shared.state.withLock { state in
                    if let waiter = state.waiters.removeValue(forKey: id) { return waiter as CheckedContinuation? }
                    state.cancelled.insert(id)
                    return nil
                }
                waiter?.resume()
            }
            if shared.state.withLock({ condition($0) }) { return }
        }
    }
}
