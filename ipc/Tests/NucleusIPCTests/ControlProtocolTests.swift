import FoundationEssentials
import NucleusConfig
import Testing
@testable import NucleusIPC

@Suite struct ControlProtocolTests {
    private func roundTrip(_ request: ControlRequest) throws -> ControlRequest {
        let data = try ControlCoding.encoder().encode(request)
        return try ControlCoding.decoder().decode(
            ControlRequest.self, from: data)
    }

    private func roundTrip(
        _ response: ControlResponse
    ) throws -> ControlResponse {
        let data = try ControlCoding.encoder().encode(response)
        return try ControlCoding.decoder().decode(
            ControlResponse.self, from: data)
    }

    // MARK: requests

    @Test func everyRequestRoundTrips() throws {
        let requests: [ControlRequest] = [
            .version, .configuration, .reloadConfiguration, .outputs, .binds,
            .action(.closeWindow),
            .action(.activateWorkspace(3)),
            .action(.tile(.bottomRight)),
            .action(.launch(appIDs: ["kitty.desktop"], command: ["kitty"])),
        ]
        for request in requests {
            #expect(try roundTrip(request) == request, "\(request)")
        }
    }

    @Test func anUnknownRequestIsRejectedByName() throws {
        let data = Data(#"{"request":"self-destruct"}"#.utf8)
        #expect(throws: (any Error).self) {
            try ControlCoding.decoder().decode(ControlRequest.self, from: data)
        }
    }

    @Test func actionRequestsCarryTheSharedBindVocabulary() throws {
        // The point of reusing BindAction: a request and a keybinding describe
        // the same operation with the same type.
        let request = ControlRequest.action(.moveWindowToWorkspace(7))
        guard case .action(let action) = try roundTrip(request) else {
            Issue.record("expected an action request")
            return
        }
        #expect(action == .moveWindowToWorkspace(7))
    }

    // MARK: responses

    @Test func everyResponseRoundTrips() throws {
        let responses: [ControlResponse] = [
            .ok,
            .version("nucleus 0.1"),
            .configuration(.defaults),
            .binds(DefaultBinds.table),
            .outputs([ControlOutput(
                name: "DP-1", width: 2560, height: 1440,
                refreshMillihertz: 143_998, scale: 1.5,
                x: 0, y: 0, enabled: true)]),
            .error("no focused window"),
        ]
        for response in responses {
            #expect(try roundTrip(response) == response, "\(response)")
        }
    }

    @Test func refreshRateSurvivesAsMillihertz() throws {
        // 59.94 Hz is 59940 mHz; rounding to integer hertz would lose it, and
        // the whole reason the field is millihertz is to keep it.
        let output = ControlOutput(
            name: "HDMI-A-1", width: 1920, height: 1080,
            refreshMillihertz: 59_940, scale: 1, x: 0, y: 0, enabled: true)
        guard case .outputs(let decoded) = try roundTrip(.outputs([output]))
        else {
            Issue.record("expected outputs")
            return
        }
        #expect(decoded.first?.refreshMillihertz == 59_940)
    }

    @Test func aConfigurationResponseUsesTheFileSpelling() throws {
        // Keys match config.json so a response can be pasted back into it.
        let data = try ControlCoding.encoder().encode(
            ControlResponse.configuration(.defaults))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"config_version\""))
        #expect(text.contains("\"natural_scroll\""))
        #expect(!text.contains("\"naturalScroll\""))
    }

    // MARK: framing

    @Test func aFramedMessageIsOneLineTerminatedByNewline() throws {
        let line = try ControlCoding.line(ControlRequest.version)
        let bytes = Array(line)
        #expect(bytes.last == UInt8(ascii: "\n"))
        // Exactly one newline: the framing depends on it.
        #expect(bytes.filter { $0 == UInt8(ascii: "\n") }.count == 1)
    }

    @Test func framedBindsStayOnOneLineDespiteTheirSize() throws {
        // The default table is large; if the encoder ever pretty-printed, the
        // newline framing would silently break.
        let line = try ControlCoding.line(
            ControlResponse.binds(DefaultBinds.table))
        #expect(Array(line).filter { $0 == UInt8(ascii: "\n") }.count == 1)
    }
}

@Suite struct ControlSocketTests {
    @Test func anExplicitOverrideWins() {
        let path = ControlSocket.defaultPath(environment: [
            "NUCLEUS_SOCKET": "/run/custom.sock",
            "XDG_RUNTIME_DIR": "/run/user/1000",
        ])
        #expect(path == "/run/custom.sock")
    }

    @Test func theDisplayNameDisambiguatesConcurrentCompositors() {
        // Two compositors in one login session must not share a socket, which
        // is exactly what a nested or test compositor creates.
        let first = ControlSocket.defaultPath(environment: [
            "XDG_RUNTIME_DIR": "/run/user/1000",
            "WAYLAND_DISPLAY": "wayland-1",
        ])
        let second = ControlSocket.defaultPath(environment: [
            "XDG_RUNTIME_DIR": "/run/user/1000",
            "WAYLAND_DISPLAY": "wayland-2",
        ])
        #expect(first == "/run/user/1000/nucleus-wayland-1.sock")
        #expect(first != second)
    }

    @Test func anAbsentDisplayFallsBackToTheConventionalName() {
        #expect(ControlSocket.defaultPath(environment: [
            "XDG_RUNTIME_DIR": "/run/user/1000",
        ]) == "/run/user/1000/nucleus-wayland-0.sock")
    }

    @Test func noRuntimeDirectoryYieldsNoPath() {
        #expect(ControlSocket.defaultPath(environment: [:]) == nil)
        #expect(ControlSocket.defaultPath(
            environment: ["XDG_RUNTIME_DIR": ""]) == nil)
    }

    @Test func aClientWithNoResolvablePathFailsBeforeConnecting() {
        #expect(throws: ControlClientError.noSocketPath) {
            try ControlClient(environment: [:])
        }
    }

    @Test func connectingToAnAbsentSocketReportsThePath() {
        let client = ControlClient(path: "/nonexistent/nucleus-test.sock")
        do {
            _ = try client.send(.version)
            Issue.record("expected a connection failure")
        } catch {
            guard case .cannotConnect(let path, _) = error else {
                Issue.record("expected cannotConnect, got \(error)")
                return
            }
            #expect(path == "/nonexistent/nucleus-test.sock")
        }
    }

    @Test func anOverlongSocketPathIsRejectedRatherThanTruncated() {
        // sun_path is a fixed 108-byte array; silently truncating would
        // connect to the wrong socket.
        let long = "/tmp/" + String(repeating: "n", count: 200) + ".sock"
        let client = ControlClient(path: long)
        #expect(throws: ControlClientError.socketPathTooLong(long)) {
            try client.send(.version)
        }
    }
}
