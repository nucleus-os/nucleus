import NucleusConfig
import NucleusConfigIO
import NucleusConfigService
import NucleusSessionProtocol
import Testing

@Suite struct ConfigurationServiceStateTests {
    private let epoch = ConfigurationServiceEpoch(high: 12, low: 34)

    @Test func invalidStartupPublishesDefaultsAndDiagnostics() {
        var state = ConfigurationServiceState(
            epoch: epoch,
            startup: ConfigLoader.load(text: "{"))
        #expect(state.snapshot.configuration == .defaults)
        #expect(state.snapshot.generation.rawValue == 1)
        #expect(state.snapshot.diagnostics.contains {
            $0.severity == .error
        })
        if case .diagnostics = state.reload(ConfigLoader.load(text: "{")) {
        } else {
            Issue.record("invalid reload must preserve the snapshot")
        }
        #expect(state.snapshot.generation.rawValue == 1)
    }

    @Test func removalPublishesDefaultsAsNewGeneration() {
        let configured = """
        {"input":{"keyboard":{"repeat_rate":42}}}
        """
        var state = ConfigurationServiceState(
            epoch: epoch,
            startup: ConfigLoader.load(text: configured))
        #expect(state.snapshot.configuration.input.keyboard.repeatRate == 42)
        if case .adopted(let snapshot) = state.fileRemoved() {
            #expect(snapshot.configuration == .defaults)
            #expect(snapshot.generation.rawValue == 2)
        } else {
            Issue.record("removal must publish defaults")
        }
    }

    @Test func semanticDuplicateDoesNotAdvanceGeneration() {
        var state = ConfigurationServiceState(
            epoch: epoch,
            startup: .loaded(.defaults, warnings: []))
        let duplicate = ConfigLoader.load(text: """
        {"config_version":1}
        """)
        if case .unchanged = state.reload(duplicate) {
        } else {
            Issue.record("semantic duplicate must coalesce")
        }
        #expect(state.snapshot.generation.rawValue == 1)
    }

    @Test func projectionsAreRoleSpecific() {
        let state = ConfigurationServiceState(
            epoch: epoch,
            startup: .loaded(.defaults, warnings: []))
        let server = state.snapshot.publication(for: .renderServer)
        let shell = state.snapshot.publication(for: .shell)
        #expect(server.renderServerConfiguration != nil)
        #expect(server.shellConfiguration == nil)
        #expect(shell.shellConfiguration != nil)
        #expect(shell.renderServerConfiguration == nil)
    }

    @Test func atomicReplaceValidatesBeforeTouchingActiveFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "nucleus-config-service-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("config.json")
        try Data("{\"config_version\":1}".utf8).write(to: path)
        let file = try #require(ActiveConfigurationFile(path: path.path))

        #expect(throws: ActiveConfigurationFileFailure.self) {
            try file.replace(source: "{")
        }
        #expect(try String(contentsOf: path, encoding: .utf8)
            == "{\"config_version\":1}")

        let source = """
        {"input":{"keyboard":{"repeat_rate":48}}}
        """
        let result = try file.replace(source: source)
        guard case .loaded(let configuration, _) = result else {
            Issue.record("valid replacement must resolve")
            return
        }
        #expect(configuration.input.keyboard.repeatRate == 48)
        #expect(try String(contentsOf: path, encoding: .utf8) == source)
    }

    @Test func serviceReplacePublishesOnceAndWatcherDuplicateCoalesces() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "nucleus-config-service-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try #require(ActiveConfigurationFile(
            path: directory.appendingPathComponent("config.json").path))
        var state = ConfigurationServiceState(
            epoch: epoch,
            startup: .loaded(.defaults, warnings: []))
        let source = """
        {"input":{"keyboard":{"repeat_rate":51}}}
        """

        guard case .adopted(let publication) = try state.replace(
            source: source,
            activeFile: file)
        else {
            Issue.record("replace must publish")
            return
        }
        #expect(publication.generation.rawValue == 2)
        guard case .unchanged = state.reload(file.load()) else {
            Issue.record("rename watcher event must coalesce")
            return
        }
        #expect(state.snapshot.generation.rawValue == 2)
    }
}
import Foundation
