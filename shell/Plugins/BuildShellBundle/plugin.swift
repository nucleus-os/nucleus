import PackagePlugin
import Foundation

// Command plugin: bundle the shell's RN app to Hermes bytecode. Mirrors the RN platform's
// Bundle the out-of-process shell app with Metro, then compile it with hermesc,
// producing .rn-build/bundles/bar.hbc.
// — the file the executable loads (NUCLEUS_SHELL_BUNDLE, a file:// URL) and feeds to
// NucleusReactRuntime.Host.evaluateBundle with moduleName "bar".
//
//   swift package build-shell-bundle --allow-writing-to-package-directory
//
// hermesc + node_modules are provisioned in the embedded RN platform's .rn-build; this reuses
// them so the shell needs no separate native provisioning.
@main
struct BuildShellBundle: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) throws {
        let root = context.package.directoryURL
        let js = root.appending(path: "js")
        let rnRoot = root.appending(path: "../react-native")
        let outDir = root.appending(path: ".rn-build/bundles")
        let hermesc = rnRoot.appending(path: ".rn-build/hermes/bin/hermesc").path

        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let bundleJS = outDir.appending(path: "bar.bundle.js").path
        let hbc = outDir.appending(path: "bar.hbc").path

        // 1. Metro build → plain JS bundle.
        try shell("""
            cd \(js.path) && \
            NODE_PATH="$PWD/node_modules${NODE_PATH:+:$NODE_PATH}" \
              node_modules/.bin/metro build bundles/bar/index.jsx \
              --config tools/metro.config.js \
              --out \(bundleJS) \
              --platform nucleus --dev false --minify true
            """, label: "metro build bar")

        // 2. hermesc → Hermes bytecode (.hbc). libc++ on LD_LIBRARY_PATH for the prebuilt hermesc.
        let hermesLib = rnRoot.appending(path: ".rn-build/hermes/lib").path
        try shell("""
            LD_LIBRARY_PATH=\(hermesLib):${LD_LIBRARY_PATH:-} \
            \(hermesc) -emit-binary -out \(hbc) \(bundleJS)
            """, label: "hermesc bar")

        Diagnostics.remark("Bundled the shell bar → \(hbc)")
    }

    private func shell(_ script: String, label: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            Diagnostics.error("\(label) failed (exit \(p.terminationStatus))")
            throw PluginError.failed(label)
        }
    }
}

enum PluginError: Error { case failed(String) }
