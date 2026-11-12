import Foundation
import HTTPCore
import Testing
@testable import ConfigFile

/// The `accessLog` key (#0125): parsing, errors naming the key, and the chain it registers.
@Suite struct ConfigFileAccessLogTests {
    func parse(_ json: String, base: String = ".") throws(ConfigFileError) -> ConfigFile {
        var defaults = ServerSettings()
        defaults.baseDirectory = base
        return try ConfigFile.parse(Data(json.utf8), source: "test.json", defaults: defaults)
    }

    func expectError(_ json: String, key: String, contains text: String? = nil) {
        do {
            _ = try parse(json)
            Issue.record("accepted: \(json)")
        } catch {
            #expect(error.key == key, "\(json): \(error)")
            if let text { #expect(error.description.contains(text), "\(error)") }
        }
    }

    @Test func offByDefault() throws {
        #expect(try parse("{}").settings.accessLog == nil)
        #expect(try parse(#"{"accessLog": false}"#).settings.accessLog == nil)
        #expect(try parse(#"{"accessLog": null}"#).settings.accessLog == nil)
        #expect(try parse(#"{"accessLog": {"enabled": false, "path": "x.log"}}"#).settings.accessLog == nil)
    }

    @Test func shorthands() throws {
        let on = try #require(try parse(#"{"accessLog": true}"#).settings.accessLog)
        #expect(on.output == .standardOutput)
        #expect(on.format == .common)
        #expect(on.metricsPath == nil)
        #expect(on.flushInterval == .seconds(1))
        #expect(try parse(#"{"accessLog": "logs/access.log"}"#).settings.accessLog?.output == .file("logs/access.log"))
        #expect(try parse(#"{"accessLog": "stderr"}"#).settings.accessLog?.output == .standardError)
        #expect(try parse(#"{"accessLog": "stdout"}"#).settings.accessLog?.output == .standardOutput)
    }

    @Test func objectKeysApply() throws {
        let file = try parse(#"""
            {"accessLog": {"path": "logs/access.log", "format": "combined", "metrics": "/_metrics", "flushInterval": 0.25}}
            """#, base: "/srv/sws")
        #expect(file.warnings.isEmpty, "\(file.warnings)")
        let log = try #require(file.settings.accessLog)
        #expect(log.output == .file("logs/access.log"))
        #expect(log.format == .combined)
        #expect(log.metricsPath == "/_metrics")
        #expect(log.flushInterval == .milliseconds(250))
        #expect(file.settings.resolvedAccessLogPath == "/srv/sws/logs/access.log")
        #expect(try parse(#"{"accessLog": {"path": "/var/log/a.log"}}"#, base: "/srv").settings.resolvedAccessLogPath == "/var/log/a.log")

        #expect(try parse(#"{"accessLog": {"format": "json"}}"#).settings.accessLog?.format == .json)
        #expect(try parse(#"{"accessLog": {"metrics": true}}"#).settings.accessLog?.metricsPath == "/metrics")
        #expect(try parse(#"{"accessLog": {"metrics": false}}"#).settings.accessLog?.metricsPath == nil)
        let metricsOnly = try #require(try parse(#"{"accessLog": {"path": null, "metrics": "/m"}}"#).settings.accessLog)
        #expect(metricsOnly.output == nil)
        #expect(metricsOnly.metricsPath == "/m")
    }

    @Test func unknownNestedKeysWarn() throws {
        let file = try parse(#"{"accessLog": {"path": "stdout", "rotate": true}}"#)
        #expect(file.warnings.count == 1)
        #expect(file.warnings.contains { $0.contains("unknown key \"accessLog.rotate\"") })
    }

    @Test func badValuesNameTheKey() {
        expectError(#"{"accessLog": 1}"#, key: "accessLog")
        expectError(#"{"accessLog": ""}"#, key: "accessLog")
        expectError(#"{"accessLog": {"path": 3}}"#, key: "accessLog.path")
        expectError(#"{"accessLog": {"path": ""}}"#, key: "accessLog.path")
        expectError(#"{"accessLog": {"format": "apache"}}"#, key: "accessLog.format", contains: "\"combined\"")
        expectError(#"{"accessLog": {"metrics": "metrics"}}"#, key: "accessLog.metrics")
        expectError(#"{"accessLog": {"metrics": "/m?x=1"}}"#, key: "accessLog.metrics")
        expectError(#"{"accessLog": {"flushInterval": 0}}"#, key: "accessLog.flushInterval")
        expectError(#"{"accessLog": {"flushInterval": "1s"}}"#, key: "accessLog.flushInterval")
        expectError(#"{"accessLog": {"enabled": "yes"}}"#, key: "accessLog.enabled")
        expectError(#"{"accessLog": {"path": null}}"#, key: "accessLog.path", contains: "nothing to record")
    }

    @Test func handlerRegistersTheLogOnlyWhenEnabled() throws {
        let directory = try ConfigFileTests.Directory()
        try directory.write("hi\n", to: "Public/index.html")
        let off = try parse("{}", base: directory.path).settings.makeHandler()
        #expect(MiddlewareChainInspector.serverComponents(in: off).isEmpty)
        #expect(!MiddlewareChainInspector.needsRequestStartTime(off))

        let file = try parse(#"{"accessLog": {"path": "logs/access.log", "metrics": "/metrics"}, "compression": true}"#,
                             base: directory.path)
        // The file is created; its directory is not.
        do {
            _ = try file.settings.makeHandler()
            Issue.record("missing log directory accepted")
        } catch {
            #expect(error.key == "accessLog.path")
            #expect(error.description.contains("logs/access.log"), "\(error)")
        }
        try directory.write("", to: "logs/.keep")
        let on = try file.settings.makeHandler()
        #expect(MiddlewareChainInspector.serverComponents(in: on).count == 1)
        #expect(MiddlewareChainInspector.connectionObservers(in: on).count == 1)
        #expect(MiddlewareChainInspector.needsRequestStartTime(on))
        #expect(FileManager.default.fileExists(atPath: directory.path + "/logs/access.log"))
    }

    @Test(.timeLimit(.minutes(1)))
    func metricsEndpointIsServed() async throws {
        let directory = try ConfigFileTests.Directory()
        try directory.write("hi\n", to: "Public/index.html")
        let handler = try parse(#"{"accessLog": {"path": null, "metrics": "/_m"}}"#, base: directory.path).settings.makeHandler()
        #expect(try await ConfigFileHostsTests.status(handler, "a.test", "/_m") == 200)
        #expect(try await ConfigFileHostsTests.status(handler, "a.test", "/index.html") == 200)
        #expect(try await ConfigFileHostsTests.status(handler, "a.test", "/metrics") == 404)
    }
}
