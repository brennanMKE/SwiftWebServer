public import HTTPCore

/// Answers `GET` (and `HEAD`) for one path with ``AccessLogMetrics`` in the Prometheus text
/// format; every other request passes through. A separate opt-in middleware: the metrics are
/// collected by ``AccessLog`` whether or not they are served.
///
/// Place it after the ``AccessLog`` to have scrapes logged and counted, before it to keep
/// them out.
public struct MetricsEndpoint: HTTPMiddleware {
    public let metrics: AccessLogMetrics
    /// The path bytes matched exactly (no query).
    @usableFromInline let path: [UInt8]

    public init(metrics: AccessLogMetrics, path: String = "/metrics") {
        self.metrics = metrics
        self.path = Array(path.utf8)
    }

    @inlinable
    public func handle<Next: HTTPHandler>(_ request: HTTPRequest, context: RequestContext,
                                          next: Next) async throws -> HTTPResponse {
        guard request.method == .get || request.method == .head, matches(request) else {
            return try await next.handle(request, context: context)
        }
        return scrape()
    }

    @usableFromInline
    func matches(_ request: HTTPRequest) -> Bool {
        guard request.path.length == path.count else { return false }
        return request.withSpan(of: request.path) { span in
            for index in 0..<span.count where span[index] != path[index] { return false }
            return true
        }
    }

    /// The scrape response.
    public func scrape() -> HTTPResponse {
        var body = ByteBuffer(capacity: 4096)
        metrics.writePrometheus(metrics.snapshot(), to: &body)
        var headers = HTTPFields()
        headers.append(.contentType, "text/plain; version=0.0.4; charset=utf-8")
        headers.append(.cacheControl, "no-store")
        return HTTPResponse(status: .ok, headers: headers, body: .bytes(body))
    }
}
