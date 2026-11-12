import HTTPCore
import Router

/// Router match microbenchmarks (#0094). Select with `sws-bench router` or `sws-bench micro
/// --filter Router`.
///
/// The table is 50 routes: ten REST resources under `/api/v1`, each with `GET` and `POST` on
/// the collection and `GET`, `PUT` and `DELETE` on `/:id`. Each op is one `Router.match` on a
/// prebuilt request. Target: 0 allocations per op for hits and misses.
func registerRouterBenchmarks() {
    let resources = ["users", "orders", "products", "invoices", "carts",
                     "reviews", "shipments", "coupons", "accounts", "sessions"]
    let ok: RouteHandler = { _, _ in HTTPResponse(status: .ok) }
    let router = try! Router {
        Group("/api/v1") {
            for resource in resources {
                GET("/\(resource)", ok)
                POST("/\(resource)", ok)
                GET("/\(resource)/:id", ok)
                PUT("/\(resource)/:id", ok)
                DELETE("/\(resource)/:id", ok)
            }
        }
    }
    precondition(router.count == 50)

    func register(_ name: String, _ method: HTTPMethod, _ target: String, readParameter: Bool = false) {
        let (storage, request) = routerRequest(method, target)
        Benchmark.register(name: name) {
            let match = router.match(request)
            if readParameter, case .route(let route) = match {
                blackHole(route.parameters.decimal("id"))
            }
            blackHole(match)
        }
        blackHole(storage)
    }
    register("Router.match static hit", .get, "/api/v1/sessions")
    register("Router.match param hit", .get, "/api/v1/sessions/123456")
    register("Router.match param hit + decimal(id)", .delete, "/api/v1/sessions/123456", readParameter: true)
    register("Router.match HEAD via GET", .head, "/api/v1/orders/42")
    register("Router.match miss (fall through)", .get, "/assets/app.js")
    register("Router.match miss under prefix", .get, "/api/v1/unknown/1")
    register("Router.match 405", .patch, "/api/v1/orders/42")
}

/// A request whose path lives in its own storage, as a connection would build it. The storage
/// is returned so that it outlives the request.
private func routerRequest(_ method: HTTPMethod, _ path: String) -> (HTTPRequestStorage, HTTPRequest) {
    let storage = HTTPRequestStorage(bufferCapacity: 256, fieldCapacity: 4)
    storage.buffer.append(contentsOf: Array(path.utf8))
    let view = ByteView(offset: 0, length: storage.buffer.writerIndex)
    return (storage, HTTPRequest(method: method, path: view, headers: storage.fieldsView))
}
