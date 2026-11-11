import HTTP1
import HTTPCore
import HTTPServer
import NetworkTransport

// Benchmark harness placeholder. The real skeleton arrives in issue 0.2 (docs/ROADMAP.md §8).
let modules = [HTTPCoreModule.name, HTTP1Module.name, HTTPServerModule.name, NetworkTransportModule.name]
print("sws-bench: no benchmarks yet (linked: \(modules.joined(separator: ", ")))")
