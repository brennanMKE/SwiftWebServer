import Darwin
import Synchronization

/// Counts heap allocations on macOS.
///
/// Method: libmalloc exports a global function pointer, `malloc_logger`, that it
/// calls on every allocation and free in every malloc zone when non-NULL (this is
/// the hook `MallocStackLogging` uses). We look it up with `dlsym`, point it at a
/// C-convention callback that increments an atomic counter for events carrying
/// `MALLOC_LOG_TYPE_ALLOCATE` (0x2; realloc reports allocate|deallocate and counts
/// once), run the closure, and restore the previous value.
///
/// Why not `malloc_zone_statistics` or `mstats`: both report blocks/bytes *in use*,
/// so a transient allocate-then-free inside the loop nets to zero and is invisible.
/// `HeapStatistics.blocksInUse()` (from `malloc_zone_statistics`) is still recorded
/// as a "retained blocks per op" figure, which catches leaks and growth.
///
/// Caveats: the counter is process-wide, so allocations by other threads during the
/// pass (Network.framework, the Swift runtime) are included; the micro command is
/// single-threaded, so this is normally zero. If a logger is already installed
/// (e.g. `MallocStackLogging=1`), counting is skipped and reported as unavailable.
enum AllocationCounter {
    typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

    /// Address of libmalloc's `malloc_logger` variable, if exported.
    nonisolated(unsafe) private static let loggerSlot: UnsafeMutablePointer<Logger?>? = {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let symbol = dlsym(rtldDefault, "malloc_logger") else { return nil }
        return symbol.assumingMemoryBound(to: Logger?.self)
    }()

    static var isAvailable: Bool { loggerSlot != nil }

    /// Number of heap allocations made while `body` runs, or nil if unavailable.
    static func count(_ body: () -> Void) -> Int? {
        guard let slot = loggerSlot, slot.pointee == nil else { return nil }
        let start = allocationEvents.load(ordering: .relaxed)
        slot.pointee = countingLogger
        body()
        slot.pointee = nil
        return allocationEvents.load(ordering: .relaxed) - start
    }

    /// Like ``count(_:)`` for async work. Process-wide: allocations made by other threads
    /// (Network.framework's queues, the cooperative pool) while `body` runs are included,
    /// which is what transport benchmarks want.
    static func countAsync(_ body: () async throws -> Void) async rethrows -> Int? {
        guard let slot = loggerSlot, slot.pointee == nil else {
            try await body()
            return nil
        }
        let start = allocationEvents.load(ordering: .relaxed)
        slot.pointee = countingLogger
        defer { slot.pointee = nil }
        try await body()
        return allocationEvents.load(ordering: .relaxed) - start
    }
}

private let allocationEvents = Atomic<Int>(0)

private let countingLogger: AllocationCounter.Logger = { type, _, _, _, _, _ in
    if type & 0x2 != 0 { // MALLOC_LOG_TYPE_ALLOCATE
        allocationEvents.add(1, ordering: .relaxed)
    }
}

enum HeapStatistics {
    /// Live blocks across all malloc zones (`malloc_zone_statistics(NULL, ...)`).
    static func blocksInUse() -> Int? {
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return Int(stats.blocks_in_use)
    }
}
