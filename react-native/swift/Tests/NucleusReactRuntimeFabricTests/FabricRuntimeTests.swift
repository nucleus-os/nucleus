import Foundation
import Testing
import NucleusReactFabricSmokeC

// Proves the statically-linked full React Native fabric (react_native +
// react_cxx_platform + yogacore + folly + static Hermes) *runs*, not just links:
// the smoke entry (in the RN host C++) creates the Hermes runtime, builds the
// Fabric runtime, evaluates a real Hermes bytecode bundle, and drains the JS
// queue — all on this thread (the runtime is single-threaded). A broken/ODR-
// violated static link would crash rather than return 0.
@MainActor
@Suite struct FabricRuntimeTests {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().path

    /// Compile a trivial JS bundle to Hermes bytecode with the built hermesc.
    static func makeTinyBytecode() throws -> String {
        let tmp = "\(NSTemporaryDirectory())nucleus-rn-fabric-\(getpid())-\(UInt.random(in: 0..<(.max)))"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        let js = "\(tmp)/tiny.js"
        let hbc = "\(tmp)/tiny.hbc"
        try "var nucleusFabricProbe = 1 + 1;\n".write(toFile: js, atomically: true, encoding: .utf8)

        let hermesc = Process()
        hermesc.executableURL = URL(fileURLWithPath: "\(repoRoot)/.rn-build/hermes/bin/hermesc")
        hermesc.arguments = ["-emit-binary", "-out", hbc, js]
        // hermesc links libc++ (clang default); put its dir on the loader path —
        // the same fix BuildHermes applies for the build-time hermesc invocation.
        var env = ProcessInfo.processInfo.environment
        if let dir = libcxxDir() {
            env["LD_LIBRARY_PATH"] = [dir, env["LD_LIBRARY_PATH"]].compactMap { $0 }.joined(separator: ":")
        }
        hermesc.environment = env
        try hermesc.run()
        hermesc.waitUntilExit()
        guard hermesc.terminationStatus == 0 else {
            throw NSError(domain: "FabricRuntimeTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "hermesc failed to emit bytecode"])
        }
        return hbc
    }

    @Test func staticReactNativeFabricRuns() throws {
        let hbc = try Self.makeTinyBytecode()
        let rc = hbc.withCString { nucleus_rn_fabric_smoke($0) }
        #expect(rc == 0, "static RN fabric smoke failed at step \(rc)")
    }

    @Test func staticReactNativeFabricInstallsAndEvaluates() throws {
        // Full path through the real RuntimeHost: installFabric (the UIManager,
        // with the Swift mounting-observer + text-layout-manager bridges) + a
        // real bytecode bundle. Proves the static fabric's surface layer wires up
        // headless, not just the runtime core.
        let hbc = try Self.makeTinyBytecode()
        let rc = hbc.withCString { nucleus_rn_fabric_full_smoke($0) }
        #expect(rc == 0, "full RN fabric smoke failed (rc \(rc))")
    }

    @Test func runtimeFailureCrossesTheCxxBoundary() {
        let rc = "/definitely-not-a-nucleus-bundle.hbc".withCString {
            nucleus_rn_fabric_full_smoke($0)
        }
        #expect(rc == 2, "runtime failure should return through Swift instead of aborting")
    }


    /// `dirname $(clang++ -print-file-name=libc++.so.1)` — the toolchain libc++.
    static func libcxxDir() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["clang++", "-print-file-name=libc++.so.1"]
        let pipe = Pipe()
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? nil : (out as NSString).deletingLastPathComponent
    }
}
