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
    static func makeTinyBytecode(
        source: String = "var nucleusFabricProbe = 1 + 1;\n"
    ) throws -> String {
        let tmp = "\(NSTemporaryDirectory())nucleus-rn-fabric-\(getpid())-\(UInt.random(in: 0..<(.max)))"
        try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        let js = "\(tmp)/tiny.js"
        let hbc = "\(tmp)/tiny.hbc"
        try source.write(toFile: js, atomically: true, encoding: .utf8)

        let hermesc = "\(repoRoot)/.rn-build/hermes/bin/hermesc"
        // hermesc links libc++ (clang default); put its dir on the loader path —
        // the same fix Collider's Hermes task applies during the build-time
        // hermesc invocation.
        var env = ProcessInfo.processInfo.environment
        if let dir = try libcxxDir() {
            env["LD_LIBRARY_PATH"] = [dir, env["LD_LIBRARY_PATH"]].compactMap { $0 }.joined(separator: ":")
        }
        let result = try SpawnedCommand.run(
            executable: hermesc,
            arguments: ["-emit-binary", "-out", hbc, js],
            environment: env)
        guard result.status == 0 else {
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

    @Test func crossThreadJSTimerWorkWakesOncePerPendingBurst() throws {
        let hbc = try Self.makeTinyBytecode(source:
            """
            setTimeout(function () {}, 1);
            setTimeout(function () {}, 1);
            """)
        let result = hbc.withCString {
            nucleus_rn_js_work_wake_smoke($0)
        }
        #expect(result == 0)
    }

    @Test func mountTransactionsShareOneOrderedDrainPerBurst() {
        #expect(nucleus_rn_mount_batching_smoke() == 0)
    }

    @Test func mountRetirementRejectsPriorGenerationsAndReclaimsState() {
        #expect(nucleus_rn_mount_lifecycle_smoke() == 0)
    }

    @Test func mountEventsRetainOnlyMutationSpecificPayloads() {
        #expect(nucleus_rn_mount_event_payload_smoke() == 0)
    }

    /// `dirname $(clang++ -print-file-name=libc++.so.1)` — the toolchain libc++.
    static func libcxxDir() throws -> String? {
        let result = try SpawnedCommand.run(
            executable: "/usr/bin/env",
            arguments: [
                "clang++",
                "-print-file-name=libc++.so.1",
            ],
            environment: ProcessInfo.processInfo.environment,
            captureOutput: true)
        guard result.status == 0 else { return nil }
        return result.output.isEmpty
            ? nil
            : (result.output as NSString).deletingLastPathComponent
    }
}
