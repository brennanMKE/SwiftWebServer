import Foundation

// sws-bench: microbenchmarks and an HTTP/1.1 load client. See docs/benchmarks/README.md.

let usage = """
    usage: sws-bench <command> [options]

    commands:
      micro    run registered microbenchmarks (ns/op, allocations/op)
      load     drive an HTTP/1.1 server and report req/s and latency

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
