import HTTPCore
import VirtualHosts

/// VirtualHosts lookup microbenchmarks (#0092). Select with `sws-bench micro --filter
/// VirtualHosts`.
///
/// The set is 50 sites: `site0.example.com` … `site49.example.com` with `www.` aliases, 10
/// wildcard sites `*.tenant0.example.net` …, and a default. Each op is one
/// `VirtualHosts.route(request)` on a prebuilt request with a `Host` field: the whole
/// per-request cost before the host's chain is called. Target: 0 allocations per op.
func registerVirtualHostsBenchmarks() {
    var hosts: [VirtualHost] = []
    for i in 0..<50 { hosts.append(VirtualHost("site\(i).example.com", "www.site\(i).example.com", handler: NotFoundHandler())) }
    for i in 0..<10 { hosts.append(VirtualHost("*.tenant\(i).example.net", handler: NotFoundHandler())) }
    hosts.append(VirtualHost.default(handler: NotFoundHandler()))
    let sites = try! VirtualHosts(hosts)

    func register(_ name: String, host: String) {
        let (storage, request) = hostRequest(host)
        Benchmark.register(name: name) {
            blackHole(sites.route(request))
        }
        blackHole(storage)
    }
    register("VirtualHosts.route exact", host: "site42.example.com")
    register("VirtualHosts.route exact + port, mixed case", host: "WWW.Site42.Example.com:8443")
    register("VirtualHosts.route wildcard", host: "acme.tenant7.example.net")
    register("VirtualHosts.route unknown -> default", host: "unknown.example.org")
}

/// A `GET /` request carrying `Host: host`, in its own storage (returned so it outlives the
/// request).
private func hostRequest(_ host: String) -> (HTTPRequestStorage, HTTPRequest) {
    let storage = HTTPRequestStorage(bufferCapacity: 256, fieldCapacity: 4)
    func add(_ text: String) -> ByteView {
        let start = storage.buffer.writerIndex
        storage.buffer.append(contentsOf: Array(text.utf8))
        return ByteView(offset: start, length: text.utf8.count)
    }
    let path = add("/")
    let name = add("Host")
    storage.appendField(nameView: name, hash: ASCII.fnv1aLowercased("host"), valueView: add(host))
    return (storage, HTTPRequest(method: .get, path: path, headers: storage.fieldsView))
}
