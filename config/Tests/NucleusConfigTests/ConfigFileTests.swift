import FoundationEssentials
import Testing
@testable import NucleusConfig
@testable import NucleusConfigIO

@Suite struct ConfigFileTests {
    // MARK: path resolution

    @Test func prefersXdgConfigHomeWhenItIsSet() {
        let path = ConfigFile.defaultPath(environment: [
            "XDG_CONFIG_HOME": "/xdg", "HOME": "/home/someone",
        ])
        #expect(path == "/xdg/nucleus/config.json")
    }

    @Test func fallsBackToTheHomeDotConfigLocation() {
        let path = ConfigFile.defaultPath(environment: ["HOME": "/home/someone"])
        #expect(path == "/home/someone/.config/nucleus/config.json")
    }

    @Test func anEmptyXdgConfigHomeIsTreatedAsUnset() {
        // An exported-but-empty variable is a common shell accident; honoring it
        // literally would look for "/nucleus/config.json".
        let path = ConfigFile.defaultPath(environment: [
            "XDG_CONFIG_HOME": "", "HOME": "/home/someone",
        ])
        #expect(path == "/home/someone/.config/nucleus/config.json")
    }

    @Test func noLocationIsResolvableWithoutEitherVariable() {
        #expect(ConfigFile.defaultPath(environment: [:]) == nil)
    }

    // MARK: reading

    private func withTemporaryFile(
        _ contents: String, _ body: (String) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(
                path: "nucleus-config-tests-\(UInt64.random(in: 0..<UInt64.max))")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "config.json")
        try Data(contents.utf8).write(to: file)
        try body(file.path)
    }

    @Test func anAbsentFileResolvesToDefaultsWithoutComplaint() throws {
        // Never having written a configuration is not an error state, and the
        // session has to come up either way.
        switch ConfigFile.load(path: "/nonexistent/nucleus/config.json") {
        case .loaded(let configuration, let warnings):
            #expect(configuration == NucleusConfiguration.defaults)
            #expect(warnings.isEmpty)
        case .failed(let diagnostics):
            Issue.record("expected defaults, got \(diagnostics.count) errors")
        }
    }

    @Test func aRealFileResolvesThroughTheSamePipelineAsText() throws {
        try withTemporaryFile("""
        {
          // written by hand, comments and all
          "input": { "touchpad": { "tap": false, "accel_speed": 0.5 } }
        }
        """) { path in
            switch ConfigFile.load(path: path) {
            case .loaded(let configuration, let warnings):
                #expect(configuration.input.touchpad.tap == false)
                #expect(configuration.input.touchpad.accelSpeed == 0.5)
                #expect(warnings.isEmpty)
            case .failed(let diagnostics):
                Issue.record(
                    "expected success: \(diagnostics.map(\.summary))")
            }
        }
    }

    @Test func aMalformedFileFailsWithALocationRatherThanResolving() throws {
        try withTemporaryFile("{ \"input\": { \n") { path in
            switch ConfigFile.load(path: path) {
            case .loaded:
                Issue.record("expected a syntax failure")
            case .failed(let diagnostics):
                let diagnostic = try #require(diagnostics.first)
                #expect(diagnostic.severity == .error)
                #expect(diagnostic.location != nil)
            }
        }
    }

    @Test func anOutOfRangeAccelSpeedLoadsButWarns() throws {
        try withTemporaryFile(#"""
        { "input": { "mouse": { "accel_speed": 7 } } }
        """#) { path in
            switch ConfigFile.load(path: path) {
            case .loaded(_, let warnings):
                let warning = try #require(warnings.first)
                #expect(warning.severity == .warning)
                #expect(warning.keyPath == ["input", "mouse", "accel_speed"])
            case .failed(let diagnostics):
                Issue.record("expected a warning, got \(diagnostics.count) errors")
            }
        }
    }
}
