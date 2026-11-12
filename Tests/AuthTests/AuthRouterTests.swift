import HTTPCore
import Router
import Testing
@testable import Auth

/// Auth composed with the Router (#0093, #0094).
@Suite struct AuthRouterTests {
    let auth: Authenticator
    let router: Router

    init() throws {
        let users = try store([("alice", "wonderland")])
        auth = try Authenticator(paths: ["/admin"], realm: "Admin", basic: users)
        let auth = auth
        router = try Router {
            GET("/public") { _, _ in HTTPResponse(status: .ok) }
            GET("/admin/users/:id") { _, context in
                // The principal set by the authenticator in front reads through RouteContext.
                var headers = HTTPFields()
                headers.append(.server, string: "\(context.principal?.name ?? "-"):\(context.params["id"] ?? "")")
                return HTTPResponse(status: .ok, headers: headers)
            }
            // A single protected route outside the authenticator's paths.
            GET("/me", handler: auth.protect(Echo()))
        }
    }

    func run(_ path: String, authorization: String? = nil) async throws -> HTTPResponse {
        let request = AuthRequest(path, authorization: authorization)
        // The Router is both a middleware and a handler; as the last element it is the handler.
        let chain = MiddlewareChain(middleware: auth, next: router)
        return try await chain.handle(request.request, context: peerContext())
    }

    @Test(.timeLimit(.minutes(1))) func authenticatorInFrontOfRouter() async throws {
        #expect(try await run("/public").status == .ok)
        #expect(try await run("/admin/users/7").status == .unauthorized)
        let ok = try await run("/admin/users/7", authorization: basicHeader("alice", "wonderland"))
        #expect(ok.status == .ok)
        #expect(ok.headers.firstValueString(for: .server) == "alice:7")
        // An unknown route under the protected prefix is not revealed without credentials.
        #expect(try await run("/admin/nothing").status == .unauthorized)
        #expect(try await run("/admin/nothing", authorization: basicHeader("alice", "wonderland")).status == .notFound)
    }

    @Test(.timeLimit(.minutes(1))) func protectedSingleRoute() async throws {
        #expect(try await run("/me").status == .unauthorized)
        #expect(try await run("/me", authorization: basicHeader("alice", "nope")).status == .unauthorized)
        let me = try await run("/me", authorization: basicHeader("alice", "wonderland"))
        #expect(me.status == .ok)
        #expect(me.headers.firstValueString(for: .server) == "basic:alice")
    }
}
