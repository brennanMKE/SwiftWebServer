import HTTPCore

/// Why a route table could not be built. Thrown by ``Router/init(_:)``.
public enum RouterError: Error, Equatable, CustomStringConvertible {
    /// The pattern is malformed; `reason` says how.
    case invalidPattern(pattern: String, reason: String)
    /// Two routes match the same paths for the same method.
    case conflict(pattern: String, existing: String, method: String)

    public var description: String {
        switch self {
        case .invalidPattern(let pattern, let reason):
            "invalid route pattern '\(pattern)': \(reason)"
        case .conflict(let pattern, let existing, let method):
            "route \(method) '\(pattern)' conflicts with \(method) '\(existing)': both match the same paths"
        }
    }
}

/// One segment of a parsed pattern.
enum PatternSegment: Equatable {
    case literal([UInt8])
    case parameter(String)
    case wildcard(String)
}

extension PatternSegment {
    /// Parses `pattern` into segments: the bytes after the leading `/`, split at every `/`.
    static func parse(_ pattern: String) throws(RouterError) -> [PatternSegment] {
        func fail(_ reason: String) -> RouterError { .invalidPattern(pattern: pattern, reason: reason) }
        guard pattern.hasPrefix("/") else { throw fail("must start with '/'") }
        let parts = pattern.utf8.dropFirst().split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: false)
        var segments: [PatternSegment] = []
        var names = Set<String>()
        for (i, part) in parts.enumerated() {
            let bytes = Array(part)
            if bytes.first == UInt8(ascii: ":") || bytes.first == UInt8(ascii: "*") {
                let isWildcard = bytes[0] == UInt8(ascii: "*")
                let nameBytes = bytes.dropFirst()
                if isWildcard && i != parts.count - 1 { throw fail("'*' must be the last segment") }
                if !isWildcard && nameBytes.isEmpty { throw fail("parameter needs a name after ':'") }
                guard nameBytes.allSatisfy(isNameByte) else {
                    throw fail("parameter names use letters, digits and '_'")
                }
                let name = nameBytes.isEmpty ? "*" : String(decoding: nameBytes, as: UTF8.self)
                guard names.insert(name).inserted else { throw fail("parameter '\(name)' appears twice") }
                segments.append(isWildcard ? .wildcard(name) : .parameter(name))
            } else {
                segments.append(.literal(encoded(bytes)))
            }
        }
        if names.count > Captures.capacity {
            throw fail("at most \(Captures.capacity) parameters per route")
        }
        return segments
    }

    static func isAlphanumeric(_ byte: UInt8) -> Bool {
        ASCII.isDigit(byte) || (ASCII.lowercased(byte) >= UInt8(ascii: "a") && ASCII.lowercased(byte) <= UInt8(ascii: "z"))
    }

    static func isNameByte(_ byte: UInt8) -> Bool {
        isAlphanumeric(byte) || byte == UInt8(ascii: "_")
    }

    /// A literal segment as it appears in a request target: bytes outside RFC 3986 `pchar`
    /// are percent-encoded (`%` itself is kept, so a pattern may be written pre-encoded).
    static func encoded(_ bytes: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        let hex = Array("0123456789ABCDEF".utf8)
        for byte in bytes {
            if isPathCharacter(byte) {
                output.append(byte)
            } else {
                output.append(UInt8(ascii: "%"))
                output.append(hex[Int(byte >> 4)])
                output.append(hex[Int(byte & 0xF)])
            }
        }
        return output
    }

    static func isPathCharacter(_ byte: UInt8) -> Bool {
        if isAlphanumeric(byte) { return true }
        return "-._~!$&'()*+,;=:@%".utf8.contains(byte)
    }
}

/// The compiled segment trie (built once by ``Router/init(_:)``, read-only afterwards).
///
/// Nodes, edges and method entries live in flat arrays of plain structs indexed by `Int32`,
/// so a lookup walks arrays and compares bytes: no allocation, no reference counting per node,
/// no `String`. A node's literal edges are sorted by (length, bytes) and binary searched.
final class RouteTable: Sendable {
    struct Node {
        var edgeStart: Int32 = 0
        var edgeCount: Int32 = 0
        /// Child for a `:param` segment, or -1.
        var parameter: Int32 = -1
        /// Terminal of a trailing `*` here, or -1.
        var wildcard: Int32 = -1
        /// Terminal for a path ending here, or -1.
        var terminal: Int32 = -1
    }

    struct Edge {
        var byteStart: Int32
        var length: Int32
        var child: Int32
    }

    struct Entry {
        var method: HTTPMethod
        var route: Int32
    }

    struct Terminal {
        var entryStart: Int32
        var entryCount: Int32
        /// The route answering every method, or -1.
        var anyMethod: Int32
        /// `405` with the `Allow` of this terminal alone.
        var methodNotAllowed: HTTPResponse
        /// The methods for `Allow`, in display order.
        var allowed: [HTTPMethod]
    }

    struct CompiledRoute {
        var pattern: String
        var names: ParameterNames?
        var handler: RouteHandler
    }

    let nodes: [Node]
    let edges: [Edge]
    let bytes: [UInt8]
    let entries: [Entry]
    let terminals: [Terminal]
    let routes: [CompiledRoute]

    // MARK: Building

    private final class BuildNode {
        var literals: [([UInt8], BuildNode)] = []
        var parameter: BuildNode?
        var wildcard: BuildTerminal?
        var terminal: BuildTerminal?

        func literal(_ bytes: [UInt8]) -> BuildNode {
            if let existing = literals.first(where: { $0.0 == bytes }) { return existing.1 }
            let node = BuildNode()
            literals.append((bytes, node))
            return node
        }
    }

    private final class BuildTerminal {
        var routes: [(methods: [HTTPMethod]?, route: Int)] = []
    }

    init(_ definitions: [Route]) throws(RouterError) {
        let root = BuildNode()
        var compiled: [CompiledRoute] = []
        for definition in definitions {
            let segments = try PatternSegment.parse(definition.pattern)
            var node = root
            var names: [String] = []
            var wildcardIndex = -1
            var terminal: BuildTerminal?
            for segment in segments {
                switch segment {
                case .literal(let bytes):
                    node = node.literal(bytes)
                case .parameter(let name):
                    names.append(name)
                    if node.parameter == nil { node.parameter = BuildNode() }
                    node = node.parameter!
                case .wildcard(let name):
                    wildcardIndex = names.count
                    names.append(name)
                    if node.wildcard == nil { node.wildcard = BuildTerminal() }
                    terminal = node.wildcard
                }
            }
            if terminal == nil {
                if node.terminal == nil { node.terminal = BuildTerminal() }
                terminal = node.terminal
            }
            let target = terminal!
            if let methods = definition.methods, methods.isEmpty {
                throw .invalidPattern(pattern: definition.pattern, reason: "empty method list")
            }
            for existing in target.routes {
                if let method = Self.overlap(existing.methods, definition.methods) {
                    throw .conflict(pattern: definition.pattern, existing: compiled[existing.route].pattern,
                                    method: method)
                }
            }
            target.routes.append((definition.methods, compiled.count))
            compiled.append(CompiledRoute(
                pattern: definition.pattern,
                names: names.isEmpty ? nil : ParameterNames(names: names, wildcardIndex: wildcardIndex),
                handler: definition.handler))
        }

        // Flatten breadth-first.
        var nodes: [Node] = []
        var edges: [Edge] = []
        var bytes: [UInt8] = []
        var entries: [Entry] = []
        var terminals: [Terminal] = []
        func addTerminal(_ terminal: BuildTerminal?) -> Int32 {
            guard let terminal else { return -1 }
            let start = entries.count
            var anyMethod: Int32 = -1
            var allowed: [HTTPMethod] = []
            for (methods, route) in terminal.routes {
                guard let methods else { anyMethod = Int32(route); continue }
                for method in methods where !entries[start...].contains(where: { $0.method == method }) {
                    entries.append(Entry(method: method, route: Int32(route)))
                    allowed.append(method)
                }
            }
            allowed = Self.displayOrder(allowed)
            terminals.append(Terminal(entryStart: Int32(start), entryCount: Int32(entries.count - start),
                                      anyMethod: anyMethod,
                                      methodNotAllowed: Self.methodNotAllowed(allowed), allowed: allowed))
            return Int32(terminals.count - 1)
        }
        var queue: [BuildNode] = [root]
        var ids: [ObjectIdentifier: Int32] = [ObjectIdentifier(root): 0]
        nodes.append(Node())
        var head = 0
        while head < queue.count {
            let build = queue[head]
            let id = Int(ids[ObjectIdentifier(build)]!)
            head += 1
            func enqueue(_ child: BuildNode) -> Int32 {
                let childID = Int32(nodes.count)
                nodes.append(Node())
                ids[ObjectIdentifier(child)] = childID
                queue.append(child)
                return childID
            }
            var node = Node()
            let sorted = build.literals.sorted { Self.precedes($0.0, $1.0) }
            node.edgeStart = Int32(edges.count)
            node.edgeCount = Int32(sorted.count)
            var pending: [(Int, BuildNode)] = []
            for (literal, _) in sorted {
                edges.append(Edge(byteStart: Int32(bytes.count), length: Int32(literal.count), child: -1))
                bytes.append(contentsOf: literal)
            }
            for (offset, (_, child)) in sorted.enumerated() { pending.append((Int(node.edgeStart) + offset, child)) }
            for (edge, child) in pending { edges[edge].child = enqueue(child) }
            if let parameter = build.parameter { node.parameter = enqueue(parameter) }
            node.wildcard = addTerminal(build.wildcard)
            node.terminal = addTerminal(build.terminal)
            nodes[id] = node
        }
        self.nodes = nodes
        self.edges = edges
        self.bytes = bytes
        self.entries = entries
        self.terminals = terminals
        self.routes = compiled
    }

    /// A method both constraints accept, as text, or `nil` when they are disjoint.
    static func overlap(_ a: [HTTPMethod]?, _ b: [HTTPMethod]?) -> String? {
        switch (a, b) {
        case (nil, nil): return "*"
        case (nil, let some?), (let some?, nil): return some.first!.description
        case (let a?, let b?): return a.first(where: b.contains)?.description
        }
    }

    /// Edge order: shorter first, then bytewise.
    static func precedes(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        a.count != b.count ? a.count < b.count : a.lexicographicallyPrecedes(b)
    }

    /// Standard methods in RFC order (with `HEAD` added when `GET` is present), then
    /// extension methods as defined.
    static func displayOrder(_ methods: [HTTPMethod]) -> [HTTPMethod] {
        var result: [HTTPMethod] = []
        for method in HTTPMethod.standardMethods {
            if methods.contains(method) || (method == .head && methods.contains(.get)) { result.append(method) }
        }
        for method in methods where method.standardName == nil && !result.contains(method) { result.append(method) }
        return result
    }

    static func methodNotAllowed(_ allowed: [HTTPMethod]) -> HTTPResponse {
        var headers = HTTPFields()
        headers.append(.allow, string: allowed.map(\.description).joined(separator: ", "))
        return HTTPResponse(status: .methodNotAllowed, headers: headers)
    }

    // MARK: Matching

    enum Outcome {
        /// The route answering the request, with captures relative to the path's start.
        case route(Int32)
        /// The path matched these terminals but none answers the method.
        case methodNotAllowed(Int32)
        case notFound
    }

    /// Finds the route for `method` on `path` (the still-encoded path, starting with `/`).
    ///
    /// Precedence at every segment: a literal edge, then a `:param`, then a trailing `*`.
    /// The search backtracks, so a deeper failure under a literal falls back to the parameter.
    /// A path that matches some route for another method answers ``Outcome/methodNotAllowed``
    /// only when no route along the precedence order answers the method.
    @inline(__always)
    func lookup(path: Span<UInt8>, method: HTTPMethod, captures: inout Captures) -> Outcome {
        guard path.count > 0, path[0] == UInt8(ascii: "/") else { return .notFound }
        var firstPathMatch: Int32 = -1
        let route = search(node: 0, path: path, position: 1, method: method,
                           captures: &captures, firstPathMatch: &firstPathMatch)
        if route >= 0 { return .route(route) }
        return firstPathMatch >= 0 ? .methodNotAllowed(firstPathMatch) : .notFound
    }

    /// `position` is the start of the next segment; `position > path.count` means the path is
    /// used up. Returns a route index or -1.
    func search(node index: Int32, path: Span<UInt8>, position: Int, method: HTTPMethod,
                captures: inout Captures, firstPathMatch: inout Int32) -> Int32 {
        let node = nodes[Int(index)]
        let count = path.count
        if position > count {
            if node.terminal >= 0 {
                let route = resolve(terminal: node.terminal, method: method)
                if route >= 0 { return route }
                if firstPathMatch < 0 { firstPathMatch = node.terminal }
            }
            return -1
        }
        var end = position
        var hasPercent = false
        while end < count {
            let byte = path[end]
            if byte == UInt8(ascii: "/") { break }
            if byte == UInt8(ascii: "%") { hasPercent = true }
            end &+= 1
        }
        if node.edgeCount > 0, let child = literalChild(node, path: path, start: position, end: end) {
            let route = search(node: child, path: path, position: end &+ 1, method: method,
                               captures: &captures, firstPathMatch: &firstPathMatch)
            if route >= 0 { return route }
        }
        if node.parameter >= 0, end > position, captures.count < Captures.capacity {
            captures.push(offset: position, length: end &- position, hasPercent: hasPercent)
            let route = search(node: node.parameter, path: path, position: end &+ 1, method: method,
                               captures: &captures, firstPathMatch: &firstPathMatch)
            if route >= 0 { return route }
            captures.pop()
        }
        if node.wildcard >= 0, captures.count < Captures.capacity {
            var restHasPercent = hasPercent
            var i = end
            while !restHasPercent && i < count {
                if path[i] == UInt8(ascii: "%") { restHasPercent = true }
                i &+= 1
            }
            let route = resolve(terminal: node.wildcard, method: method)
            if route >= 0 {
                captures.push(offset: position, length: count &- position, hasPercent: restHasPercent)
                return route
            }
            if firstPathMatch < 0 { firstPathMatch = node.wildcard }
        }
        return -1
    }

    /// Binary search of `node`'s literal edges for `path[start..<end]`.
    @inline(__always)
    func literalChild(_ node: Node, path: Span<UInt8>, start: Int, end: Int) -> Int32? {
        let length = end &- start
        var low = Int(node.edgeStart)
        var high = low &+ Int(node.edgeCount)
        while low < high {
            let mid = (low &+ high) >> 1
            let edge = edges[mid]
            var order = Int(edge.length) &- length
            if order == 0 {
                var i = 0
                let base = Int(edge.byteStart)
                while i < length {
                    let a = bytes[base &+ i], b = path[start &+ i]
                    if a != b { order = a < b ? -1 : 1; break }
                    i &+= 1
                }
                if order == 0 { return edge.child }
            }
            if order < 0 { low = mid &+ 1 } else { high = mid }
        }
        return nil
    }

    /// The route of `terminal` answering `method` (`HEAD` falls back to `GET`), or -1.
    @inline(__always)
    func resolve(terminal index: Int32, method: HTTPMethod) -> Int32 {
        let terminal = terminals[Int(index)]
        let start = Int(terminal.entryStart)
        let end = start &+ Int(terminal.entryCount)
        for i in start..<end where entries[i].method == method { return entries[i].route }
        if method == .head {
            for i in start..<end where entries[i].method == .get { return entries[i].route }
        }
        return terminal.anyMethod
    }

    /// Calls `visit` with every terminal whose pattern matches `path` (for a combined
    /// `Allow`). Does not allocate.
    func forEachMatchingTerminal(path: Span<UInt8>, _ visit: (Int32) -> Void) {
        guard path.count > 0, path[0] == UInt8(ascii: "/") else { return }
        collect(node: 0, path: path, position: 1, visit)
    }

    private func collect(node index: Int32, path: Span<UInt8>, position: Int, _ visit: (Int32) -> Void) {
        let node = nodes[Int(index)]
        if position > path.count {
            if node.terminal >= 0 { visit(node.terminal) }
            return
        }
        var end = position
        while end < path.count && path[end] != UInt8(ascii: "/") { end += 1 }
        if node.edgeCount > 0, let child = literalChild(node, path: path, start: position, end: end) {
            collect(node: child, path: path, position: end + 1, visit)
        }
        if node.parameter >= 0, end > position {
            collect(node: node.parameter, path: path, position: end + 1, visit)
        }
        if node.wildcard >= 0 { visit(node.wildcard) }
    }
}
