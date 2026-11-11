import Dispatch

/// A `TaskExecutor` that runs jobs on a connection's serial `DispatchQueue` (the ROADMAP §7
/// experiment). With a task-executor preference set to it, a task resumed from a
/// Network.framework callback continues on the same queue instead of hopping to the global
/// cooperative pool. See docs/notes/nw-transport.md for the measurement.
final class QueueTaskExecutor: TaskExecutor, @unchecked Sendable {
    // @unchecked: `queue` is immutable and DispatchQueue is thread-safe.
    let queue: DispatchQueue

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedTaskExecutor()
        queue.async { job.runSynchronously(on: executor) }
    }
}
