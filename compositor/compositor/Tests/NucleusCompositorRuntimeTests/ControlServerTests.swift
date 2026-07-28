import Foundation
import NucleusConfig
import NucleusIPC
import Testing
@testable import NucleusCompositorRuntime

// The control socket end to end: a real listener, a real client, a real unix
// socket. The protocol types round-trip in the IPC package's own tests; what is
// only checkable here is that the two halves actually talk.
@Suite @MainActor struct ControlServerTests {
    private final class Handler: ControlRequestHandler {
        var received: [ControlRequest] = []
        var answer: ControlResponse = .ok

        func handle(_ request: ControlRequest) -> ControlResponse {
            received.append(request)
            return answer
        }
    }

    private func withServer(
        _ body: @MainActor (ControlServer, ControlClient, Handler) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(
                path: "nucleus-control-\(UInt64.random(in: 0..<UInt64.max))")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "control.sock").path
        let handler = Handler()
        let built: ControlServer? = ControlServer(handler: handler, path: path)
        let server = try #require(built)
        try body(server, ControlClient(path: path), handler)
    }

    /// Drive one exchange. The client blocks on its reply, so the server has to
    /// be pumped from another thread.
    private func exchange(
        _ server: ControlServer,
        _ client: ControlClient,
        _ request: ControlRequest
    ) throws -> ControlResponse {
        let ready = DispatchSemaphore(value: 0)
        let box = ResponseBox()
        DispatchQueue.global().async {
            ready.signal()
            box.store(try? client.send(request))
        }
        ready.wait()
        // Serve until the request lands; the connect may not have completed by
        // the time the first poll runs. Bounded, so a regression fails the
        // test instead of hanging the suite.
        for _ in 0..<500 {
            if server.process() { break }
            usleep(1000)
        }
        return try #require(box.wait())
    }

    private final class ResponseBox: @unchecked Sendable {
        private let lock = NSLock()
        private let done = DispatchSemaphore(value: 0)
        private var value: ControlResponse?

        func store(_ response: ControlResponse?) {
            lock.lock()
            value = response
            lock.unlock()
            done.signal()
        }

        func wait() -> ControlResponse? {
            _ = done.wait(timeout: .now() + 5)
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    // MARK: binding

    @Test func theSocketIsBoundAtTheRequestedPath() throws {
        try withServer { server, _, _ in
            #expect(FileManager.default.fileExists(atPath: server.socketPath))
        }
    }

    @Test func theSocketIsOwnerOnly() throws {
        // It performs privileged session actions, and XDG_RUNTIME_DIR is
        // per-user but not necessarily per-session.
        try withServer { server, _, _ in
            let attributes = try FileManager.default
                .attributesOfItem(atPath: server.socketPath)
            let permissions = attributes[.posixPermissions] as? NSNumber
            #expect(permissions?.int16Value == 0o600)
        }
    }

    @Test func aStaleSocketFromACrashedRunIsReplaced() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "nucleus-stale-\(UInt64.random(in: 0..<UInt64.max))")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "control.sock").path
        // A leftover file would make bind fail with EADDRINUSE forever, so a
        // compositor that crashed could never restart.
        try Data().write(to: URL(filePath: path))
        #expect(ControlServer(handler: Handler(), path: path) != nil)
    }

    @Test func anUnbindablePathYieldsNoServer() {
        #expect(ControlServer(
            handler: Handler(),
            path: "/nonexistent-nucleus-tree/control.sock") == nil)
    }

    @Test func teardownRemovesTheSocket() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "nucleus-teardown-\(UInt64.random(in: 0..<UInt64.max))")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appending(path: "control.sock").path
        do {
            let server = ControlServer(handler: Handler(), path: path)
            #expect(server != nil)
            #expect(FileManager.default.fileExists(atPath: path))
        }
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    // MARK: exchanges

    @Test func aRequestReachesTheHandlerAndItsAnswerReachesTheClient() throws {
        try withServer { server, client, handler in
            handler.answer = .version("nucleus 1")
            let response = try exchange(server, client, .version)
            #expect(handler.received == [.version])
            #expect(response == .version("nucleus 1"))
        }
    }

    @Test func anActionRequestCarriesItsPayloadIntact() throws {
        try withServer { server, client, handler in
            let response = try exchange(
                server, client, .action(.activateWorkspace(4)))
            #expect(handler.received == [.action(.activateWorkspace(4))])
            #expect(response == .ok)
        }
    }

    @Test func aLargeResponseSurvivesTheFraming() throws {
        // The default bind table is far larger than one read chunk; newline
        // framing has to hold across reads.
        try withServer { server, client, handler in
            handler.answer = .binds(DefaultBinds.table)
            let response = try exchange(server, client, .binds)
            guard case .binds(let binds) = response else {
                Issue.record("expected binds, got \(response)")
                return
            }
            #expect(binds == DefaultBinds.table)
        }
    }

    @Test func aConfigurationResponseSurvivesTheRoundTrip() throws {
        try withServer { server, client, handler in
            handler.answer = .configuration(.defaults)
            let response = try exchange(server, client, .configuration)
            #expect(response == .configuration(.defaults))
        }
    }

    @Test func anErrorResponseIsDeliveredRatherThanDropped() throws {
        try withServer { server, client, handler in
            handler.answer = .error("no focused window")
            let response = try exchange(
                server, client, .closeWindowRequest)
            #expect(response == .error("no focused window"))
        }
    }

    // MARK: malformed input

    @Test func garbageIsAnsweredWithAnErrorAndDoesNotReachTheHandler() throws {
        try withServer { server, _, handler in
            let reply = try sendRaw(
                server, "this is not json\n")
            #expect(handler.received.isEmpty)
            #expect(reply.contains("error"))
        }
    }

    @Test func anUnterminatedRequestIsIgnoredWithoutBlocking() throws {
        // No newline means no request. The read timeout is what keeps this from
        // holding the compositor's main actor.
        try withServer { server, _, handler in
            _ = try? sendRaw(server, "{\"request\":\"version\"", expectReply: false)
            #expect(handler.received.isEmpty)
        }
    }

    /// Write raw bytes to the socket and read whatever comes back.
    private func sendRaw(
        _ server: ControlServer,
        _ text: String,
        expectReply: Bool = true
    ) throws -> String {
        let box = TextBox()
        let ready = DispatchSemaphore(value: 0)
        let path = server.socketPath
        DispatchQueue.global().async {
            ready.signal()
            box.store(rawExchange(path: path, text: text))
        }
        ready.wait()
        for _ in 0..<500 {
            if server.process() { break }
            usleep(1000)
        }
        guard expectReply else { return "" }
        return box.wait() ?? ""
    }

    private final class TextBox: @unchecked Sendable {
        private let lock = NSLock()
        private let done = DispatchSemaphore(value: 0)
        private var value: String?

        func store(_ text: String?) {
            lock.lock(); value = text; lock.unlock(); done.signal()
        }

        func wait() -> String? {
            _ = done.wait(timeout: .now() + 5)
            lock.lock(); defer { lock.unlock() }; return value
        }
    }
}

private extension ControlRequest {
    static var closeWindowRequest: ControlRequest { .action(.closeWindow) }
}

/// A minimal raw client, so malformed input can be sent that the typed client
/// would refuse to produce.
private func rawExchange(path: String, text: String) -> String? {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: address.sun_path) - 1
    let pathBytes = Array(path.utf8)
    guard pathBytes.count <= capacity else { return nil }
    let descriptor = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
    guard descriptor >= 0 else { return nil }
    defer { close(descriptor) }
    withUnsafeMutablePointer(to: &address.sun_path) {
        unsafe $0.withMemoryRebound(to: UInt8.self, capacity: capacity + 1) {
            destination in
            for index in pathBytes.indices {
                unsafe destination[index] = pathBytes[index]
            }
            unsafe destination[pathBytes.count] = 0
        }
    }
    let connected = withUnsafePointer(to: &address) {
        unsafe $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            unsafe connect(
                descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard connected == 0 else { return nil }
    // The server may legitimately answer nothing (an unterminated request);
    // without this the reader would block for the life of the process.
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    _ = withUnsafePointer(to: &timeout) {
        unsafe setsockopt(
            descriptor, SOL_SOCKET, SO_RCVTIMEO, $0,
            socklen_t(MemoryLayout<timeval>.size))
    }
    let outgoing = Array(text.utf8)
    _ = outgoing.withUnsafeBytes { buffer in
        unsafe write(descriptor, buffer.baseAddress, buffer.count)
    }
    var incoming = [UInt8](repeating: 0, count: 4096)
    let count = incoming.withUnsafeMutableBytes { buffer in
        unsafe read(descriptor, buffer.baseAddress, buffer.count)
    }
    guard count > 0 else { return "" }
    return String(decoding: incoming[0..<count], as: UTF8.self)
}
