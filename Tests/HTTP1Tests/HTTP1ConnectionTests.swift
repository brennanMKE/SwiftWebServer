import Testing
import HTTPCore
@testable import HTTP1

/// The pure state machine: persistence rules (RFC 9112 §9.3) and transitions.
@Suite struct HTTP1ConnectionTests {
    typealias Summary = HTTP1Connection.RequestSummary

    func context(_ action: HTTP1Connection.Action) -> HTTP1ResponseContext? {
        if case .writeResponse(let context) = action { return context }
        return nil
    }

    /// Drives one exchange to the response and returns the persistence the response carries.
    func persistence(_ summary: Summary, kind: HTTP1Connection.ResponseKind = .delimited) -> HTTP1ResponseContext.Persistence? {
        var connection = HTTP1Connection()
        guard case .callHandler = connection.handle(.head(summary)) else { return nil }
        return context(connection.handle(.response(kind)))?.persistence
    }

    @Test func http11PersistsByDefault() {
        #expect(persistence(Summary(version: .http1_1)) == .keepAlive)
    }

    @Test func connectionCloseEndsHTTP11() {
        #expect(persistence(Summary(version: .http1_1, connectionClose: true)) == .close)
        #expect(persistence(Summary(version: .http1_1, connectionClose: true, connectionKeepAlive: true)) == .close)
    }

    @Test func http10NeedsKeepAliveOptIn() {
        #expect(persistence(Summary(version: .http1_0)) == .close)
        #expect(persistence(Summary(version: .http1_0, connectionKeepAlive: true)) == .keepAlive)
        #expect(persistence(Summary(version: .http1_0, connectionClose: true, connectionKeepAlive: true)) == .close)
    }

    @Test func http10NeverGetsAnUnknownLengthBodyOnAPersistentConnection() {
        // No chunked coding in HTTP/1.0: the body must be delimited by the close.
        #expect(persistence(Summary(version: .http1_0, connectionKeepAlive: true), kind: .unknownLength) == .close)
        #expect(persistence(Summary(version: .http1_1), kind: .unknownLength) == .keepAlive)
    }

    @Test func summaryReadsConnectionTokens() {
        var head = HTTP1RequestHead()
        head.version = .http1_0
        var fields = HTTPFields()
        fields.append(.connection, "Upgrade, Keep-Alive")
        let summary = Summary(head: head, fields: fields)
        #expect(summary.connectionKeepAlive && !summary.connectionClose)
        #expect(summary.wantsPersistence)

        var closing = HTTPFields()
        closing.append(.connection, "CLOSE")
        #expect(Summary(head: HTTP1RequestHead(), fields: closing).connectionClose)
        #expect(!Summary(head: HTTP1RequestHead(), fields: HTTPFields()).connectionClose)
    }

    @Test func keepAliveCycleReturnsToIdle() {
        var connection = HTTP1Connection()
        for _ in 0..<3 {
            #expect(connection.handle(.needMoreBytes(headStarted: true)) == .proceed)
            #expect(connection.state == .readingHead)
            #expect(connection.handle(.head(Summary())) == .callHandler)
            guard case .handling = connection.state else { Issue.record("not handling"); return }
            #expect(context(connection.handle(.response(.delimited)))?.persistence == .keepAlive)
            guard case .writing = connection.state else { Issue.record("not writing"); return }
            #expect(connection.handle(.responseWritten) == .proceed)
            #expect(connection.state == .idle)
        }
        #expect(connection.requestCount == 3)
        #expect(connection.handle(.endOfStream) == .close(.normal))
    }

    @Test func closeAfterResponse() {
        var connection = HTTP1Connection()
        _ = connection.handle(.head(Summary(connectionClose: true)))
        _ = connection.handle(.response(.delimited))
        #expect(connection.handle(.responseWritten) == .close(.normal))
        #expect(connection.state == .closing(.normal))
    }

    @Test func handlerFailureIs500AndClose() {
        var connection = HTTP1Connection()
        _ = connection.handle(.head(Summary(method: .head)))
        guard case .writeError(let status, let context) = connection.handle(.handlerFailed) else {
            Issue.record("expected writeError"); return
        }
        #expect(status.code == 500)
        #expect(context.persistence == .close)
        #expect(context.requestMethod == .head)
        #expect(connection.handle(.responseWritten) == .close(.normal))
    }

    @Test func parseErrorIsItsStatusAndClose() {
        var connection = HTTP1Connection()
        _ = connection.handle(.needMoreBytes(headStarted: true))
        guard case .writeError(let status, let context) = connection.handle(.parseError(.headTooLarge)) else {
            Issue.record("expected writeError"); return
        }
        #expect(status.code == 431)
        #expect(context.persistence == .close)
        #expect(connection.handle(.responseWritten) == .close(.protocolError))
    }

    @Test func requestWithBodyGoesToTheHandler() {
        for framing in [HTTP1RequestFraming.contentLength(5), .chunked, .contentLength(0)] {
            var connection = HTTP1Connection()
            #expect(connection.handle(.head(Summary(framing: framing))) == .callHandler)
            guard case .handling(let exchange) = connection.state else { Issue.record("not handling"); continue }
            #expect(exchange.hasBody == (framing != .contentLength(0)))
            #expect(!exchange.expectsContinue)
        }
    }

    @Test func contentLengthOverTheLimitIs413BeforeTheHandler() {
        var connection = HTTP1Connection(maxBodySize: 100)
        guard case .writeError(let status, let context) = connection.handle(.head(Summary(framing: .contentLength(101)))) else {
            Issue.record("expected writeError"); return
        }
        #expect(status.code == 413)
        #expect(context.persistence == .close)
        #expect(connection.handle(.responseWritten) == .close(.normal))

        var atLimit = HTTP1Connection(maxBodySize: 100)
        #expect(atLimit.handle(.head(Summary(framing: .contentLength(100)))) == .callHandler)
        // Chunked bodies are checked while they are read.
        var chunked = HTTP1Connection(maxBodySize: 100)
        #expect(chunked.handle(.head(Summary(framing: .chunked))) == .callHandler)
    }

    @Test func expectations() {
        var unsupported = HTTP1Connection()
        guard case .writeError(let status, let context) = unsupported.handle(.head(Summary(framing: .contentLength(5), expectation: .unsupported))) else {
            Issue.record("expected writeError"); return
        }
        #expect(status.code == 417)
        #expect(context.persistence == .close)

        var continuing = HTTP1Connection()
        #expect(continuing.handle(.head(Summary(framing: .contentLength(5), expectation: .continue))) == .callHandler)
        guard case .handling(let exchange) = continuing.state else { Issue.record("not handling"); return }
        #expect(exchange.expectsContinue)

        // No content: nothing to continue.
        var bodiless = HTTP1Connection()
        _ = bodiless.handle(.head(Summary(expectation: .continue)))
        guard case .handling(let none) = bodiless.state else { Issue.record("not handling"); return }
        #expect(!none.expectsContinue)
    }

    @Test func summaryReadsExpect() {
        func summary(_ value: String, version: HTTP1Version = .http1_1) -> Summary {
            var head = HTTP1RequestHead()
            head.version = version
            var fields = HTTPFields()
            fields.append(name: "Expect", value: value)
            return Summary(head: head, fields: fields)
        }
        #expect(summary("100-continue").expectation == .continue)
        #expect(summary("100-Continue").expectation == .continue)
        #expect(summary("100-continue, x-other").expectation == .unsupported)
        #expect(summary("x-other").expectation == .unsupported)
        #expect(summary("100-continue", version: .http1_0).expectation == .none)
        #expect(Summary(head: HTTP1RequestHead(), fields: HTTPFields()).expectation == .none)
    }

    @Test func unreadBodyIsDrainedOrCloses() {
        var drained = HTTP1Connection()
        _ = drained.handle(.head(Summary(framing: .contentLength(5))))
        #expect(drained.handle(.bodyUnread(drainable: true)) == .drainBody)
        guard case .readingBody = drained.state else { Issue.record("not readingBody"); return }
        #expect(drained.handle(.bodyDrained(complete: true)) == .proceed)
        #expect(context(drained.handle(.response(.delimited)))?.persistence == .keepAlive)

        var overLimit = HTTP1Connection()
        _ = overLimit.handle(.head(Summary(framing: .chunked)))
        #expect(overLimit.handle(.bodyUnread(drainable: true)) == .drainBody)
        #expect(overLimit.handle(.bodyDrained(complete: false)) == .proceed)
        #expect(context(overLimit.handle(.response(.delimited)))?.persistence == .close)
        #expect(overLimit.handle(.responseWritten) == .close(.normal))

        var undrainable = HTTP1Connection()
        _ = undrainable.handle(.head(Summary(framing: .contentLength(5), expectation: .continue)))
        #expect(undrainable.handle(.bodyUnread(drainable: false)) == .proceed)
        #expect(context(undrainable.handle(.response(.delimited)))?.persistence == .close)
    }

    @Test func bodyFailureStatuses() {
        for (failure, code) in [(HTTP1Connection.BodyFailure.tooLarge, 413), (.malformed, 400)] {
            var connection = HTTP1Connection()
            _ = connection.handle(.head(Summary(framing: .chunked)))
            guard case .writeError(let status, let context) = connection.handle(.bodyFailed(failure)) else {
                Issue.record("expected writeError"); continue
            }
            #expect(status.code == code)
            #expect(context.persistence == .close)
            #expect(connection.handle(.responseWritten) == .close(.normal))
        }
    }

    @Test func responseBodyFailureAborts() {
        var connection = HTTP1Connection()
        _ = connection.handle(.head(Summary()))
        _ = connection.handle(.response(.unknownLength))
        #expect(connection.handle(.responseBodyFailed) == .close(.abort))
    }

    @Test func responseContextCarriesTheVersion() {
        var connection = HTTP1Connection()
        _ = connection.handle(.head(Summary(version: .http1_0)))
        #expect(context(connection.handle(.response(.unknownLength)))?.requestVersion == .http1_0)
    }

    @Test func endOfStreamMidHeadClosesQuietly() {
        var connection = HTTP1Connection()
        _ = connection.handle(.needMoreBytes(headStarted: true))
        #expect(connection.handle(.endOfStream) == .close(.normal))
    }

    @Test func transportFailuresAbort() {
        var connection = HTTP1Connection()
        #expect(connection.handle(.receiveFailed) == .close(.abort))
        var sending = HTTP1Connection()
        _ = sending.handle(.head(Summary()))
        _ = sending.handle(.response(.delimited))
        #expect(sending.handle(.sendFailed) == .close(.abort))
    }

    @Test func shutdownClosesIdleAndMarksTheNextResponseClose() {
        var idle = HTTP1Connection()
        #expect(idle.handle(.shutdown) == .close(.shutdown))

        var busy = HTTP1Connection()
        _ = busy.handle(.head(Summary()))
        #expect(busy.handle(.shutdown) == .proceed)
        #expect(context(busy.handle(.response(.delimited)))?.persistence == .close)
        #expect(busy.handle(.responseWritten) == .close(.normal))

        var draining = HTTP1Connection()
        _ = draining.handle(.shutdown)
        #expect(draining.isDraining)
    }

    @Test func tunnelHandsOverTheStream() {
        var connection = HTTP1Connection()
        _ = connection.handle(.head(Summary()))
        _ = connection.handle(.response(.tunnel))
        #expect(connection.handle(.responseWritten) == .startTunnel)
        #expect(connection.state == .tunnelled)
    }
}
