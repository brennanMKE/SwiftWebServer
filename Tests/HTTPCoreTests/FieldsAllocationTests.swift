import Darwin
import Synchronization
import Testing
import HTTPCore

/// Counts heap allocations made by the current thread while a closure runs.
///
/// libmalloc calls the exported `malloc_logger` function pointer on every allocation when it
/// is set (the hook MallocStackLogging uses). The callback counts only events from the thread
/// that installed it, so allocations by other tests running in parallel are ignored. The
/// closure must not suspend. Returns `nil` when the hook is unavailable or already in use.
enum ThreadAllocationCounter {
    typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

    nonisolated(unsafe) static let slot: UnsafeMutablePointer<Logger?>? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return nil }
        return symbol.assumingMemoryBound(to: Logger?.self)
    }()

    static let lock = Mutex(())

    static func count(_ body: () -> Void) -> Int? {
        lock.withLock { _ -> Int? in
            guard let slot, slot.pointee == nil else { return nil }
            countedThread.store(pthread_mach_thread_np(pthread_self()), ordering: .relaxed)
            let start = allocationEvents.load(ordering: .relaxed)
            slot.pointee = countingLogger
            body()
            slot.pointee = nil
            countedThread.store(0, ordering: .relaxed)
            return allocationEvents.load(ordering: .relaxed) - start
        }
    }
}

private let allocationEvents = Atomic<Int>(0)
private let countedThread = Atomic<UInt32>(0)

private let countingLogger: ThreadAllocationCounter.Logger = { type, _, _, _, _, _ in
    // MALLOC_LOG_TYPE_ALLOCATE; realloc reports allocate|deallocate and counts once.
    guard type & 0x2 != 0 else { return }
    guard pthread_mach_thread_np(pthread_self()) == countedThread.load(ordering: .relaxed) else { return }
    allocationEvents.add(1, ordering: .relaxed)
}

/// One heap allocation the optimizer cannot elide, for calibrating the counter.
@inline(never) @_optimize(none)
private func opaqueAllocate() {
    free(malloc(16))
}

@Suite struct FieldsAllocationTests {
    static let head = """
        Host: example.com\r
        User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)\r
        Accept: text/html,application/xhtml+xml\r
        Accept-Language: en-US,en;q=0.9\r
        Accept-Encoding: gzip, deflate, br\r
        Connection: keep-alive\r
        Cookie: session=abc123\r
        Cache-Control: max-age=0\r
        Upgrade-Insecure-Requests: 1\r
        X-Request-Id: 42
        """

    @Test func counterSeesAnAllocation() {
        guard let count = ThreadAllocationCounter.count({ opaqueAllocate() }) else {
            withKnownIssue("malloc_logger unavailable") { Issue.record("allocation counting unavailable") }
            return
        }
        #expect(count >= 1)
    }

    /// Refilling and clearing a 10-header request in warmed-up storage allocates nothing,
    /// and neither do well-known lookups.
    @Test func refillAndLookupDoNotAllocate() {
        let storage = HTTPRequestStorage(bufferCapacity: 4096, fieldCapacity: 32)
        FieldScanner.fill(storage, with: Self.head)
        let bytes = storage.buffer.writerIndex
        // Record the scanned ranges and hashes once so the measured loop does no String work.
        let fields = (0..<storage.fields.count).map { i in
            (storage.fields.nameViews[i], storage.buffer.withSpan(of: storage.fields.nameViews[i]) { ASCII.fnv1aLowercased($0) },
             storage.fields.valueViews[i])
        }
        var found = 0
        let count = ThreadAllocationCounter.count {
            for _ in 0..<1_000 {
                storage.endRequest()
                for (name, hash, value) in fields {
                    storage.appendField(nameView: name, hash: hash, valueView: value)
                }
                let view = storage.fieldsView
                if view.firstValue(for: .host) != nil { found += 1 }
                if view.contains(.contentLength) { found += 1 }
                if view.containsListElement("keep-alive", in: .connection) { found += 1 }
            }
        }
        #expect(found == 2_000)
        #expect(storage.buffer.writerIndex == bytes)
        guard let count else { return }
        #if DEBUG
        // Unoptimized builds box generic closures and do not specialize, so they allocate.
        // The zero-allocation guarantee is checked in release builds:
        // `swift test -c release --filter FieldsAllocationTests` (and `sws-bench` fields).
        _ = count
        #else
        #expect(count == 0, "\(count) allocations in 1000 refills")
        #endif
    }
}
