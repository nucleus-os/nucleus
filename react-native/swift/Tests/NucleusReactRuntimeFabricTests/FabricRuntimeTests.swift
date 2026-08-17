import CxxStdlib
import Foundation
import NucleusAppHostProtocols
import NucleusReactRuntime
import NucleusReactRuntimeCxx
import NucleusReactRuntimeCxxBridge
import Synchronization
import Testing

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

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
            unsafe nucleus.react.NetworkTransport(
                .init { _, callbacks in
                    callbacks.didComplete(std.string("network unavailable"), false)
                    return nucleus.react.NetworkRequestToken()
                },
                .init { _ in nucleus.react.NetworkWebSocket() }
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
                // The Swift test runner blocks termination signals while it
                // coordinates child processes. Process propagates that mask
                // into this fixture, so SIGTERM can remain pending forever.
                // This process owns only disposable loopback test servers.
                _ = kill(process.processIdentifier, SIGKILL)
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
                    if self.path == "/stream":
                        chunks = [("stream-%02d\n" % index).encode() for index in range(64)]
                        self.send_response(200)
                        self.send_header("Content-Type", "text/plain")
                        self.send_header("Content-Length", str(sum(map(len, chunks))))
                        self.end_headers()
                        for chunk in chunks:
                            self.wfile.write(chunk)
                            self.wfile.flush()
                            time.sleep(0.002)
                        return
                    if self.path == "/truncated":
                        self.send_response(200)
                        self.send_header("Content-Length", "128")
                        self.end_headers()
                        self.wfile.write(b"truncated")
                        self.wfile.flush()
                        self.connection.shutdown(socket.SHUT_RDWR)
                        self.connection.close()
                        return
                    if self.path == "/binary":
                        body = b"binary-response"
                        self.send_response(200)
                        self.send_header("Content-Type", "application/octet-stream")
                        self.send_header("Content-Length", str(len(body)))
                        self.end_headers()
                        self.wfile.write(body)
                        return
                    self.send_response(404)
                    self.send_header("Content-Length", "0")
                    self.end_headers()

                def do_POST(self):
                    length = int(self.headers.get("Content-Length", "0"))
                    request_body = self.rfile.read(length)
                    body = self.headers.get("X-Nucleus", "missing").encode() + b":" + request_body
                    self.send_response(200)
                    self.send_header("Content-Type", "text/plain")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)

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

            def send_frame(stream, opcode, payload=b"", fin=True):
                header = bytes([(0x80 if fin else 0) | opcode])
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
                    path = request.decode("latin1").split("\r\n", 1)[0].split(" ")[1]
                    if path == "/reject":
                        self.request.sendall(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
                        return
                    headers = {}
                    for line in request.decode("latin1").split("\r\n")[1:]:
                        if ":" in line:
                            name, value = line.split(":", 1)
                            headers[name.lower()] = value.strip()
                    accept = base64.b64encode(hashlib.sha1((headers["sec-websocket-key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
                    self.request.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " + accept + "\r\n\r\n").encode())
                    if path == "/disconnect":
                        return
                    if path == "/malformed":
                        send_frame(self.request, 0, b"unexpected-continuation")
                        time.sleep(0.05)
                        return
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
                        if opcode == 2 and path == "/fragmented-binary":
                            midpoint = len(payload) // 2
                            send_frame(self.request, 2, payload[:midpoint], False)
                            send_frame(self.request, 0, payload[midpoint:])
                        elif opcode == 1 or opcode == 2:
                            send_frame(self.request, opcode, payload)
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

    @Test func portableNetworkingModulesUseProductionTransportsAndRetireCleanly() throws {
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
            networking.sendRequest(
              'GET',
              'http://127.0.0.1:\(fixture.httpPort)/stream',
              47,
              [],
              {},
              'text',
              true,
              5000,
              false
            );
            networking.sendRequest(
              'GET',
              'http://127.0.0.1:\(fixture.httpPort)/slow',
              49,
              [],
              {},
              'text',
              false,
              50,
              false
            );
            networking.sendRequest(
              'POST',
              'http://127.0.0.1:\(fixture.httpPort)/echo',
              51,
              [['X-Nucleus', 'header']],
              {string: 'text-body'},
              'text',
              false,
              5000,
              false
            );
            networking.sendRequest(
              'POST',
              'http://127.0.0.1:\(fixture.httpPort)/echo',
              53,
              [['X-Nucleus', 'header']],
              {base64: 'YmFzZTY0LWJvZHk='},
              'text',
              false,
              5000,
              false
            );
            networking.sendRequest(
              'GET',
              'http://127.0.0.1:\(fixture.httpPort)/truncated',
              55,
              [],
              {},
              'text',
              false,
              5000,
              false
            );
            webSocket.connect('ws://127.0.0.1:\(fixture.webSocketPort)', null, {}, 42);
            webSocket.connect('ws://127.0.0.1:\(fixture.webSocketPort)/reject', null, {}, 46);
            webSocket.connect('ws://127.0.0.1:\(fixture.webSocketPort)/malformed', null, {}, 48);
            webSocket.connect('ws://127.0.0.1:\(fixture.webSocketPort)/disconnect', null, {}, 50);
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
                      stream: globalThis.nucleusNetworkEvents.some(
                        event => event[0] === 'didCompleteNetworkResponse' && event[1][0] === 47),
                      timeout: globalThis.nucleusNetworkEvents.some(
                        event => event[0] === 'didCompleteNetworkResponse' &&
                          event[1][0] === 49 && event[1][2] === true),
                      textBody: globalThis.nucleusNetworkEvents.some(
                        event => event[0] === 'didCompleteNetworkResponse' && event[1][0] === 51),
                      base64Body: globalThis.nucleusNetworkEvents.some(
                        event => event[0] === 'didCompleteNetworkResponse' && event[1][0] === 53),
                      truncated: globalThis.nucleusNetworkEvents.some(
                        event => event[0] === 'didCompleteNetworkResponse' &&
                          event[1][0] === 55 && event[1][1].length > 0),
                      rejectedSocket: globalThis.nucleusNetworkEvents.some(
                        event => event[0] === 'websocketFailed' && event[1].id === 46),
                      malformedSocket: globalThis.nucleusNetworkEvents.some(
                        event => event[0] === 'websocketClosed' && event[1].id === 48),
                      disconnectedSocket: globalThis.nucleusNetworkEvents.some(
                        event => event[0] === 'websocketClosed' && event[1].id === 50),
                    })
                    """,
                    sourceUrl: "portable-networking-completion.js")
                == #"{"redirect":true,"socket":true,"tlsRejected":true,"stream":true,"timeout":true,"textBody":true,"base64Body":true,"truncated":true,"rejectedSocket":true,"malformedSocket":true,"disconnectedSocket":true}"#
            if complete { break }
            usleep(10_000)
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
        #expect(events.contains("stream-00"))
        #expect(events.contains("stream-63"))
        #expect(events.contains("header:text-body"))
        #expect(events.contains("header:base64-body"))
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

    @Test func productionNetworkTransportsCancelPendingWorkDuringRuntimeShutdown() throws {
        let fixture = try NetworkFixture()
        do {
            let host = try RuntimeHost()
            try host.evaluateJavaScriptSource(
                """
                globalThis.__rctDeviceEventEmitter = { emit() {} };
                global.__turboModuleProxy('Networking').sendRequest(
                  'GET',
                  'http://127.0.0.1:\(fixture.httpPort)/slow',
                  57,
                  [],
                  {},
                  'text',
                  false,
                  5000,
                  false
                );
                global.__turboModuleProxy('WebSocketModule').connect(
                  'ws://127.0.0.1:\(fixture.webSocketPort)', null, {}, 58);
                """,
                sourceUrl: "network-runtime-shutdown.js")
            _ = try host.drainPendingJSCalls()
        }
        usleep(50_000)
    }

    @Test func blobModulesIntegrateWithHTTPMultipartAndWebSockets() throws {
        let fixture = try NetworkFixture()
        let host = try RuntimeHost()
        try host.evaluateJavaScriptSource(
            """
            globalThis.nucleusBlobEvents = [];
            globalThis.nucleusBlobResults = {};

            const blob = global.__turboModuleProxy('BlobModule');
            const fileReader = global.__turboModuleProxy('FileReaderModule');
            const networking = global.__turboModuleProxy('Networking');
            const webSocket = global.__turboModuleProxy('WebSocketModule');
            const descriptor = {
              blobId: 'nucleus-blob-test',
              offset: 0,
              size: 9,
              type: 'text/plain',
            };

            blob.createFromParts([{type: 'string', data: 'blob-body'}], descriptor.blobId);
            globalThis.nucleusBlobResults.constants = blob.getConstants();
            fileReader.readAsText(
              {...descriptor, offset: 5, size: 4},
              'UTF-8'
            ).then(value => globalThis.nucleusBlobResults.slice = value);
            fileReader.readAsDataURL(descriptor).then(
              value => globalThis.nucleusBlobResults.dataURL = value
            );

            globalThis.__rctDeviceEventEmitter = {
              emit(name, payload) {
                globalThis.nucleusBlobEvents.push([name, payload]);
                if (name === 'didReceiveNetworkData' && payload[0] === 67) {
                  fileReader.readAsText(payload[1], 'utf8').then(
                    value => globalThis.nucleusBlobResults.httpBlob = value
                  );
                } else if (name === 'websocketOpen' && payload.id === 71) {
                  blob.addWebSocketHandler(71);
                  blob.sendOverSocket(descriptor, 71);
                } else if (name === 'websocketOpen' && payload.id === 73) {
                  webSocket.sendBinary('YmluYXJ5LXJhdw==', 73);
                } else if (name === 'websocketMessage' && payload.id === 71) {
                  globalThis.nucleusBlobResults.socketBlobType = payload.type;
                  fileReader.readAsText(
                    {...payload.data, type: 'text/plain'}, 'UTF-8'
                  ).then(value => {
                    globalThis.nucleusBlobResults.socketBlob = value;
                    blob.removeWebSocketHandler(71);
                    webSocket.close(1000, 'complete', 71);
                  });
                } else if (name === 'websocketMessage' && payload.id === 73) {
                  globalThis.nucleusBlobResults.socketBinaryType = payload.type;
                  globalThis.nucleusBlobResults.socketBinary = payload.data;
                  webSocket.close(1000, 'complete', 73);
                }
              },
            };

            networking.sendRequest(
              'POST',
              'http://127.0.0.1:\(fixture.httpPort)/echo',
              61,
              [['X-Nucleus', 'blob']],
              {blob: descriptor},
              'text',
              false,
              5000,
              false
            );
            networking.sendRequest(
              'POST',
              'http://127.0.0.1:\(fixture.httpPort)/echo',
              65,
              [],
              {formData: [
                {
                  string: 'field-value',
                  headers: {'Content-Disposition': 'form-data; name="field"'},
                },
                {
                  uri: 'blob://nucleus/nucleus-blob-test?offset=0&size=9',
                  headers: {
                    'Content-Disposition': 'form-data; name="file"; filename="blob.txt"',
                    'Content-Type': 'text/plain',
                  },
                },
              ]},
              'text',
              false,
              5000,
              false
            );
            networking.sendRequest(
              'GET',
              'http://127.0.0.1:\(fixture.httpPort)/binary',
              67,
              [],
              {},
              'blob',
              true,
              5000,
              false
            );
            webSocket.connect(
              'ws://127.0.0.1:\(fixture.webSocketPort)/fragmented-binary', null, {}, 71
            );
            webSocket.connect('ws://127.0.0.1:\(fixture.webSocketPort)', null, {}, 73);
            """,
            sourceUrl: "blob-integration.js")

        for _ in 0..<500 {
            _ = try host.drainPendingJSCalls()
            let complete =
                try host.evaluateJavaScriptForString(
                    """
                    String(
                      globalThis.nucleusBlobResults.slice === 'body' &&
                      globalThis.nucleusBlobResults.dataURL ===
                        'data:text/plain;base64,YmxvYi1ib2R5' &&
                      globalThis.nucleusBlobResults.httpBlob === 'binary-response' &&
                      globalThis.nucleusBlobResults.socketBlob === 'blob-body' &&
                      globalThis.nucleusBlobResults.socketBlobType === 'blob' &&
                      globalThis.nucleusBlobResults.socketBinary === 'YmluYXJ5LXJhdw==' &&
                      globalThis.nucleusBlobResults.socketBinaryType === 'binary' &&
                      globalThis.nucleusBlobEvents.some(
                        event => event[0] === 'didCompleteNetworkResponse' && event[1][0] === 61) &&
                      globalThis.nucleusBlobEvents.some(
                        event => event[0] === 'didCompleteNetworkResponse' && event[1][0] === 65) &&
                      globalThis.nucleusBlobEvents.some(
                        event => event[0] === 'didCompleteNetworkResponse' && event[1][0] === 67)
                    )
                    """,
                    sourceUrl: "blob-integration-completion.js") == "true"
            if complete { break }
            usleep(10_000)
        }

        let events = try host.evaluateJavaScriptForString(
            "JSON.stringify(globalThis.nucleusBlobEvents)",
            sourceUrl: "blob-integration-events.js")
        #expect(events.contains("blob:blob-body"))
        #expect(events.contains("field-value"))
        #expect(events.contains("blob-body"))
        #expect(events.contains(#"["didSendNetworkData",[61,9,9]]"#))
        #expect(events.contains(#"["didSendNetworkData",[65,"#))
        #expect(events.contains(#"["didReceiveNetworkDataProgress",[67,"#))
        #expect(
            try host.evaluateJavaScriptForString(
                """
                JSON.stringify({
                  constants: globalThis.nucleusBlobResults.constants,
                  slice: globalThis.nucleusBlobResults.slice,
                  dataURL: globalThis.nucleusBlobResults.dataURL,
                  httpBlob: globalThis.nucleusBlobResults.httpBlob,
                  socketBlob: globalThis.nucleusBlobResults.socketBlob,
                  socketBlobType: globalThis.nucleusBlobResults.socketBlobType,
                  socketBinary: globalThis.nucleusBlobResults.socketBinary,
                  socketBinaryType: globalThis.nucleusBlobResults.socketBinaryType,
                })
                """,
                sourceUrl: "blob-integration-results.js")
                == #"{"constants":{"BLOB_URI_SCHEME":"blob","BLOB_URI_HOST":"nucleus"},"slice":"body","dataURL":"data:text/plain;base64,YmxvYi1ib2R5","httpBlob":"binary-response","socketBlob":"blob-body","socketBlobType":"blob","socketBinary":"YmluYXJ5LXJhdw==","socketBinaryType":"binary"}"#
        )

        try host.evaluateJavaScriptSource(
            """
            global.__turboModuleProxy('BlobModule').release('nucleus-blob-test');
            global.__turboModuleProxy('FileReaderModule').readAsText({
              blobId: 'nucleus-blob-test',
              offset: 0,
              size: 9,
              type: 'text/plain',
            }, 'UTF-8').then(
              () => globalThis.nucleusBlobResults.released = false,
              () => globalThis.nucleusBlobResults.released = true
            );
            """,
            sourceUrl: "blob-release.js")
        for _ in 0..<20 {
            _ = try host.drainPendingJSCalls()
            usleep(1_000)
        }
        #expect(
            try host.evaluateJavaScriptForString(
                "String(globalThis.nucleusBlobResults.released)",
                sourceUrl: "blob-release-result.js") == "true")
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
