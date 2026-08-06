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
        let configuration = LanguageServerConfiguration(
            backgroundPreparationMode: "build",
            swiftPM: LanguageServerConfiguration.SwiftPM(
                configuration: invocation.context.configuration.rawValue,
                scratchPath: invocation.scratchPath.string))
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
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try bytes.write(to: url, options: .atomic)
    }
}
