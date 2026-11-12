import HTTPCore
import Synchronization
import Testing
@testable import ConfigFile

/// `ReloadableHandler` (#0127): new requests run on the replacement, old connections keep
/// their chain's observers, and a replaced chain's components stop once its connections closed.
@Suite struct ReloadableHandlerTests {
    final class Events: Sendable {
        let list = Mutex<[String]>([])
        func append(_ event: String) { list.withLock { $0.append(event) } }
        var all: [String] { list.withLock { $0 } }
    }

    /// Answers with its status; as a component, records its start and stop.
    struct Probe: HTTPHandler, ServerComponent, ConnectionObserver {
        let tag: String
        let status: HTTPStatus
        let events: Events

        func handle(_ request: HTTPRequest, context: RequestContext) async throws -> HTTPResponse {
            HTTPResponse(status: status)
        }

        func run(server: ServerHandle) async throws {
            events.append("start \(tag)")
            while (try? await Task.sleep(for: .seconds(3600))) != nil {}
            events.append("stop \(tag)")
        }

        func connectionWillStart(_ connection: inout ConnectionContext) { events.append("open \(tag)") }
        func connectionDidEnd(_ connection: ConnectionContext) { events.append("close \(tag)") }
    }

    func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    @Test(.timeLimit(.minutes(1)))
    func swapsForNewRequestsAndRetiresTheOldChainAfterItsConnections() async throws {
        let events = Events()
        let reloadable = ReloadableHandler(Probe(tag: "a", status: .ok, events: events))
        let storage = HTTPRequestStorage(bufferCapacity: 16, fieldCapacity: 1)
        let request = HTTPRequest(method: .get, path: .empty, headers: storage.fieldsView)
        let handle = ServerHandle(localAddresses: [], draining: ShutdownSignal(), requestShutdown: {})

        try await withThrowingTaskGroup { group in
            group.addTask { try await reloadable.run(server: handle) }
            try await eventually { events.all.contains("start a") }

            var connection = ConnectionContext(info: ConnectionInfo())
            reloadable.connectionWillStart(&connection)
            #expect(try await reloadable.handle(request, context: connection.requestContext).status == .ok)

            reloadable.replace(with: Probe(tag: "b", status: .notFound, events: events))
            try await eventually { events.all.contains("start b") }
            // The open connection's next request runs on the new chain; the old chain lives on.
            #expect(try await reloadable.handle(request, context: connection.requestContext).status == .notFound)
            #expect(reloadable.liveHandlers.map(\.tag) == ["a", "b"])
            #expect(!events.all.contains("stop a"))

            reloadable.connectionDidEnd(connection)
            try await eventually { events.all.contains("stop a") }
            #expect(reloadable.liveHandlers.map(\.tag) == ["b"])

            var second = ConnectionContext(info: ConnectionInfo())
            reloadable.connectionWillStart(&second)
            #expect(try await reloadable.handle(request, context: second.requestContext).status == .notFound)
            reloadable.connectionDidEnd(second)

            group.cancelAll()
        }
        #expect(events.all == ["start a", "open a", "start b", "close a", "stop a", "open b", "close b", "stop b"])
    }

    @Test func reloadOnlyKeysAreNotReportedAsRestartChanges() {
        let old = ServerSettings()
        var next = old
        next.root = "Other"
        next.proxy = []
        next.maxAge = nil
        #expect(next.restartOnlyChanges(comparedTo: old).isEmpty)
        next.port = 9
        next.maxConnections = 3
        #expect(next.restartOnlyChanges(comparedTo: old) == ["port", "maxConnections"])
    }
}
