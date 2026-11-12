// Upstream choice, retries, error mapping and active health checks (#0122).
public import HTTPCore

extension ReverseProxy {
    /// Sends `request` to the mount's upstreams: round-robin over the healthy ones, retrying an
    /// idempotent request on the next upstream after a connect failure (at most
    /// `policy.retries` times). Errors before the response head become `502 Bad Gateway`
    /// (`504 Gateway Timeout` for a timeout), returned as a status so ErrorPages renders them.
    /// A failure after the head throws from the body stream, which aborts the response
    /// (close on HTTP/1.1, stream reset on HTTP/2 and HTTP/3).
    func forward(_ request: HTTPRequest, decodedPath: String, mount: CompiledMount,
                 clientHost: String?, context: RequestContext) async throws -> HTTPResponse {
        let upstreams = mount.config.upstreams
        guard !upstreams.isEmpty else { return HTTPResponse(status: .badGateway) }
        let policy = mount.config.policy
        let idempotent = request.method.isIdempotent
        let order = mount.balancer.order()
        let attempts = idempotent ? 1 + policy.retries : 1
        let deadline = policy.timeouts.total.map { ContinuousClock.now + $0 }
        let options = UpstreamSendOptions(timeouts: policy.timeouts, deadline: deadline,
                                          retriesStaleConnection: policy.retries > 0, pool: policy.pool)
        var lastError = UpstreamError.connectFailed("no upstream")
        for attempt in 0..<attempts {
            let index = order[attempt % order.count]
            let target = upstreams[index]
            let upstreamRequest = makeUpstreamRequest(request, decodedPath: decodedPath, mount: mount,
                                                      target: target, clientHost: clientHost, context: context)
            do {
                let response = try await client.send(upstreamRequest, body: request.body, to: target, options: options)
                mount.balancer.recordSuccess(index)
                return mapResponse(response, mount: mount, target: target, clientHost: clientHost,
                                   secure: context.connection.isSecure)
            } catch let error as UpstreamError {
                // The client went away: nothing to answer, and not the upstream's fault.
                if Task.isCancelled { throw CancellationError() }
                // A full pool is load, not a failed upstream.
                if error != .cancelled && error != .poolExhausted { mount.balancer.recordFailure(index) }
                lastError = error
                // Only a request that never reached an upstream is sent again.
                guard error.isConnectFailure else { break }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
                mount.balancer.recordFailure(index)
                lastError = .malformedResponse("\(error)")
                break
            }
        }
        if lastError == .poolExhausted { return HTTPResponse(status: .serviceUnavailable) }
        return HTTPResponse(status: lastError.isTimeout ? .gatewayTimeout : .badGateway)
    }
}

extension ReverseProxy: ServerComponent {
    /// Runs the active health checks of mounts with a `checkPath`, and the sweep that closes
    /// idle pooled connections past their idle timeout or closed by the upstream (#0120),
    /// until cancelled. Closes every idle connection on the way out.
    public func run(server: ServerHandle) async throws {
        let checked = mounts.filter { $0.config.policy.health.checkPath != nil && !$0.config.upstreams.isEmpty }
        let client = client
        let interval = Self.sweepInterval(mounts.map(\.config.policy.pool.idleTimeout))
        await withTaskGroup(of: Void.self) { group in
            for mount in checked {
                group.addTask { await Self.healthLoop(mount, client: client) }
            }
            group.addTask {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: interval) } catch { break }
                    await client.evictIdleConnections(all: false)
                }
            }
        }
        await client.evictIdleConnections(all: true)
    }

    /// Half the shortest idle timeout, between 1 and 30 seconds.
    static func sweepInterval(_ idleTimeouts: [Duration?]) -> Duration {
        let shortest = idleTimeouts.compactMap { $0 }.min() ?? .seconds(60)
        return min(max(shortest / 2, .seconds(1)), .seconds(30))
    }

    static func healthLoop(_ mount: CompiledMount, client: any UpstreamClient) async {
        let health = mount.config.policy.health
        while !Task.isCancelled {
            await checkOnce(mount, client: client)
            do { try await Task.sleep(for: health.checkInterval) } catch { return }
        }
    }

    /// Checks every upstream of `mount` once, concurrently, and records the results.
    static func checkOnce(_ mount: CompiledMount, client: any UpstreamClient) async {
        let health = mount.config.policy.health
        guard let path = health.checkPath else { return }
        var timeouts = mount.config.policy.timeouts
        timeouts.connect = min(timeouts.connect ?? health.checkInterval, health.checkInterval)
        timeouts.response = min(timeouts.response ?? health.checkInterval, health.checkInterval)
        timeouts.idle = timeouts.response
        timeouts.total = nil
        let options = UpstreamSendOptions(timeouts: timeouts, retriesStaleConnection: true)
        await withTaskGroup(of: Void.self) { group in
            for (index, target) in mount.config.upstreams.enumerated() {
                group.addTask {
                    let request = UpstreamRequest(method: .get, target: path,
                                                  host: ReverseProxyHeaders.authority(of: target.address),
                                                  headers: HTTPFields())
                    var healthy = false
                    do {
                        let response = try await client.send(request, body: .empty, to: target, options: options)
                        healthy = response.status.code < 500
                        // Drain (under the idle limit) so the connection can be pooled.
                        while try await response.body.next() != nil {}
                    } catch {
                        healthy = false
                    }
                    if Task.isCancelled { return }
                    mount.balancer.recordCheck(index, healthy: healthy)
                }
            }
        }
    }
}
