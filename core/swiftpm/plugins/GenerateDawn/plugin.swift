import PackagePlugin
import Foundation

// Command plugin: regenerates Dawn's vendored codegen by driving the existing
// first-party script (tools/regenerate-dawn.sh), which runs Dawn's own Python
// generators (DawnJSONGenerator + version/gpu-info) over the Dawn submodule.
// Wrapped, not ported — the generators are upstream Python; the script is the
// single source of truth for targets/paths. Run after a Skia/Dawn bump:
//
//   swift package generate-dawn --allow-writing-to-package-directory
//
// Output (committed): build_zig/generated/dawn_gen/{include,src,webgpu-headers}.
// Requires the dev shell (python3 with jinja2 + markupsafe), which is present
// when this runs through `swift package generate-dawn` on the host.

@main
struct GenerateDawn: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) throws {
        let root = context.package.directoryURL

        let bash = try context.tool(named: "bash")
        let process = Process()
        process.executableURL = bash.url
        process.arguments = ["tools/regenerate-dawn.sh"]
        // The script asserts it runs from the repo root (checks Package.swift).
        process.currentDirectoryURL = root
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            Diagnostics.error("tools/regenerate-dawn.sh failed (exit \(process.terminationStatus))")
            throw GenError.toolFailed
        }
        Diagnostics.remark("Regenerated Dawn codegen into build_zig/generated/dawn_gen")
    }
}

enum GenError: Error { case toolFailed }
