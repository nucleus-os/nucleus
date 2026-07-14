import PackagePlugin
import Foundation

// Command (provisioning) plugin: stage the core-owned C++ host archives that a
// downstream executable (the compositor) LINKS rather than recompiles. Run once,
// after a normal build, to populate .cxx-build (→ the native SDK's lib/nucleus-cxx-libs):
//
//   swift build                    # (and/or `swift build -c release`)
//   swift package provision-cxx-libs --allow-writing-to-package-directory
//
// Each built configuration is staged under its own subdir (.cxx-build/{debug,release});
// the downstream consumer links the archive matching its own build configuration.
//
// NucleusReactRuntimeHostCxx is the RN host C++ impl. It compiles against the Swift→C++
// header SwiftPM emits for NucleusReactRuntimeCxx — findable only at the DEFINING build's
// location, so a consuming package cannot recompile it (the header lands in the consumer's
// .build, not here). Staging the archive here lets the compositor link the prebuilt result
// and skip the recompile entirely — the last piece of the native/generated-build decoupling.

private let archives = ["libNucleusReactRuntimeHostCxx.a"]

@main
struct ProvisionCxxLibs: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let root = context.package.directoryURL.path
        let staging = root + "/.cxx-build"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: staging, withIntermediateDirectories: true)

        // Stage each built configuration into its own subdir (.cxx-build/debug,
        // .cxx-build/release) so a downstream target links the archive matching ITS
        // build configuration — a debug consumer must not link a release archive (or
        // vice-versa); the object was compiled with different optimization/ABI settings.
        var staged = 0
        for cfg in ["Debug", "Release"] {
            let productDir = "\(root)/.build/out/Products/\(cfg)-linux-x86_64"
            let outDir = "\(staging)/\(cfg.lowercased())"
            for a in archives {
                let src = "\(productDir)/\(a)"
                guard fm.fileExists(atPath: src) else { continue }
                try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
                let dst = "\(outDir)/\(a)"
                try? fm.removeItem(atPath: dst)
                try fm.copyItem(atPath: src, toPath: dst)
                print("provision-cxx-libs: staged \(a) (\(cfg)) → .cxx-build/\(cfg.lowercased())/")
                staged += 1
            }
        }
        if staged == 0 {
            Diagnostics.error("No host-cxx archives found under .build/out/Products — run `swift build` (and/or `swift build -c release`) first.")
        }
    }
}
