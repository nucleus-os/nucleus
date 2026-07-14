import PackagePlugin
import Foundation

// Command plugin: assemble a runnable install prefix for the compositor — the
// same tree the Zig build's install step produced. Ported from build.zig's
// session-artifacts/install logic.
//
//   cd compositor && swift package install-compositor --allow-writing-to-package-directory
//   # or: ... install-compositor --prefix /some/dir --allow-writing-to-directory /some/dir
//
// Layout (default prefix: compositor/.install):
//   bin/nucleus-compositor            (the built executable)
//   bin/nucleus-session               (session launcher, bash -n checked)
//   bin/nucleus-session-validate      (session validator, bash -n checked)
//   share/systemd/user/nucleus@.service   (ExecStart wired to absolute bin paths)
//
// The compositor links zero React (repo-decomposition Phase 5): it installs no RN
// shell bundle. The shell is an out-of-process layer-shell client (nucleus-shell, or
// any standard shell such as Noctalia), packaged and launched separately.
//
// Runtime library resolution (Swift runtime + system libs) is the packaging
// layer's concern (distribution packaging / loader path) — this step
// only lays down the tree + validates the scripts and unit.
@main
struct InstallCompositor: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) throws {
        let appDir = context.package.directoryURL
        let repoRoot = appDir.deletingLastPathComponent()
        let fm = FileManager.default

        // --prefix <dir> (default <app>/.install)
        var prefix = appDir.appending(path: ".install").path
        if let i = arguments.firstIndex(of: "--prefix"), i + 1 < arguments.count {
            prefix = arguments[i + 1]
        }

        // Build the executable and locate it.
        Diagnostics.remark("Building NucleusCompositor…")
        let result = try packageManager.build(
            .product("NucleusCompositor"),
            parameters: .init(configuration: .debug)
        )
        guard result.succeeded else {
            Diagnostics.error("compositor build failed:\n\(result.logText)")
            throw PluginError.failed
        }
        guard let exe = result.builtArtifacts.first(where: { $0.url.lastPathComponent == "NucleusCompositor" })?.url else {
            Diagnostics.error("could not locate the built NucleusCompositor")
            throw PluginError.failed
        }

        let bin = "\(prefix)/bin"
        let unitDir = "\(prefix)/share/systemd/user"
        for d in [bin, unitDir] {
            try fm.createDirectory(atPath: d, withIntermediateDirectories: true)
        }

        // Executable.
        try copy(exe.path, to: "\(bin)/nucleus-compositor", fm: fm)

        // Session scripts (validated with `bash -n` before install).
        for name in ["nucleus-session", "nucleus-session-validate"] {
            let src = repoRoot.appending(path: "packages/session/\(name)").path
            try run("/usr/bin/env", ["bash", "-n", src], failure: "\(name) is not valid bash")
            let dst = "\(bin)/\(name)"
            try copy(src, to: dst, fm: fm)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dst)
        }

        // systemd user unit: substitute the @bindir@ placeholders with the
        // absolute installed bin paths, then verify it.
        let unitTemplate = try String(
            contentsOf: repoRoot.appending(path: "packages/session/nucleus@.service"), encoding: .utf8)
        let unit = unitTemplate
            .replacingOccurrences(of: "@bindir@/nucleus-session", with: "\(bin)/nucleus-session")
            .replacingOccurrences(of: "@bindir@/nucleus-compositor", with: "\(bin)/nucleus-compositor")
        let unitPath = "\(unitDir)/nucleus@.service"
        try unit.write(toFile: unitPath, atomically: true, encoding: .utf8)
        try run("/usr/bin/env",
                ["systemd-analyze", "--user", "--recursive-errors=no", "verify", unitPath],
                failure: "systemd unit failed verification")

        Diagnostics.remark("Installed compositor prefix → \(prefix)")
    }

    private func copy(_ src: String, to dst: String, fm: FileManager) throws {
        try? fm.removeItem(atPath: dst)
        try fm.copyItem(atPath: src, toPath: dst)
    }

    private func run(_ exe: String, _ args: [String], failure: String) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = ProcessInfo.processInfo.environment
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            Diagnostics.error("\(failure) (exit \(p.terminationStatus))")
            throw PluginError.failed
        }
    }
}

enum PluginError: Error { case failed }
