import PackagePlugin
import Foundation // Process executes React Native code generation.

// Command plugin: regenerates React Native's FBReactNativeSpec codegen by
// driving RN's own upstream generator through tools/generate-rn-spec.js. The
// wrapper forces output outside the vendored checkout.
// Run once per RN version bump:
//
//   swift package generate-rn-spec --allow-writing-to-package-directory
//
// Output: .rn-build/generated/FBReactNativeSpec

@main
struct GenerateRNSpec: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) throws {
        let root = context.package.directoryURL
        let generator = root.appending(path: "tools/generate-rn-spec.js")

        let node = try context.tool(named: "node")
        let process = Process()
        process.executableURL = node.url
        process.arguments = [generator.path]
        process.currentDirectoryURL = root
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            Diagnostics.error("Nucleus RN spec generation failed (exit \(process.terminationStatus))")
            throw GenError.toolFailed
        }
        Diagnostics.remark("Generated FBReactNativeSpec into .rn-build/generated")
    }
}

enum GenError: Error { case toolFailed }
