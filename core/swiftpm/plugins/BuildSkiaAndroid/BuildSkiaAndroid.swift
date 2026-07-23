import PackagePlugin
import Foundation // Process executes the Android Skia provisioning script.

// Build-tool plugin: drive upstream Skia's GN + Ninja build cross-targeting the
// Android NDK (arm64), producing the Vulkan-Graphite archive set the Android
// Skia bridge + render core link. The Android analog of the host BuildSkia plugin
// uses the same native Vulkan Graphite backend (ContextFactory::MakeVulkan), with
// Android's platform font manager instead of fontconfig.
//
// Lands in a persistent in-repo dir (.skia-build/android-arm64, gitignored) so
// gn-gen runs once and ninja stays incremental. The NDK is resolved from the
// environment (matching `tools/nucleus android verify`). Requires --disable-sandbox
// and the host build environment (gn/ninja).

private let ndkVersion = "30.0.14904198"

private func resolveNdk(_ env: [String: String]) -> String {
    if let v = env["NUCLEUS_ANDROID_NDK_HOME"] { return v }
    if let v = env["ANDROID_NDK_HOME"] { return v }
    let sdk = env["ANDROID_SDK_ROOT"] ?? env["ANDROID_HOME"]
        ?? (env["HOME"].map { "\($0)/Android/Sdk" } ?? "")
    return "\(sdk)/ndk/\(ndkVersion)"
}

private let gnFlags = [
    "is_official_build=true", "skia_enable_tools=false",
    "skia_enable_graphite=true", "skia_use_vulkan=true", "skia_use_dawn=false",
    "skia_use_freetype=true", "skia_use_harfbuzz=true", "skia_use_icu=true",
    "skia_use_fontconfig=false", "skia_use_expat=true", "skia_use_zlib=true",
    "skia_use_wuffs=true",
    "skia_use_libpng_decode=true", "skia_use_libpng_encode=true",
    "skia_use_libjpeg_turbo_decode=true", "skia_use_libjpeg_turbo_encode=true",
    "skia_use_libwebp_decode=true", "skia_use_libwebp_encode=true",
    "skia_enable_skshaper=true", "skia_enable_skparagraph=true",
    "skia_enable_skunicode=true", "skia_enable_svg=true", "skia_enable_pdf=true",
    "skia_enable_precompile=true",
    "skia_use_system_expat=false", "skia_use_system_freetype2=false",
    "skia_use_system_harfbuzz=false", "skia_use_system_icu=false",
    "skia_use_system_libjpeg_turbo=false", "skia_use_system_libpng=false",
    "skia_use_system_libwebp=false", "skia_use_system_zlib=false",
]

private let ninjaTargets = ["skia", "skshaper", "skparagraph", "skunicode", "svg"]

@main
struct BuildSkiaAndroid: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let env = ProcessInfo.processInfo.environment
        // This plugin lives in the root package, whose directory IS the repo root.
        let root = context.package.directoryURL.path
        let skia = "\(root)/third-party/skia"
        let build = "\(root)/.skia-build/android-arm64"
        let ndk = resolveNdk(env)

        let args = (["target_os=\"android\"", "target_cpu=\"arm64\"",
                     "ndk=\"\(ndk)\"", "ndk_api=24"] + gnFlags).joined(separator: " ")

        let script = """
        set -e
        cd "\(skia)"
        if [ ! -f "\(build)/build.ninja" ]; then
            ./bin/gn gen "\(build)" --args='\(args)'
        fi
        ninja -C "\(build)" \(ninjaTargets.joined(separator: " "))
        """
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", script]
        proc.environment = env
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            Diagnostics.error("Android Skia build failed (exit \(proc.terminationStatus))")
            return
        }
    }
}
