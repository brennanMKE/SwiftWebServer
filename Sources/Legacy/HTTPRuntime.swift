import Foundation
import Network
import os.log

public struct RuntimeConfiguration: Sendable {
    public let rootURL: URL
    public let publicURL: URL
    public let config: HTTPConfig
    public let port: NWEndpoint.Port
    public let listener: NWListener

    func mimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        for type in config.mimeTypes {
            if type.pathExtensions.contains(ext) {
                return type.contentType
            }
        }
        return config.defaultMimeType
    }
}

private enum HTTPRuntimeState: Sendable {
    case none
    case runtimeConfig(RuntimeConfiguration)
    case failed(Error)

    var runtimeConfig: RuntimeConfiguration? {
        switch self {
        case .runtimeConfig(let runtimeConfig):
            runtimeConfig
        default: nil
        }
    }

    var failure: Error? {
        switch self {
        case .failed(let error):
            error
        default:
            nil
        }
    }
}

actor HTTPRuntime {
    enum Failure: Error {
        case invalidState
        case configNotFound
        case notBootstrapped
    }
    private var state: HTTPRuntimeState = .none

    var config: RuntimeConfiguration {
        get throws {
            if let error = state.failure {
                throw error
            }

            guard let runtimeConfig = state.runtimeConfig else {
                logger.error("Not bootstrapped yet. Must run bootstrap first.")
                throw Failure.notBootstrapped
            }

            return runtimeConfig
        }
    }

    var error: Error? {
        state.failure
    }

    func bootstrap(at rootURL: URL) throws -> RuntimeConfiguration {
        guard case .none = state else {
            throw Failure.invalidState
        }

        let configURL = rootURL.appendingPathComponent("http-config.json")
        guard FileManager.default.fileExists(atPath: configURL.path()) else {
            logger.error("http-config.json not found at \(configURL.path(), privacy: .public)")
            throw Failure.configNotFound
        }
        let config = try HTTPConfig.init(configURL: configURL)
        let port = NWEndpoint.Port(rawValue: UInt16(config.port))!
        let publicURL = URL(fileURLWithPath: config.path, relativeTo: rootURL).standardizedFileURL
        // LISTEN_HOST (e.g. 127.0.0.1) restricts the listener to one interface; benchmarks
        // and tests bind loopback only so no firewall prompt can appear (AGENTS.md).
        let listener: NWListener
        if let host = ProcessInfo.processInfo.environment["LISTEN_HOST"], !host.isEmpty {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(host), port: port)
            listener = try NWListener(using: parameters)
        } else {
            listener = try NWListener(using: .tcp, on: port)
        }
        let runtimeConfig = RuntimeConfiguration(rootURL: rootURL, publicURL: publicURL, config: config, port: port, listener: listener)

        logger.log("Listening on port http://localhost:\(config.port)/")

        state = .runtimeConfig(runtimeConfig)

        return runtimeConfig
    }
}
