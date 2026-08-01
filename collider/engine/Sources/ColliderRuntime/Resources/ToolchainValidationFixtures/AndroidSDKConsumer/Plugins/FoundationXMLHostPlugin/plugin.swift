import Foundation
import PackagePlugin

@main
struct FoundationXMLHostPlugin: BuildToolPlugin {
    func createBuildCommands(
        context: PluginContext,
        target: Target
    ) throws -> [Command] {
        let parser = XMLParser(data: Data("<host-tool/>".utf8))
        precondition(parser.parse())
        return []
    }
}
