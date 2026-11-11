#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Synchronization

/// Resolved files by raw request path, bounded and sharded (docs/ROADMAP.md §7, "memory-map
/// the file").
///
/// Each shard is a `Mutex` around a dictionary keyed by the 64-bit FNV-1a hash of the path,
/// so a lookup hashes the borrowed path bytes and allocates nothing; the entry's own key is
/// compared outside the lock. An entry is served without touching the file system for
/// ``revalidationInterval``; the first request after that re-checks it (others keep getting
/// the cached entry meanwhile). When a shard is full, inserting evicts a random entry.
final class FileCache: Sendable {
    struct Slot {
        var validatedAt: UInt64
        let file: CachedFile
    }

    final class Shard: Sendable {
        let slots = Mutex<[UInt64: Slot]>([:])
    }

    enum Lookup {
        case hit(CachedFile)
        /// Due for revalidation; this caller does it.
        case stale(CachedFile)
        case miss
    }

    let shards: [Shard]
    let shardMask: UInt64
    let capacityPerShard: Int
    let revalidationInterval: UInt64

    init(maxEntries: Int, revalidationInterval interval: Duration) {
        let count = maxEntries >= 64 ? 16 : 1
        shards = (0..<count).map { _ in Shard() }
        shardMask = UInt64(count - 1)
        capacityPerShard = max(1, maxEntries / count)
        let (seconds, attoseconds) = interval.components
        revalidationInterval = UInt64(clamping: seconds) &* 1_000_000_000 &+ UInt64(clamping: attoseconds / 1_000_000_000)
    }

    @inline(__always)
    func shard(_ hash: UInt64) -> Shard {
        shards[Int(truncatingIfNeeded: (hash ^ (hash >> 32)) & shardMask)]
    }

    func lookup(_ hash: UInt64, now: UInt64) -> Lookup {
        let interval = revalidationInterval
        return shard(hash).slots.withLock { slots in
            guard let slot = slots[hash] else { return .miss }
            if now &- slot.validatedAt < interval { return .hit(slot.file) }
            slots[hash]!.validatedAt = now
            return .stale(slot.file)
        }
    }

    func insert(_ hash: UInt64, _ file: CachedFile, now: UInt64) {
        let capacity = capacityPerShard
        shard(hash).slots.withLock { slots in
            if slots[hash] == nil, slots.count >= capacity, let victim = slots.keys.randomElement() {
                slots.removeValue(forKey: victim)
            }
            slots[hash] = Slot(validatedAt: now, file: file)
        }
    }

    func remove(_ hash: UInt64) {
        shard(hash).slots.withLock { _ = $0.removeValue(forKey: hash) }
    }

    var count: Int {
        shards.reduce(0) { total, shard in total + shard.slots.withLock { $0.count } }
    }

    /// 64-bit FNV-1a of `bytes`.
    @inline(__always)
    static func hash(_ bytes: Span<UInt8>) -> UInt64 {
        var value: UInt64 = 0xCBF2_9CE4_8422_2325
        for i in 0..<bytes.count {
            value = (value ^ UInt64(bytes[i])) &* 0x0000_0100_0000_01B3
        }
        return value
    }

    /// A cheap monotonic clock in nanoseconds (the coarse uptime clock on Darwin).
    @inline(__always)
    static func now() -> UInt64 {
        #if canImport(Darwin)
        clock_gettime_nsec_np(CLOCK_UPTIME_RAW_APPROX)
        #else
        var time = timespec()
        clock_gettime(CLOCK_MONOTONIC_COARSE, &time)
        return UInt64(time.tv_sec) &* 1_000_000_000 &+ UInt64(time.tv_nsec)
        #endif
    }
}
