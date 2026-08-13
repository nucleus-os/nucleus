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
        unsafe facade = nucleus.react.ReactRuntimeHostFacade(
            nucleus.react.NetworkTransport(
                .init { _, callbacks in
                    unsafe callbacks.didComplete(std.string("network unavailable"), false)
                    return unsafe nucleus.react.NetworkRequestToken()
                },
                .init { _ in unsafe nucleus.react.NetworkWebSocket() }
            ))
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
            userInfo: [NSLocalizedDescriptionKey: runtimeHostErrorMessage(result)])
    }
}

@MainActor
@Suite(.serialized) struct FabricRuntimeTests {
    private final class NetworkFixture {
        let httpPort: Int
        let httpsPort: Int
        let webSocketPort: Int

        private let process: Process
        private let directory: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "nucleus-network-fixture-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let script = directory.appendingPathComponent("fixture.py")
            try Self.script.write(to: script, atomically: true, encoding: .utf8)

            let output = Pipe()
            process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = ["-u", script.path]
            process.standardOutput = output
            process.standardError = FileHandle.standardError
            try process.run()

            var line = Data()
            while true {
                guard let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty
                else {
                    throw NSError(
                        domain: "NetworkFixture", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "fixture exited before startup"])
                }
                if byte[0] == 10 { break }
                line.append(byte)
            }
            let ports = String(decoding: line, as: UTF8.self).split(separator: " ")
            guard ports.count == 3, let httpPort = Int(ports[0]),
                let httpsPort = Int(ports[1]), let webSocketPort = Int(ports[2])
            else {
                throw NSError(
                    domain: "NetworkFixture", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "fixture returned invalid ports"])
            }
            self.httpPort = httpPort
            self.httpsPort = httpsPort
            self.webSocketPort = webSocketPort
        }

        deinit {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            try? FileManager.default.removeItem(at: directory)
        }

        private static let script = #"""
            import base64
            import hashlib
            import http.server
            import socket
            import socketserver
            import ssl
            import struct
            import subprocess
            import tempfile
            import threading
            import time

            class HTTPHandler(http.server.BaseHTTPRequestHandler):
                protocol_version = "HTTP/1.1"

                def log_message(self, *_):
                    pass

                def do_GET(self):
                    if self.path == "/redirect":
                        self.send_response(302)
                        self.send_header("Location", "/cookie")
                        self.send_header("Set-Cookie", "nucleus=session")
                        self.send_header("Content-Length", "0")
                        self.end_headers()
                        return
                    if self.path == "/cookie":
                        body = b"redirected-with-cookie" if "nucleus=session" in self.headers.get("Cookie", "") else b"missing-cookie"
                        self.send_response(200)
                        self.send_header("Content-Type", "text/plain")
                        self.send_header("Content-Length", str(len(body)))
                        self.end_headers()
                        self.wfile.write(body)
                        return
                    if self.path == "/slow":
                        time.sleep(2)
                        body = b"too-late"
                        self.send_response(200)
                        self.send_header("Content-Length", str(len(body)))
                        self.end_headers()
                        self.wfile.write(body)
                        return
                    self.send_response(404)
                    self.send_header("Content-Length", "0")
                    self.end_headers()

            class ThreadingHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
                daemon_threads = True

            def read_exact(stream, count):
                data = b""
                while len(data) < count:
                    chunk = stream.recv(count - len(data))
                    if not chunk:
                        raise EOFError()
                    data += chunk
                return data

            def send_frame(stream, opcode, payload=b""):
                header = bytes([0x80 | opcode])
                if len(payload) < 126:
                    header += bytes([len(payload)])
                elif len(payload) < 65536:
                    header += bytes([126]) + struct.pack("!H", len(payload))
                else:
                    header += bytes([127]) + struct.pack("!Q", len(payload))
                stream.sendall(header + payload)

            class WebSocketHandler(socketserver.BaseRequestHandler):
                def handle(self):
                    request = b""
                    while b"\r\n\r\n" not in request:
                        request += self.request.recv(4096)
                    headers = {}
                    for line in request.decode("latin1").split("\r\n")[1:]:
                        if ":" in line:
                            name, value = line.split(":", 1)
                            headers[name.lower()] = value.strip()
                    accept = base64.b64encode(hashlib.sha1((headers["sec-websocket-key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
                    self.request.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + "\r\n\r\n").encode())
                    while True:
                        first, second = read_exact(self.request, 2)
                        opcode = first & 0x0f
                        length = second & 0x7f
                        if length == 126:
                            length = struct.unpack("!H", read_exact(self.request, 2))[0]
                        elif length == 127:
                            length = struct.unpack("!Q", read_exact(self.request, 8))[0]
                        mask = read_exact(self.request, 4) if second & 0x80 else b""
                        payload = read_exact(self.request, length)
                        if mask:
                            payload = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
                        if opcode == 1:
                            send_frame(self.request, 1, payload)
                        elif opcode == 8:
                            send_frame(self.request, 8, payload)
                            return
                        elif opcode == 9:
                            send_frame(self.request, 10, payload)

            class ThreadingTCPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
                allow_reuse_address = True
                daemon_threads = True

            httpd = ThreadingHTTPServer(("127.0.0.1", 0), HTTPHandler)
            certificate_directory = tempfile.mkdtemp(prefix="nucleus-network-cert-")
            certificate = certificate_directory + "/certificate.pem"
            private_key = certificate_directory + "/private-key.pem"
            subprocess.run([
                "openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
                "-subj", "/CN=localhost", "-days", "1",
                "-keyout", private_key, "-out", certificate,
            ], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            httpsd = ThreadingHTTPServer(("127.0.0.1", 0), HTTPHandler)
            tls_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            tls_context.load_cert_chain(certificate, private_key)
            httpsd.socket = tls_context.wrap_socket(httpsd.socket, server_side=True)
            websocketd = ThreadingTCPServer(("127.0.0.1", 0), WebSocketHandler)
            threading.Thread(target=httpd.serve_forever, daemon=True).start()
            threading.Thread(target=httpsd.serve_forever, daemon=True).start()
            threading.Thread(target=websocketd.serve_forever, daemon=True).start()
            print(httpd.server_port, httpsd.server_port, websocketd.server_address[1], flush=True)
            threading.Event().wait()
            """#
    }

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

    @Test func portableNetworkingModulesUseProductionTransportsAndRetireCleanly() async throws {
        let fixture = try NetworkFixture()
        let host = try RuntimeHost()
        try host.evaluateJavaScriptSource(
            """
            globalThis.nucleusNetworkEvents = [];
            globalThis.__rctDeviceEventEmitter = {
              emit(name, payload) {
                globalThis.nucleusNetworkEvents.push([name, payload]);
                if (name === 'websocketOpen') {
                  global.__turboModuleProxy('WebSocketModule').send('echo-me', payload.id);
                } else if (name === 'websocketMessage') {
                  global.__turboModuleProxy('WebSocketModule').ping(payload.id);
                  global.__turboModuleProxy('WebSocketModule').close(1000, 'complete', payload.id);
                } else if (name === 'websocketClosed' && payload.id === 42) {
                  global.__turboModuleProxy('WebSocketModule').connect(
                    'ws://127.0.0.1:\(fixture.webSocketPort)', null, {}, 44);
                }
              },
            };

            const networking = global.__turboModuleProxy('Networking');
            const webSocket = global.__turboModuleProxy('WebSocketModule');
            globalThis.nucleusNetworkContracts = JSON.stringify([
              typeof networking.sendRequest,
              typeof networking.abortRequest,
              typeof webSocket.connect,
              typeof webSocket.close,
            ]);

            networking.sendRequest(
              'GET',
              'http://127.0.0.1:\(fixture.httpPort)/redirect',
              41,
              [],
              {},
              'text',
              false,
              0,
              false
            );
            networking.sendRequest(
              'GET',
              'http://127.0.0.1:\(fixture.httpPort)/slow',
              43,
              [],
              {},
              'text',
              false,
              5000,
              false
            );
            networking.abortRequest(43);
            networking.sendRequest(
              'GET',
              'https://localhost:\(fixture.httpsPort)/cookie',
              45,
              [],
              {},
              'text',
              false,
              5000,
              false
            );
            webSocket.connect('ws://127.0.0.1:\(fixture.webSocketPort)', null, {}, 42);
            """,
            sourceUrl: "portable-networking-modules.js")

        for _ in 0..<500 {
            _ = try host.drainPendingJSCalls()
            let complete =
                try host.evaluateJavaScriptForString(
                    """
                    JSON.stringify({
                      redirect: globalThis.nucleusNetworkEvents.some(
                        event => event[0] === 'didCompleteNetworkResponse' && event[1][0] === 41),
                      socket: globalThis.nucleusNetworkEvents.some(
                        event => event[0] === 'websocketClosed' && event[1].id === 44),
                      tlsRejected: globalThis.nucleusNetworkEvents.some(
                        event => event[0] === 'didCompleteNetworkResponse' &&
                          event[1][0] === 45 && event[1][1].length > 0),
                    })
                    """,
                    sourceUrl: "portable-networking-completion.js")
                == #"{"redirect":true,"socket":true,"tlsRejected":true}"#
            if complete { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(
            try host.evaluateJavaScriptForString(
                "globalThis.nucleusNetworkContracts",
                sourceUrl: "portable-networking-contracts.js")
                == #"["function","function","function","function"]"#)
        let events = try host.evaluateJavaScriptForString(
            "JSON.stringify(globalThis.nucleusNetworkEvents)",
            sourceUrl: "portable-networking-events.js")
        #expect(events.contains("redirected-with-cookie"))
        #expect(events.contains("echo-me"))
        #expect(events.contains("didCompleteNetworkResponse"))
        #expect(events.contains("websocketClosed"))
        #expect(
            try host.evaluateJavaScriptForString(
                """
                String(globalThis.nucleusNetworkEvents.some(
                  event => event[0] === 'didReceiveNetworkData' && event[1][0] === 43))
                """,
                sourceUrl: "portable-networking-cancellation.js")
                == "false")
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
