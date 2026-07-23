import PackagePlugin
import Foundation // Process executes the Vulkan generator tool.

// Command plugin: regenerates the Vulkan binding core from the vendored
// vk.xml into its committed path (generate-once model). Run when the vendored
// Vulkan-Headers bump:
//
//   swift package generate-vulkan --allow-writing-to-package-directory
//
// Output (committed): Sources/Vulkan/Vulkan.swift, compiled by the
// Vulkan target against the VulkanC module.

@main
struct GenerateVulkan: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) throws {
        let root = context.package.directoryURL
        let outFile = root.appending(path: "Sources/Vulkan/Vulkan.swift")
        // Vendored vk.xml (matches the headers in Sources/VulkanC/vulkan).
        let vkXml = root.appending(path: "third-party/vk.xml")

        let tool = try context.tool(named: "VulkanGen")
        let process = Process()
        process.executableURL = tool.url
        // The third arg is an opaque emitter format-version token (cache key only).
        process.arguments = [vkXml.path, outFile.path, "1"]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            Diagnostics.error("VulkanGen failed (exit \(process.terminationStatus))")
            throw GenError.toolFailed
        }
        Diagnostics.remark("Generated Vulkan.swift into Sources/Vulkan/")
    }
}

enum GenError: Error { case toolFailed }
