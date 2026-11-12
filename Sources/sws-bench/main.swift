import Foundation

// sws-bench: microbenchmarks and an HTTP/1.1 load client. See docs/benchmarks/README.md.

let usage = """
    usage: sws-bench <command> [options]

    commands:
      micro    run registered microbenchmarks (ns/op, allocations/op)
      load     drive an HTTP/1.1 server and report req/s and latency
      serve    run the new-stack HTTP/1.1 server with a built-in hello handler
      h1conn   ns and allocations per request of the HTTP/1.1 connection loop
      accept   new-connection rate, per-phase latency and allocations per connection
      proxy    reverse-proxy cost per request over a warm upstream pool (in-process upstream)
      router   Router match microbenchmarks (same as `micro --filter Router`)
      hash-password  print an auth credential line (PBKDF2) for a password read from stdin

    Run `sws-bench <command> --help` for options. With no command, runs `micro`.
    """

let arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "micro"
let rest = Array(arguments.dropFirst())

do {
    let status: Int32
    switch command {
    case "micro":
        status = try MicroCommand.run(rest)
    case "load":
        status = try await LoadCommand.run(rest)
    case "serve":
        status = try await ServeCommand.run(rest)
    case "h1conn":
        status = try await H1ConnBench.run(rest)
    case "accept":
        status = try await AcceptBench.run(rest)
    case "proxy":
        status = try await ProxyBench.run(rest)
    case "router":
        status = try MicroCommand.run(["--filter", "Router"] + rest)
    case "hash-password":
        status = try HashPasswordCommand.run(rest)
    case "help", "--help", "-h":
        print(usage)
        status = 0
    default:
        printError("sws-bench: unknown command '\(command)'\n\n" + usage)
        status = 2
    }
    exit(status)
} catch let failure as Arguments.Failure {
    printError("sws-bench \(command): \(failure)")
    exit(2)
} catch {
    printError("sws-bench \(command): \(error)")
    exit(1)
}
