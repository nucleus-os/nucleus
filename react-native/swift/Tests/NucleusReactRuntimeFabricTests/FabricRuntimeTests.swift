import Foundation
import NucleusReactRuntimeCxx
import Synchronization
import Testing

@MainActor
@Suite struct FabricRuntimeTests {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().path

    /// Compile a trivial JS bundle to Hermes bytecode with the built hermesc.
    static func makeTinyBytecode(
        source: String = "var nucleusFabricValue = 1 + 1;\n"
    ) throws -> String {
        let tmp =
            "\(NSTemporaryDirectory())nucleus-rn-fabric-\(getpid())-\(UInt.random(in: 0..<(.max)))"
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
            env["LD_LIBRARY_PATH"] = [dir, env["LD_LIBRARY_PATH"]].compactMap { $0 }.joined(
                separator: ":")
        }
        let result = try SpawnedCommand.run(
            executable: hermesc,
            arguments: ["-emit-binary", "-out", hbc, js],
            environment: env)
        guard result.status == 0 else {
            throw NSError(
                domain: "FabricRuntimeTests", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "hermesc failed to emit bytecode"])
        }
        return hbc
    }

    @Test func staticReactNativeFabricRuns() throws {
        let hbc = try Self.makeTinyBytecode()
        #expect(RuntimeHost.hermesCanCreateRuntime())
        let host = try RuntimeHost()
        try host.evaluateBytecode(at: hbc)
        _ = try host.drainPendingJSCalls()
    }

    @Test func staticReactNativeFabricInstallsAndEvaluates() throws {
        // Full path through the real RuntimeHost: installFabric (the UIManager,
        // with the Swift mounting-observer + text-layout-manager bridges) + a
        // real bytecode bundle. Proves the static fabric's surface layer wires up
        // headless, not just the runtime core.
        let hbc = try Self.makeTinyBytecode()
        let host = try RuntimeHost()
        try host.installFabric()
        try host.evaluateBytecode(at: hbc)
        _ = try host.drainPendingJSCalls()
    }

    @Test func runtimeFailureCrossesTheCxxBoundary() {
        do {
            let host = try RuntimeHost()
            try host.installFabric()
            try host.evaluateBytecode(at: "/definitely-not-a-nucleus-bundle.hbc")
            Issue.record("missing bytecode unexpectedly evaluated")
        } catch {
            #expect(error is RuntimeHostOperationError)
        }
    }

    @Test func crossThreadJSTimerWorkWakesOncePerPendingBurst() throws {
        let hbc = try Self.makeTinyBytecode(
            source:
                """
                setTimeout(function () {}, 1);
                setTimeout(function () {}, 1);
                """)
        let wakes = Mutex(0)
        let host = try RuntimeHost()
        try host.setJSWorkWakeHandler {
            wakes.withLock { $0 += 1 }
        }
        try host.evaluateBytecode(at: hbc)
        let deadline = ContinuousClock.now + .seconds(2)
        while wakes.withLock({ $0 }) == 0, ContinuousClock.now < deadline {
            usleep(1_000)
        }
        usleep(20_000)
        #expect(wakes.withLock { $0 } == 1)
        #expect(try host.drainPendingJSCalls() > 0)
    }

    @Test func jsThreadCommandDeliveryHopsToMainActor() async throws {
        let hbc = try Self.makeTinyBytecode(
            source:
                """
                global.__turboModuleProxy('NucleusHostCommand')
                  .invoke('activate', '{"window":7}');
                """)
        final class Delivery: @unchecked Sendable {
            @MainActor var value: (String, String)?
        }
        let delivery = Delivery()
        let host = try RuntimeHost()
        try host.setCommandHandler { command, arguments in
            delivery.value = (command, arguments)
        }
        try host.evaluateBytecode(at: hbc)
        for _ in 0..<100 where delivery.value == nil {
            await Task.yield()
        }
        #expect(delivery.value?.0 == "activate")
        #expect(delivery.value?.1 == #"{"window":7}"#)
    }

    @Test func commandHandlerReplacementUsesTheCurrentHandler() async throws {
        let hbc = try Self.makeTinyBytecode(
            source:
                "global.__turboModuleProxy('NucleusHostCommand').invoke('current', '{}');")
        let firstCalls = Mutex(0)
        let secondCalls = Mutex(0)
        let host = try RuntimeHost()
        try host.setCommandHandler { _, _ in
            firstCalls.withLock { $0 += 1 }
        }
        try host.setCommandHandler { _, _ in
            secondCalls.withLock { $0 += 1 }
        }
        try host.evaluateBytecode(at: hbc)
        for _ in 0..<100 where secondCalls.withLock({ $0 }) == 0 {
            await Task.yield()
        }
        #expect(firstCalls.withLock { $0 } == 0)
        #expect(secondCalls.withLock { $0 } == 1)
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
