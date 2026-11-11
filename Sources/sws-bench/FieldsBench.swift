import Darwin
import HTTPCore
import Synchronization

/// HTTPFields / HTTPFieldName microbenchmarks (issue #0074). Not wired into `main` yet; the
/// harness calls `runFieldsBenchmarks()` and reports the results.
///
/// Each benchmark reuses one `HTTPRequestStorage` the way a connection does, so the steady
/// state is the hot path. `allocationsPerOp` comes from a `malloc_logger` hook (see
/// `FieldsAllocationCounter`); it is `nil` when the hook is unavailable. Once the shared
/// harness (#0070) lands, switch to its allocation counter.
func runFieldsBenchmarks(iterations: Int = 1_000_000) -> [(name: String, nanosecondsPerOp: Double, allocationsPerOp: Double?)] {
    let fixture = FieldsFixture()
    return [
        measureFields("fields.fill+clear 10-header request", iterations: iterations / 10, fixture.fillAndClear),
        measureFields("fields.scan+hash+fill 10-header request", iterations: iterations / 10, fixture.scanAndFill),
        measureFields("fieldname.lookup(hash:) well-known", iterations: iterations, fixture.lookupWellKnown),
        measureFields("fieldname.lookup(hash:) unknown", iterations: iterations, fixture.lookupUnknown),
        measureFields("fields.firstValue(for: .host)", iterations: iterations, fixture.firstValueHost),
        measureFields("fields.contains(.contentLength) miss", iterations: iterations, fixture.containsMiss),
        measureFields("fields.contentLength()", iterations: iterations, fixture.contentLength),
        measureFields("method.parse GET", iterations: iterations, fixture.parseMethod),
        measureFields("status.appendHTTP1StatusLine 200", iterations: iterations, fixture.statusLine),
        measureFields("httpfields.append 5 static + removeAll", iterations: iterations / 5, fixture.responseFields),
    ]
}

/// A typical browser request head plus reusable storage.
private final class FieldsFixture {
    static let head: StaticString = """
        Host: example.com\r
        User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)\r
        Accept: text/html,application/xhtml+xml\r
        Accept-Language: en-US,en;q=0.9\r
        Accept-Encoding: gzip, deflate, br\r
        Connection: keep-alive\r
        Cookie: session=abc123\r
        Cache-Control: max-age=0\r
        Upgrade-Insecure-Requests: 1\r
        Content-Length: 0\r
        \r

        """

    let storage = HTTPRequestStorage(bufferCapacity: 4096, fieldCapacity: 32)
    var scanned: [(name: ByteView, hash: UInt32, value: ByteView)] = []
    @exclusivity(unchecked) var response = HTTPFields(minimumCapacity: 16, arenaCapacity: 512)
    @exclusivity(unchecked) var output = ByteBuffer(capacity: 256)
    let hostName: [UInt8] = Array("Host".utf8)
    let hostHash = ASCII.fnv1aLowercased("Host")
    let unknownName: [UInt8] = Array("X-Custom-Header".utf8)
    let unknownHash = ASCII.fnv1aLowercased("X-Custom-Header")
    let method: [UInt8] = Array("GET".utf8)

    init() {
        storage.buffer.append(Self.head)
        scan()
        scanned = (0..<storage.fields.count).map { i in
            let name = storage.fields.nameViews[i]
            return (name, storage.buffer.withSpan(of: name) { ASCII.fnv1aLowercased($0) }, storage.fields.valueViews[i])
        }
    }

    /// Scans field lines, hashing each name in the same pass that finds `:` (what #0075 does).
    func scan() {
        storage.endRequest()
        let end = storage.buffer.writerIndex
        storage.buffer.withReadableSpan { bytes in
            var i = 0
            while i + 1 < end, bytes[i] != 0x0D {
                let nameStart = i
                var hasher = ASCII.FNV1a()
                while bytes[i] != UInt8(ascii: ":") {
                    hasher.combineLowercased(bytes[i])
                    i &+= 1
                }
                let nameEnd = i
                i &+= 1
                while bytes[i] == 0x20 { i &+= 1 }
                let valueStart = i
                while bytes[i] != 0x0D { i &+= 1 }
                storage.fields.append(
                    nameView: ByteView(offset: nameStart, length: nameEnd &- nameStart),
                    hash: hasher.value,
                    valueView: ByteView(offset: valueStart, length: i &- valueStart),
                    in: storage.buffer)
                i &+= 2
            }
        }
    }

    func fillAndClear(_ i: Int) -> UInt64 {
        storage.endRequest()
        for field in scanned {
            storage.appendField(nameView: field.name, hash: field.hash, valueView: field.value)
        }
        return UInt64(storage.fields.count)
    }

    func scanAndFill(_ i: Int) -> UInt64 {
        scan()
        return UInt64(storage.fields.count)
    }

    func lookupWellKnown(_ i: Int) -> UInt64 {
        UInt64(hostName.withUnsafeBufferPointer { HTTPFieldName.lookup(hash: hostHash &+ UInt32(i & 0), name: $0.span) }.rawValue)
    }

    func lookupUnknown(_ i: Int) -> UInt64 {
        UInt64(unknownName.withUnsafeBufferPointer { HTTPFieldName.lookup(hash: unknownHash &+ UInt32(i & 0), name: $0.span) }.rawValue)
    }

    func firstValueHost(_ i: Int) -> UInt64 {
        UInt64(storage.fieldsView.firstValue(for: .host)?.length ?? 0)
    }

    func containsMiss(_ i: Int) -> UInt64 {
        storage.fieldsView.contains(.transferEncoding) ? 1 : 0
    }

    func contentLength(_ i: Int) -> UInt64 {
        if case .value(let n) = storage.fieldsView.contentLength() { return n &+ 1 }
        return 0
    }

    func parseMethod(_ i: Int) -> UInt64 {
        method.withUnsafeBufferPointer { HTTPMethod($0.span) } == .get ? 1 : 0
    }

    func statusLine(_ i: Int) -> UInt64 {
        output.clear()
        HTTPStatus.ok.appendHTTP1StatusLine(to: &output)
        return UInt64(output.readableBytes)
    }

    func responseFields(_ i: Int) -> UInt64 {
        response.removeAll()
        response.append(.contentType, "text/html; charset=utf-8")
        response.append(.contentLength, decimal: i & 0xFFFF)
        response.append(.cacheControl, "no-cache")
        response.append(.server, "sws")
        response.append(.vary, "accept-encoding")
        return UInt64(response.count)
    }
}

/// Runs `body` `iterations` times and returns nanoseconds and allocations per call.
private func measureFields(
    _ name: String, iterations: Int, _ body: (Int) -> UInt64
) -> (name: String, nanosecondsPerOp: Double, allocationsPerOp: Double?) {
    var sink: UInt64 = 0
    for i in 0..<min(iterations, 10_000) { sink &+= body(i) }   // warm up
    let allocations = FieldsAllocationCounter.count {
        for i in 0..<1_000 { sink &+= body(i) }
    }
    let clock = ContinuousClock()
    let start = clock.now
    for i in 0..<iterations { sink &+= body(i) }
    let elapsed = start.duration(to: clock.now)
    fieldsBlackHole(sink)
    let (seconds, attoseconds) = elapsed.components
    let nanoseconds = Double(seconds) * 1e9 + Double(attoseconds) / 1e9
    return (name, nanoseconds / Double(iterations), allocations.map { Double($0) / 1_000 })
}

@inline(never)
private func fieldsBlackHole(_ value: UInt64) {
    if value == 0x5EED_5EED_5EED_5EED { print("") }
}

/// Counts heap allocations through libmalloc's exported `malloc_logger` hook, which it calls
/// on every allocation when set. Private to this file so it does not clash with the shared
/// harness counter.
private enum FieldsAllocationCounter {
    typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

    nonisolated(unsafe) static let slot: UnsafeMutablePointer<Logger?>? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return nil }
        return symbol.assumingMemoryBound(to: Logger?.self)
    }()

    static func count(_ body: () -> Void) -> Int? {
        guard let slot, slot.pointee == nil else { return nil }
        let start = fieldsAllocationEvents.load(ordering: .relaxed)
        slot.pointee = fieldsCountingLogger
        body()
        slot.pointee = nil
        return fieldsAllocationEvents.load(ordering: .relaxed) - start
    }
}

private let fieldsAllocationEvents = Atomic<Int>(0)

private let fieldsCountingLogger: FieldsAllocationCounter.Logger = { type, _, _, _, _, _ in
    if type & 0x2 != 0 { fieldsAllocationEvents.add(1, ordering: .relaxed) }   // MALLOC_LOG_TYPE_ALLOCATE
}
