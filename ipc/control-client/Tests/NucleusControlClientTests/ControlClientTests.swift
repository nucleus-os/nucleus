import NucleusControlClient
import Testing

@Suite struct ControlSocketTests {
    @Test func anExplicitOverrideWins() {
        let path = ControlSocket.defaultPath(environment: [
            "NUCLEUS_CONTROL_SOCKET": "/run/custom.sock",
            "XDG_RUNTIME_DIR": "/run/user/1000",
        ])
        #expect(path == "/run/custom.sock")
    }

    @Test func displayNameDisambiguatesConcurrentCompositors() {
        let first = ControlSocket.defaultPath(environment: [
            "XDG_RUNTIME_DIR": "/run/user/1000",
            "WAYLAND_DISPLAY": "wayland-1",
        ])
        let second = ControlSocket.defaultPath(environment: [
            "XDG_RUNTIME_DIR": "/run/user/1000",
            "WAYLAND_DISPLAY": "wayland-2",
        ])
        #expect(first == "/run/user/1000/nucleus/wayland-1/control.sock")
        #expect(first != second)
    }

    @Test func absentDisplayUsesConventionalName() {
        #expect(ControlSocket.defaultPath(environment: [
            "XDG_RUNTIME_DIR": "/run/user/1000",
        ]) == "/run/user/1000/nucleus/wayland-0/control.sock")
    }

    @Test func noRuntimeDirectoryYieldsNoPath() {
        #expect(ControlSocket.defaultPath(environment: [:]) == nil)
        #expect(ControlSocket.defaultPath(
            environment: ["XDG_RUNTIME_DIR": ""]) == nil)
    }

    @Test func noResolvablePathFailsBeforeConnecting() {
        #expect(throws: ControlClientError.noSocketPath) {
            try ControlClient(environment: [:])
        }
    }

    @Test func absentSocketReportsItsPath() {
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

    @Test func overlongSocketPathIsRejected() {
        let long = "/tmp/" + String(repeating: "n", count: 200) + ".sock"
        let client = ControlClient(path: long)
        #expect(throws: ControlClientError.socketPathTooLong(long)) {
            try client.send(.version)
        }
    }
}
