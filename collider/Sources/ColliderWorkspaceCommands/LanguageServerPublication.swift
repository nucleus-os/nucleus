import ColliderCore
import Foundation
import SystemPackage

private struct LanguageServerConfiguration: Codable {
    struct SwiftPM: Codable {
        let configuration: String
        let scratchPath: String
    }

    let backgroundPreparationMode: String
    let swiftPM: SwiftPM
}

extension WorkspaceContext {
    func publishLanguageServerConfiguration(
        _ invocation: SwiftPMInvocation
    ) throws {
        // The editor prepares in the developer's own storage, never in the
        // build store. Its outputs feed no artifact, and its background
        // preparation is a writer the machine execution lease does not cover,
        // so pointing it at shared build state would put an uncoordinated
        // second writer inside the state deliveries are built from.
        #if os(macOS)
        let scratchPath = MacOSHostStorageLayout.developerOwned()
            .languageServerScratch.string
        #else
        let scratchPath = invocation.scratchPath.string
        #endif
        let configuration = LanguageServerConfiguration(
            backgroundPreparationMode: "build",
            swiftPM: LanguageServerConfiguration.SwiftPM(
                configuration: invocation.context.configuration.rawValue,
                scratchPath: scratchPath))
        var bytes = try JSONEncoder.sorted.encode(configuration)
        bytes.append(UInt8(ascii: "\n"))
        try publishLanguageServerFile(
            bytes,
            to: root.appending(".sourcekit-lsp/config.json"))
    }

    private func publishLanguageServerFile(
        _ bytes: Data,
        to path: FilePath
    ) throws {
        let url = URL(fileURLWithPath: path.string)
        guard (try? Data(contentsOf: url)) != bytes else { return }
        // Editor configuration belongs to the account that owns the source
        // tree. A build executing as the trusted builder reads a checkout it
        // must never write, and has no editor to configure; refusing to publish
        // is correct there rather than a failure of the build.
        guard FileManager.default.isWritableFile(atPath: root.string) else { return }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try bytes.write(to: url, options: .atomic)
    }
}
