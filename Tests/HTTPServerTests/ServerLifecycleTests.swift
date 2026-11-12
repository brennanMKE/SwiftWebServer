import HTTPCore
import HTTPServer
import Testing

/// Every (state, event) pair of `ServerLifecycle` (#0079), including the illegal ones and the
/// legacy #0005 races (shutdown before running, double shutdown).
@Suite struct ServerLifecycleTests {
    typealias State = ServerLifecycle.State
    typealias Event = ServerLifecycle.Event
    typealias Action = ServerLifecycle.Action

    static let deadline = Deadline.after(.seconds(5))
    static let otherDeadline = Deadline.after(.seconds(60))

    /// A machine driven into `state` through legal events.
    static func machine(in state: State) -> ServerLifecycle {
        var machine = ServerLifecycle()
        let path: [Event] = switch state {
        case .idle: []
        case .starting: [.start]
        case .running: [.start, .listenerReady]
        case .draining(let deadline): [.start, .listenerReady, .shutdownRequested(deadline: deadline)]
        case .stopped: [.start, .listenerReady, .shutdownRequested(deadline: deadline), .lastConnectionClosed]
        case .failed: [.start, .listenerFailed]
        }
        for event in path { _ = machine.handle(event) }
        #expect(machine.state == state)
        return machine
    }

    static let states: [State] = [.idle, .starting, .running, .draining(deadline: deadline), .stopped, .failed]
    static let events: [Event] = [
        .start, .listenerReady, .listenerFailed, .shutdownRequested(deadline: otherDeadline),
        .drainDeadlineReached, .lastConnectionClosed,
    ]

    /// The full transition table: `nil` means the event is ignored (state unchanged, `.none`).
    static func expected(_ state: State, _ event: Event) -> (State, Action)? {
        switch (state, event) {
        case (.idle, .start): (.starting, .startListeners)
        case (_, .start): (state, .rejectStart)
        case (.idle, .shutdownRequested): (.stopped, .finish)
        case (.starting, .shutdownRequested): (.stopped, .abandonStartup)
        case (.running, .shutdownRequested(let d)): (.draining(deadline: d), .drain(deadline: d))
        case (.starting, .listenerReady): (.running, .acceptConnections)
        case (.starting, .listenerFailed): (.failed, .failStartup)
        case (.draining, .lastConnectionClosed): (.stopped, .finish)
        case (.draining, .drainDeadlineReached): (.stopped, .cancelConnections)
        default: nil
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func everyStateEventPair() {
        var legal = 0
        for state in Self.states {
            for event in Self.events {
                var machine = Self.machine(in: state)
                let action = machine.handle(event)
                if let (next, expectedAction) = Self.expected(state, event) {
                    #expect(machine.state == next, "\(state) + \(event)")
                    #expect(action == expectedAction, "\(state) + \(event)")
                    if expectedAction != .rejectStart { legal += 1 }
                } else {
                    #expect(machine.state == state, "\(state) + \(event) must be ignored")
                    #expect(action == .none, "\(state) + \(event) must be ignored")
                }
            }
        }
        #expect(legal == 8)
    }

    @Test(.timeLimit(.minutes(1)))
    func happyPath() {
        var machine = ServerLifecycle()
        #expect(machine.state == .idle)
        #expect(machine.handle(.start) == .startListeners)
        #expect(machine.handle(.listenerReady) == .acceptConnections)
        #expect(machine.isRunning)
        #expect(machine.handle(.shutdownRequested(deadline: Self.deadline)) == .drain(deadline: Self.deadline))
        #expect(machine.drainDeadline == Self.deadline)
        #expect(!machine.isRunning)
        #expect(machine.handle(.lastConnectionClosed) == .finish)
        #expect(machine.state == .stopped)
        #expect(machine.isFinished)
    }

    @Test(.timeLimit(.minutes(1)))
    func deadlineCancelsThenLateCloseIsIgnored() {
        var machine = Self.machine(in: .draining(deadline: Self.deadline))
        #expect(machine.handle(.drainDeadlineReached) == .cancelConnections)
        #expect(machine.state == .stopped)
        // The cancelled connections close afterwards; nothing more to do.
        #expect(machine.handle(.lastConnectionClosed) == .none)
        #expect(machine.handle(.drainDeadlineReached) == .none)
    }

    /// #0005: a shutdown before `run()` is not lost; `run()` then returns at once.
    @Test(.timeLimit(.minutes(1)))
    func shutdownBeforeRunIsNotLost() {
        var machine = ServerLifecycle()
        #expect(machine.handle(.shutdownRequested(deadline: Self.deadline)) == .finish)
        #expect(machine.state == .stopped)
        #expect(machine.handle(.start) == .rejectStart)
        #expect(machine.state == .stopped)
    }

    /// #0005: a shutdown while binding abandons startup; the listener reporting later is ignored.
    @Test(.timeLimit(.minutes(1)))
    func shutdownWhileStartingAbandonsStartup() {
        var machine = Self.machine(in: .starting)
        #expect(machine.handle(.shutdownRequested(deadline: Self.deadline)) == .abandonStartup)
        #expect(machine.state == .stopped)
        #expect(machine.handle(.listenerReady) == .none)
        #expect(machine.handle(.listenerFailed) == .none)
        #expect(machine.state == .stopped)
    }

    /// #0005: the first shutdown wins; its deadline is kept.
    @Test(.timeLimit(.minutes(1)))
    func doubleShutdownKeepsTheFirstDeadline() {
        var machine = Self.machine(in: .running)
        #expect(machine.handle(.shutdownRequested(deadline: Self.deadline)) == .drain(deadline: Self.deadline))
        #expect(machine.handle(.shutdownRequested(deadline: Self.otherDeadline)) == .none)
        #expect(machine.state == .draining(deadline: Self.deadline))
        #expect(machine.handle(.lastConnectionClosed) == .finish)
        #expect(machine.handle(.shutdownRequested(deadline: Self.otherDeadline)) == .none)
        #expect(machine.state == .stopped)
    }

    @Test(.timeLimit(.minutes(1)))
    func failedIsTerminal() {
        var machine = Self.machine(in: .failed)
        for event in Self.events {
            _ = machine.handle(event)
            #expect(machine.state == .failed)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func configurationValidation() {
        #expect(throws: ServerError.self) { try ServerConfiguration(maxConnections: 0).validate() }
        #expect(throws: ServerError.self) { try ServerConfiguration(drainTimeout: .seconds(-1)).validate() }
        #expect(throws: Never.self) { try ServerConfiguration(maxConnections: 1, drainTimeout: nil).validate() }
    }
}

/// Once-per-connection protocol selection (#0079, ROADMAP §5.2).
@Suite struct ProtocolRegistryTests {
    struct Fake<Tag>: ConnectionProtocol {
        static var alpnTokens: [String] {
            Tag.self == A.self ? ["a/1"] : Tag.self == H1.self ? ["http/1.1"] : ["b/1", "b/2"]
        }
        static func matchesCleartextPreface(_ bytes: borrowing ByteBuffer) -> SniffResult {
            let prefix: [UInt8] = Tag.self == A.self ? Array("AAAA".utf8) : Array("BB".utf8)
            let have = bytes.withReadableSpan { span in (0..<span.count).map { span[$0] } }
            let n = min(have.count, prefix.count)
            guard have.prefix(n).elementsEqual(prefix.prefix(n)) else { return .noMatch }
            return n == prefix.count ? .match : .needMoreBytes
        }
        func run<T: ByteStreamTransport, H: HTTPHandler>(_ t: T, handler: H, context: ConnectionContext) async {}
    }
    enum A {}
    enum B {}
    enum H1 {}

    let registry = ProtocolRegistry([Fake<A>(), Fake<B>()])

    @Test(.timeLimit(.minutes(1)))
    func alpnPicksTheProtocolListingTheToken() {
        #expect(registry.select(alpn: "a/1", preface: ByteBuffer()) == .selected(index: 0))
        #expect(registry.select(alpn: "b/2", preface: ByteBuffer()) == .selected(index: 1))
        #expect(registry.select(alpn: "h3", preface: ByteBuffer()) == .unsupported)
    }

    @Test(.timeLimit(.minutes(1)))
    func singleProtocolNeedsNoSniffing() {
        let single = ProtocolRegistry([Fake<B>()])
        #expect(single.select(alpn: nil, preface: ByteBuffer()) == .selected(index: 0))
        #expect(single.select(alpn: nil, preface: ByteBuffer("zzz")) == .selected(index: 0))
    }

    @Test(.timeLimit(.minutes(1)))
    func cleartextSniffing() {
        #expect(registry.select(alpn: nil, preface: ByteBuffer()) == .needMoreBytes)
        #expect(registry.select(alpn: nil, preface: ByteBuffer("A")) == .needMoreBytes)
        #expect(registry.select(alpn: nil, preface: ByteBuffer("AAAA")) == .selected(index: 0))
        #expect(registry.select(alpn: nil, preface: ByteBuffer("BB")) == .selected(index: 1))
        #expect(registry.select(alpn: nil, preface: ByteBuffer("AB")) == .unsupported)
        #expect(registry.select(alpn: nil, preface: ByteBuffer("C")) == .unsupported)
    }

    /// #0088: what a TLS listener offers is every registered token, in registration order.
    @Test(.timeLimit(.minutes(1)))
    func alpnTokensFollowRegistrationOrder() {
        #expect(registry.alpnTokens == ["a/1", "b/1", "b/2"])
        #expect(ProtocolRegistry([Fake<B>(), Fake<A>(), Fake<B>()]).alpnTokens == ["b/1", "b/2", "a/1"])
        #expect(ProtocolRegistry([]).alpnTokens.isEmpty)
    }

    /// #0088: on TLS, an absent or unknown ALPN token falls back to the `http/1.1` protocol
    /// without sniffing; cleartext keeps sniffing.
    @Test(.timeLimit(.minutes(1)))
    func secureConnectionsFallBackToHTTP11() {
        let withH1 = ProtocolRegistry([Fake<A>(), Fake<H1>()])
        #expect(withH1.select(alpn: nil, secure: true, preface: ByteBuffer()) == .selected(index: 1))
        #expect(withH1.select(alpn: "h2", secure: true, preface: ByteBuffer()) == .selected(index: 1))
        #expect(withH1.select(alpn: "a/1", secure: true, preface: ByteBuffer()) == .selected(index: 0))
        #expect(withH1.select(alpn: nil, secure: false, preface: ByteBuffer()) == .needMoreBytes)
        #expect(withH1.select(alpn: "h2", secure: false, preface: ByteBuffer()) == .unsupported)
        // Without an http/1.1 protocol a secure connection with no token is sniffed.
        #expect(registry.select(alpn: nil, secure: true, preface: ByteBuffer()) == .needMoreBytes)
    }

    @Test(.timeLimit(.minutes(1)))
    func sniffTimeoutComesFromTheConfiguration() {
        #expect(ProtocolRegistry([]).sniffTimeout == .seconds(10))
        #expect(throws: ServerError.self) { try ServerConfiguration(sniffTimeout: .zero).validate() }
        #expect(throws: Never.self) { try ServerConfiguration(sniffTimeout: nil).validate() }
    }

    @Test(.timeLimit(.minutes(1)))
    func emptyRegistrySupportsNothing() {
        #expect(ProtocolRegistry([]).select(alpn: nil, preface: ByteBuffer("x")) == .unsupported)
    }
}
