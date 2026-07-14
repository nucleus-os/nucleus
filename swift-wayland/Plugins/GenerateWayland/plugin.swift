import PackagePlugin
import Foundation

// Regenerates the three committed Wayland C modules from the vendored protocol XML over the full
// set (all of Protocols/, minus core wayland.xml and the deprecated/duplicate protocol versions
// whose stable successors are already present — those would define duplicate wl_interface symbols):
//
//   swift package generate-wayland --allow-writing-to-package-directory
//
//   Sources/WaylandServerC/     WaylandServerC.h + module.modulemap + <name>-server-protocol.h
//   Sources/WaylandClientC/     WaylandClientC.h + module.modulemap + <name>-client-protocol.h
//   Sources/WaylandProtocolsC/  <name>-protocol.c  (the mode-independent marshalling)
//
// The protocol set is enumerated + sorted so regeneration is byte-stable.

@main
struct GenerateWayland: CommandPlugin {
    // Deprecated/duplicate XML excluded to avoid duplicate wl_interface definitions; the kept
    // successor is noted. Matched as a path suffix so only the intended copy is dropped.
    static let excludedSuffixes = [
        "wayland-protocols/unstable/tablet/tablet-unstable-v2.xml",          // → stable/tablet/tablet-v2
        "wayland-protocols/unstable/xdg-shell/xdg-shell-unstable-v5.xml",    // → stable/xdg-shell
        "wayland-protocols/unstable/linux-dmabuf/linux-dmabuf-unstable-v1.xml", // → stable/linux-dmabuf
        "protocols/presentation-time.xml",                                  // dup of stable/presentation-time
    ]

    func performCommand(context: PluginContext, arguments: [String]) throws {
        let root = context.package.directoryURL
        let protocolsRoot = root.appending(path: "Protocols")
        let waylandXML = protocolsRoot.appending(path: "protocols/wayland.xml")
        let fm = FileManager.default

        // Enumerate every vendored .xml, drop core wayland.xml (passed separately) + the excluded
        // versions, sort for a stable protocol order.
        var protoXMLs: [String] = []
        if let e = fm.enumerator(at: protocolsRoot, includingPropertiesForKeys: nil) {
            for case let url as URL in e where url.pathExtension == "xml" {
                let path = url.path
                if url.lastPathComponent == "wayland.xml" { continue }
                if Self.excludedSuffixes.contains(where: { path.hasSuffix($0) }) { continue }
                // Skip any XML that isn't a Wayland protocol (e.g. stray xcb/registry files) — it
                // would parse to an empty protocol name and emit a broken "-protocol.h" include.
                guard let text = try? String(contentsOf: url, encoding: .utf8),
                      text.contains("<protocol ") else { continue }
                protoXMLs.append(path)
            }
        }
        protoXMLs.sort()

        let serverDir = root.appending(path: "Sources/WaylandServerC")
        let clientDir = root.appending(path: "Sources/WaylandClientC")
        let protocolsDir = root.appending(path: "Sources/WaylandProtocolsC")
        for dir in [serverDir, clientDir, protocolsDir] {
            try? fm.removeItem(at: dir)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // WaylandServerDispatch is entirely generated (one file per interface + Handles.swift);
        // wipe it so a dropped/renamed interface leaves no stale file. (Its sibling WaylandServer —
        // the hand-written ergonomic trio — lives in a separate dir and is untouched.)
        let dispatchDir = root.appending(path: "Sources/WaylandServerDispatch")
        let clientDispatchDir = root.appending(path: "Sources/WaylandClientDispatch")
        for d in [dispatchDir, clientDispatchDir] {
            try? fm.removeItem(at: d)
            try fm.createDirectory(at: d, withIntermediateDirectories: true)
        }
        let emptyInclude = protocolsDir.appending(path: "include")
        try fm.createDirectory(at: emptyInclude, withIntermediateDirectories: true)
        try Data().write(to: emptyInclude.appending(path: ".gitkeep"))

        let gen = try context.tool(named: "SwiftWaylandGen").url
        let searchDirs = ["--search-dir", protocolsRoot.appending(path: "protocols").path,
                          "--search-dir", protocolsRoot.appending(path: "wayland-protocols").path]

        // 1. Aggregating server + client headers (+ module.modulemap) over the full set. The
        //    server pass also emits the typed Swift dispatch layer (WaylandServerDispatch) for
        //    every server interface with typed requests (interfaces whose only new_id is untyped
        //    bind-style — wl_registry — are skipped by the generator, as libwayland handles bind).
        for (mode, module, dir) in [("server", "WaylandServerC", serverDir),
                                    ("client", "WaylandClientC", clientDir)] {
            let dispatch = mode == "server"
                ? ["--dispatch", dispatchDir.path]
                : ["--dispatch", clientDispatchDir.path]
            try run(gen, ["--mode", mode, "--module", module] + searchDirs + dispatch
                        + [dir.path, waylandXML.path] + protoXMLs,
                    label: "SwiftWaylandGen (\(mode))")
        }

        // 2. wayland-scanner over the resolved closure the server pass wrote (selected +
        //    pulled-in deps): a server header, a client header, and the shared marshalling .c.
        let scanner = try context.tool(named: "wayland-scanner").url
        let manifest = try String(contentsOf: serverDir.appending(path: "generated-protocols.tsv"),
                                  encoding: .utf8)
        for line in manifest.split(separator: "\n") {
            let f = line.split(separator: "\t", maxSplits: 1)
            guard f.count == 2 else { continue }
            let (name, xml) = (String(f[0]), String(f[1]))
            try run(scanner, ["server-header", xml, serverDir.appending(path: "\(name)-server-protocol.h").path],
                    label: "wayland-scanner server-header \(name)")
            try run(scanner, ["client-header", xml, clientDir.appending(path: "\(name)-client-protocol.h").path],
                    label: "wayland-scanner client-header \(name)")
            try run(scanner, ["private-code", xml, protocolsDir.appending(path: "\(name)-protocol.c").path],
                    label: "wayland-scanner private-code \(name)")
        }
        for dir in [serverDir, clientDir] {
            try? fm.removeItem(at: dir.appending(path: "generated-protocols.tsv"))
        }
        Diagnostics.remark("Generated WaylandServerC/WaylandClientC/WaylandProtocolsC (\(protoXMLs.count) protocols)")
    }

    private func run(_ tool: URL, _ args: [String], label: String) throws {
        let p = Process()
        let stderr = Pipe()
        p.executableURL = tool
        p.arguments = args
        p.standardError = stderr
        try p.run()
        p.waitUntilExit()
        let diagnostic = String(
            decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if p.terminationStatus != 0 {
            Diagnostics.error(
                "\(label) failed (exit \(p.terminationStatus))"
                    + (diagnostic.isEmpty ? "" : ": \(diagnostic)"))
            throw GenerateError.toolFailed(label)
        }
        if diagnostic.contains("XML failed validation against built-in DTD") {
            Diagnostics.warning(
                "\(label): input uses protocol XML accepted by wayland-scanner but not its "
                    + "older built-in DTD; generated output was retained")
        } else if !diagnostic.isEmpty {
            Diagnostics.remark("\(label): \(diagnostic)")
        }
    }
}

enum GenerateError: Error { case toolFailed(String) }
