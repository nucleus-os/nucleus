import CxxStdlib
import Foundation
import NucleusAppHostProtocols
import NucleusReactRuntime
import NucleusReactRuntimeCxx
import NucleusReactRuntimeCxxBridge
import Synchronization
import Testing

@MainActor
private final class TestPresentationFrameSource:
    NucleusPresentationFrameSource
{
    struct RequestFailure: Error {}

    var rejectsRequests = false
    private(set) var requestCount = 0
    private(set) var cancellationCount = 0
    private var completion: (@MainActor @Sendable (UInt64) -> Void)?

    func requestPresentationFrame(
        _ completion: @escaping @MainActor @Sendable (UInt64) -> Void
    ) throws {
        requestCount += 1
        if rejectsRequests { throw RequestFailure() }
        precondition(self.completion == nil)
        self.completion = completion
    }

    func cancelPresentationFrame() {
        cancellationCount += 1
        completion = nil
    }

    func deliver(_ timestampNanoseconds: UInt64) {
        let completion = completion
        self.completion = nil
        completion?(timestampNanoseconds)
    }
}

@safe private final class CrossThreadRuntimeFacade: @unchecked Sendable {
    nonisolated(unsafe) private var facade: nucleus.react.ReactRuntimeHostFacade

    init() throws {
        unsafe facade = nucleus.react.ReactRuntimeHostFacade()
        let result = unsafe facade.initializationResult()
        guard result.succeeded else {
            throw Self.operationError(result)
        }
    }

    @MainActor
    func evaluateJavaScriptSource(_ source: String) throws {
        let result = unsafe facade.evaluateJavaScriptSource(
            std.string(source),
            std.string("queued-device-event.js"))
        guard result.succeeded else {
            throw Self.operationError(result)
        }
    }

    nonisolated func emitDeviceEvent(name: String) -> Bool {
        unsafe facade.emitDeviceEvent(std.string(name), std.string("")).succeeded
    }

    private static func operationError(
        _ result: nucleus.react.RuntimeHostResult
    ) -> NSError {
        NSError(
            domain: "CrossThreadRuntimeFacade",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: String(result.error)])
    }
}

@MainActor
@Suite struct FabricRuntimeTests {
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

        guard
            let nativeSDKRoot = ProcessInfo.processInfo.environment[
                "NUCLEUS_NATIVE_SDK_ROOT"
            ], !nativeSDKRoot.isEmpty
        else {
            throw NSError(
                domain: "FabricRuntimeTests",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "NUCLEUS_NATIVE_SDK_ROOT is required to locate hermesc"
                ])
        }
        let hermesc = "\(nativeSDKRoot)/rn/lib/rn/hermes/bin/hermesc"
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

    @Test func animationModulesPublishTheirFabricRuntimeContracts() throws {
        let host = try RuntimeHost()
        try host.installFabric()
        try host.evaluateJavaScriptSource(
            """
            const worklets = global.__turboModuleProxy('WorkletsModule');
            const workletsInstalled = worklets.installTurboModule(false);
            const reanimated = global.__turboModuleProxy('ReanimatedModule');
            globalThis.nucleusAnimationModules = JSON.stringify([
              workletsInstalled,
              typeof globalThis.__workletsModuleProxy,
              typeof reanimated.installTurboModule,
            ]);
            """,
            sourceUrl: "animation-modules.js")

        #expect(
            try host.evaluateJavaScriptForString(
                "globalThis.nucleusAnimationModules",
                sourceUrl: "animation-modules-result.js")
                == #"[true,"object","function"]"#)
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

    @Test func animationFramesCoalesceCancelAndUseThePresentationTimestamp() throws {
        let requests = Mutex(0)
        let cancellations = Mutex(0)
        let host = try RuntimeHost()
        try host.setAnimationFrameScheduler(
            request: {
                requests.withLock { $0 += 1 }
                return true
            },
            cancel: { cancellations.withLock { $0 += 1 } }
        )
        try host.evaluateJavaScriptSource(
            """
            globalThis.animationFrames = [];
            const cancelledFrame = requestAnimationFrame(function (timestamp) {
              globalThis.animationFrames.push(['cancelled', timestamp]);
            });
            requestAnimationFrame(function (timestamp) {
              globalThis.animationFrames.push(['delivered', timestamp]);
            });
            cancelAnimationFrame(cancelledFrame);
            """,
            sourceUrl: "animation-frame-coalescing.js")

        #expect(requests.withLock { $0 } == 1)
        #expect(cancellations.withLock { $0 } == 0)
        try host.deliverAnimationFrame(timestampNanoseconds: 12_500_000)

        #expect(
            try host.evaluateJavaScriptForString(
                "JSON.stringify(globalThis.animationFrames)",
                sourceUrl: "animation-frame-result.js")
                == #"[["delivered",12.5]]"#)
        #expect(requests.withLock { $0 } == 1)
        #expect(cancellations.withLock { $0 } == 0)
    }

    @Test func animationFramesRearmAndClampRegressingTimestamps() throws {
        let requests = Mutex(0)
        let host = try RuntimeHost()
        try host.setAnimationFrameScheduler(
            request: {
                requests.withLock { $0 += 1 }
                return true
            },
            cancel: {})
        try host.evaluateJavaScriptSource(
            """
            globalThis.animationFrames = [];
            requestAnimationFrame(function first(timestamp) {
              globalThis.animationFrames.push(timestamp);
              requestAnimationFrame(function second(nextTimestamp) {
                globalThis.animationFrames.push(nextTimestamp);
              });
            });
            """,
            sourceUrl: "animation-frame-rearm.js")

        try host.deliverAnimationFrame(timestampNanoseconds: 20_000_000)
        #expect(requests.withLock { $0 } == 2)
        try host.deliverAnimationFrame(timestampNanoseconds: 10_000_000)

        #expect(
            try host.evaluateJavaScriptForString(
                "JSON.stringify(globalThis.animationFrames)",
                sourceUrl: "animation-frame-monotonic-result.js")
                == "[20,20]")
        #expect(requests.withLock { $0 } == 2)
    }

    @Test func cancellingTheLastAnimationFrameRetiresPlatformDemand() throws {
        let requests = Mutex(0)
        let cancellations = Mutex(0)
        let host = try RuntimeHost()
        try host.setAnimationFrameScheduler(
            request: {
                requests.withLock { $0 += 1 }
                return true
            },
            cancel: { cancellations.withLock { $0 += 1 } }
        )
        try host.evaluateJavaScriptSource(
            """
            const frame = requestAnimationFrame(function () {});
            cancelAnimationFrame(frame);
            """,
            sourceUrl: "animation-frame-cancel.js")

        #expect(requests.withLock { $0 } == 1)
        #expect(cancellations.withLock { $0 } == 1)
    }

    @Test func runtimeTeardownCancelsOutstandingAnimationFrame() throws {
        let cancellations = Mutex(0)
        var host: RuntimeHost? = try RuntimeHost()
        try host?.setAnimationFrameScheduler(
            request: { true },
            cancel: { cancellations.withLock { $0 += 1 } }
        )
        try host?.evaluateJavaScriptSource(
            "requestAnimationFrame(function () {});",
            sourceUrl: "animation-frame-teardown.js")

        host = nil
        #expect(cancellations.withLock { $0 } == 1)
    }

    @Test func presentationFrameSourceDrivesAndCancelsRuntimeDemand() throws {
        let source = TestPresentationFrameSource()
        let host = try RuntimeHost()
        try host.setPresentationFrameSource(source)
        try host.evaluateJavaScriptSource(
            """
            globalThis.presentationFrames = [];
            requestAnimationFrame(function (timestamp) {
              globalThis.presentationFrames.push(timestamp);
            });
            """,
            sourceUrl: "presentation-frame-source.js")

        #expect(source.requestCount == 1)
        source.deliver(33_250_000)
        #expect(
            try host.evaluateJavaScriptForString(
                "JSON.stringify(globalThis.presentationFrames)",
                sourceUrl: "presentation-frame-source-result.js")
                == "[33.25]")

        try host.evaluateJavaScriptSource(
            """
            globalThis.pendingPresentationFrame = requestAnimationFrame(
              function () {}
            );
            """,
            sourceUrl: "presentation-frame-source-cancel.js")
        #expect(source.requestCount == 2)
        try host.evaluateJavaScriptSource(
            "cancelAnimationFrame(globalThis.pendingPresentationFrame);",
            sourceUrl: "presentation-frame-source-cancel-result.js")
        #expect(source.cancellationCount == 1)
    }

    @Test func rejectedPresentationRequestCanBeReplaced() throws {
        let rejected = TestPresentationFrameSource()
        rejected.rejectsRequests = true
        let host = try RuntimeHost()
        try host.setPresentationFrameSource(rejected)
        try host.evaluateJavaScriptSource(
            "requestAnimationFrame(function () {});",
            sourceUrl: "rejected-presentation-frame.js")
        #expect(rejected.requestCount == 1)

        let replacement = TestPresentationFrameSource()
        try host.setPresentationFrameSource(replacement)
        #expect(replacement.requestCount == 1)
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

    @Test func deviceEventsUseTheInstalledReactNativeEmitterAndCacheIt() async throws {
        let hbc = try Self.makeTinyBytecode(
            source:
                """
                global.RCTDeviceEventEmitter = {
                  emit: function (name, payload) {
                    global.__turboModuleProxy('NucleusHostCommand')
                      .invoke(name, JSON.stringify(payload));
                  }
                };
                """)
        let deliveries = Mutex<[(String, String)]>([])
        let host = try RuntimeHost()
        try host.setCommandHandler { name, payload in
            deliveries.withLock { $0.append((name, payload)) }
        }
        try host.evaluateBytecode(at: hbc)

        try host.emitDeviceEvent(
            name: "first",
            payloadJson: #"{"sequence":1}"#)
        try host.evaluateJavaScriptSource(
            """
            global.RCTDeviceEventEmitter.emit = function (name, payload) {
              global.__turboModuleProxy('NucleusHostCommand')
                .invoke('replacement-' + name, JSON.stringify(payload));
            };
            """,
            sourceUrl: "device-emitter-replacement.js")
        try host.emitDeviceEvent(
            name: "second",
            payloadJson: #"{"sequence":2}"#)
        _ = try host.drainPendingJSCalls()
        for _ in 0..<100 where deliveries.withLock({ $0.count }) != 2 {
            await Task.yield()
        }

        #expect(deliveries.withLock { $0.map(\.0) } == ["first", "second"])
        #expect(
            deliveries.withLock { $0.map(\.1) }
                == [#"{"sequence":1}"#, #"{"sequence":2}"#])
    }

    @Test func missingDeviceEmitterDropsWithoutFailingTheRuntime() throws {
        let hbc = try Self.makeTinyBytecode()
        let host = try RuntimeHost()
        try host.evaluateBytecode(at: hbc)
        try host.emitDeviceEvent(name: "unhandled")
        _ = try host.drainPendingJSCalls()
    }

    @Test func shutdownDiscardsAQueuedDeviceEvent() async throws {
        var host: CrossThreadRuntimeFacade? = try CrossThreadRuntimeFacade()
        try host?.evaluateJavaScriptSource(
            """
            global.RCTDeviceEventEmitter = { emit: function () {} };
            """)
        let accepted = await Task.detached { [host] in
            host?.emitDeviceEvent(name: "queued-before-shutdown") ?? false
        }.value
        #expect(accepted)

        host = nil
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
