import Foundation
import SystemPackage
import Testing

@testable import ColliderWorkspaceCommands

@Test func inferredSnippetTargetsUseResolvedConfigurationAndMissingDeclaredTargetsFailClosed()
    throws
{
    let resolved = Data(
        #"{"name":"basic-usage","type":"snippet","target_dependencies":["Logging"]}"#.utf8)
    let configuration = try SwiftPackageGraphResolver.targetConfiguration(
        name: "basic-usage", type: "snippet", declared: nil,
        resolved: resolved, packageRoot: FilePath("/fixture"))
    #expect(configuration == String(decoding: resolved, as: UTF8.self))
    #expect(throws: (any Error).self) {
        try SwiftPackageGraphResolver.targetConfiguration(
            name: "Logging", type: "library", declared: nil,
            resolved: resolved, packageRoot: FilePath("/fixture"))
    }
}

@Test func evaluatedManifestIdentitySeparatesSelectedDeclarationsAndPreservesUnknownSettings()
    throws
{
    func parse(_ text: String) throws -> SwiftPackageGraphResolver.ManifestConfiguration {
        try SwiftPackageGraphResolver.parsedManifestConfiguration(
            Data(text.utf8), packageRoot: FilePath("/fixture"))
    }
    let first = try parse(
        #"{"name":"Fixture","futureCompilerSetting":true,"targets":[{"name":"App","resources":[{"path":"Assets"}]}],"products":[{"name":"App","type":{"executable":null}}],"dependencies":[]}"#
    )
    let expanded = try parse(
        #"{"dependencies":[{"unrelated":"pin"}],"products":[{"type":{"executable":null},"name":"App"},{"name":"Other"}],"targets":[{"resources":[{"path":"Assets"}],"name":"App"},{"name":"Other"}],"futureCompilerSetting":true,"name":"Fixture"}"#
    )
    #expect(first.package == expanded.package)
    #expect(first.targets["App"] == expanded.targets["App"])
    #expect(first.products["App"] == expanded.products["App"])
    #expect(first.package.contains("futureCompilerSetting"))
    #expect(first.targets["App"]?.contains("Assets") == true)
    #expect(first.targets["Other"] == nil)
    #expect(expanded.targets["Other"] != nil)
}

@Test func duplicateManifestDeclarationsAreRejected() {
    #expect(throws: (any Error).self) {
        try SwiftPackageGraphResolver.parsedManifestConfiguration(
            Data(#"{"targets":[{"name":"App"},{"name":"App"}],"products":[]}"#.utf8),
            packageRoot: FilePath("/fixture"))
    }
}
