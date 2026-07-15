import PackagePlugin
import Foundation

// Command (provisioning) plugin: drives upstream Skia's own GN + Ninja build to
// produce the Graphite + Dawn + Vulkan archive set the renderer links, into the
// gitignored .skia-build/graphite. Run once to provision the native SDK:
//
//   swift package build-skia --allow-writing-to-package-directory
//
// This is a *command*, not a build-tool plugin: the native build is decoupled from
// the SwiftPM target build so that (a) consuming Nucleus from another package/repo
// doesn't trigger a Skia build it can't satisfy, and (b) `swift build` just consumes
// the prebuilt archives through the native SDK. gn-gen runs once; ninja stays
// incremental. Requires the dev shell (gn/ninja/clang).

private let gnArgs = [
    "is_official_build=true", "skia_enable_tools=false",
    "skia_enable_graphite=true", "skia_use_dawn=true", "skia_use_vulkan=true",
    // CEF owns the process-wide PartitionAlloc shim in CEF-enabled hosts. Keep
    // the standalone render SDK allocator-neutral so embedding it cannot add a
    // second malloc/free owner to the process.
    "skia_use_partition_alloc=false",
    "dawn_enable_vulkan=true", "dawn_enable_d3d11=false", "dawn_enable_d3d12=false",
    "dawn_enable_metal=false", "dawn_enable_opengles=false",
    "skia_use_freetype=true", "skia_use_harfbuzz=true", "skia_use_icu=true",
    "skia_use_fontconfig=true", "skia_use_expat=true", "skia_use_zlib=true",
    "skia_use_wuffs=true",
    "skia_use_libpng_decode=true", "skia_use_libpng_encode=true",
    "skia_use_libjpeg_turbo_decode=true", "skia_use_libjpeg_turbo_encode=true",
    "skia_use_libwebp_decode=true", "skia_use_libwebp_encode=true",
    "skia_enable_skshaper=true", "skia_enable_skparagraph=true",
    "skia_enable_skunicode=true", "skia_enable_svg=true", "skia_enable_pdf=true",
    "skia_enable_precompile=true",
    // Build every external from the vendored source (is_official_build flips these
    // to system libs whose headers are off the dev-shell include path).
    "skia_use_system_expat=false", "skia_use_system_freetype2=false",
    "skia_use_system_harfbuzz=false", "skia_use_system_icu=false",
    "skia_use_system_libjpeg_turbo=false", "skia_use_system_libpng=false",
    "skia_use_system_libwebp=false", "skia_use_system_zlib=false",
    #"cc="clang""#, #"cxx="clang++""#,
].joined(separator: " ")

// Ninja targets covering the archive set the renderer + façade link.
private let ninjaTargets = ["skia", "skshaper", "skparagraph", "skunicode", "svg"]

@main
struct BuildSkia: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let root = context.package.directoryURL.path
        let skia = "\(root)/third-party/skia"
        let build = "\(root)/.skia-build/graphite"
        let script = """
        set -e
        cd "\(skia)"
        ./bin/gn gen "\(build)" --args='\(gnArgs)'
        ninja -C "\(build)" \(ninjaTargets.joined(separator: " "))
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", script]
        proc.environment = ProcessInfo.processInfo.environment
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            Diagnostics.error("Skia build failed (exit \(proc.terminationStatus))")
            return
        }
    }
}
