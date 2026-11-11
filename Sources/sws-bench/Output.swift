import Darwin
import Foundation

struct MachineInfo: Codable, Sendable {
    var cpu: String
    var cores: Int
    var memoryGB: Int
    var os: String
    var build: String
    var date: String

    static func current() -> MachineInfo {
        #if DEBUG
        let build = "debug"
        #else
        let build = "release"
        #endif
        let info = ProcessInfo.processInfo
        return MachineInfo(
            cpu: sysctlString("machdep.cpu.brand_string") ?? "unknown",
            cores: info.activeProcessorCount,
            memoryGB: Int(info.physicalMemory >> 30),
            os: info.operatingSystemVersionString,
            build: build,
            date: ISO8601DateFormatter().string(from: Date()))
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

enum JSONOutput {
    static func encode(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
