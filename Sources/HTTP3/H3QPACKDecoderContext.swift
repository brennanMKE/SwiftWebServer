import QPACK
import Synchronization

/// A connection's QPACK dynamic table state when ``H3Configuration/qpackMaxTableCapacity`` is
/// non-zero (#0106): one ``QPACKDynamicDecoder`` behind a `Mutex`, shared by the encoder
/// stream reader and the request streams.
///
/// Every critical section is non-suspending (ROADMAP §2): applying encoder instructions,
/// admitting a field section, decoding it (the sink copies the fields into the request's
/// storage), and taking decoder stream bytes. Continuations are resumed outside the lock.
///
/// A request stream whose field section needs inserts that have not arrived waits in
/// ``waitForInserts(_:)``; at most ``H3Configuration/qpackBlockedStreams`` streams wait at
/// once (more is `QPACK_DECOMPRESSION_FAILED`). Waiters are resumed when the encoder stream
/// delivers the inserts, or with `false` when their task is cancelled.
///
/// Decoder stream bytes (Section Acknowledgment, Stream Cancellation, Insert Count Increment)
/// queue in the decoder; one task at a time sends them (``beginFlush()`` /
/// ``nextFlush(_:)``), so our decoder stream is written in order without a writer task.
final class H3QPACKDecoderContext: Sendable {
    struct Waiter {
        let id: UInt64
        let requiredInsertCount: UInt64
        let continuation: CheckedContinuation<Bool, Never>
    }

    struct State {
        var decoder: QPACKDynamicDecoder
        var waiters: [Waiter] = []
        var nextWaiterID: UInt64 = 0
        /// A task is sending decoder stream bytes.
        var flushing = false
    }

    let state: Mutex<State>

    /// Queued decoder stream bytes beyond which the peer is not reading our decoder stream:
    /// the connection is closed with `H3_EXCESSIVE_LOAD` rather than buffering more.
    static let maxPendingDecoderStreamBytes = 64 * 1024

    init(configuration: H3Configuration) {
        state = Mutex(State(decoder: QPACKDynamicDecoder(
            maxTableCapacity: configuration.qpackMaxTableCapacity,
            maxBlockedStreams: configuration.qpackBlockedStreams,
            maxFieldSectionSize: configuration.maxFieldSectionSize)))
    }

    /// The longest string an encoder instruction may carry, bounding what the encoder stream
    /// reader buffers.
    var maxInstructionStringLength: Int { state.withLock { $0.decoder.maxInstructionStringLength } }

    // MARK: Encoder stream

    /// Applies the complete encoder instructions at the start of `bytes` and wakes the streams
    /// whose inserts have now arrived.
    func consumeEncoderStream(
        _ bytes: UnsafeRawBufferPointer
    ) throws(QPACKError) -> (consumed: Int, instructions: Int, inserts: Int) {
        let (result, ready) = try state.withLock { (state) throws(QPACKError) -> ((Int, Int, Int), [Waiter]) in
            let before = state.decoder.table.insertCount
            let (consumed, instructions) = try state.decoder.consumeEncoderStream(bytes)
            let inserts = state.decoder.table.insertCount
            let result = (consumed, instructions, Int(inserts &- before))
            guard state.waiters.contains(where: { $0.requiredInsertCount <= inserts }) else { return (result, []) }
            var ready: [Waiter] = []
            state.waiters.removeAll { waiter in
                guard waiter.requiredInsertCount <= inserts else { return false }
                ready.append(waiter)
                return true
            }
            return (result, ready)
        }
        for waiter in ready { waiter.continuation.resume(returning: true) }
        return result
    }

    // MARK: Request streams

    /// See ``QPACKDynamicDecoder/admit(_:)``.
    func admit(_ section: UnsafeRawBufferPointer) throws(QPACKError) -> QPACKDynamicDecoder.Admission {
        try state.withLock { (state) throws(QPACKError) in try state.decoder.admit(section) }
    }

    /// Waits until `requiredInsertCount` inserts have arrived (`true`) or the task is cancelled
    /// (`false`), then releases the blocked-stream slot ``admit(_:)`` took.
    func waitForInserts(_ requiredInsertCount: UInt64) async -> Bool {
        let id = state.withLock { state in
            defer { state.nextWaiterID &+= 1 }
            return state.nextWaiterID
        }
        let arrived = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                let resume = state.withLock { state -> Bool? in
                    if state.decoder.table.insertCount >= requiredInsertCount { return true }
                    if Task.isCancelled { return false }
                    state.waiters.append(Waiter(id: id, requiredInsertCount: requiredInsertCount,
                                                continuation: continuation))
                    return nil
                }
                if let resume { continuation.resume(returning: resume) }
            }
        } onCancel: {
            let waiter = state.withLock { state -> Waiter? in
                guard let index = state.waiters.firstIndex(where: { $0.id == id }) else { return nil }
                return state.waiters.remove(at: index)
            }
            waiter?.continuation.resume(returning: false)
        }
        state.withLock { $0.decoder.unblock() }
        return arrived
    }

    /// Decodes a field section whose inserts have arrived (see
    /// ``QPACKDynamicDecoder/decode(_:requiredInsertCount:streamID:into:)``).
    func decode<Sink: QPACKFieldSink>(
        _ section: UnsafeRawBufferPointer, requiredInsertCount: UInt64, streamID: UInt64, into sink: inout Sink
    ) throws(QPACKError) -> Int {
        try state.withLock { (state) throws(QPACKError) -> Int in
            try state.decoder.decode(section, requiredInsertCount: requiredInsertCount, streamID: streamID, into: &sink)
        }
    }

    /// Queues a Stream Cancellation for a stream abandoned before its sections were decoded.
    func cancelStream(_ streamID: UInt64) {
        state.withLock { $0.decoder.cancelStream(streamID) }
    }

    /// Whether the queued decoder stream bytes went past ``maxPendingDecoderStreamBytes``.
    var isDecoderStreamBacklogged: Bool {
        state.withLock { $0.decoder.pendingDecoderStreamBytes > Self.maxPendingDecoderStreamBytes }
    }

    // MARK: Decoder stream

    /// Claims the right to send decoder stream bytes; `false` when another task holds it (it
    /// will also send whatever is queued now).
    func beginFlush() -> Bool {
        state.withLock { state in
            guard !state.flushing else { return false }
            state.flushing = true
            return true
        }
    }

    /// The next decoder stream bytes to send, or `nil` (releasing the claim) when nothing is
    /// queued. With `failed`, releases the claim without taking anything.
    func nextFlush(failed: Bool = false) -> [UInt8]? {
        state.withLock { state in
            guard !failed, state.decoder.hasDecoderStreamOutput else {
                state.flushing = false
                return nil
            }
            var bytes: [UInt8] = []
            state.decoder.takeDecoderStreamOutput(into: &bytes)
            return bytes
        }
    }
}

/// Decodes one request stream's field section through the connection's dynamic table.
struct H3DynamicSectionDecoder: QPACKSectionDecoder {
    let context: H3QPACKDecoderContext
    let streamID: UInt64
    let requiredInsertCount: UInt64

    mutating func decode<Sink: QPACKFieldSink>(
        _ section: UnsafeRawBufferPointer, into sink: inout Sink
    ) throws(QPACKError) -> Int {
        try context.decode(section, requiredInsertCount: requiredInsertCount, streamID: streamID, into: &sink)
    }
}
