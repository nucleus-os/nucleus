import Glibc
import Testing

@testable import NucleusCompositorWaylandRuntime

// The gating decision, and the listener that produces the identities it acts
// on. This is the one place in the compositor where getting a boolean backwards
// silently grants a confined application the run of the session, so the table
// is asserted explicitly rather than by spot check.
@Suite struct PrivilegedGlobalTests {
    private let sandboxed = SecurityContextIdentity(
        sandboxEngine: "org.flatpak",
        appID: "com.example.App",
        instanceID: "1")

    @Test func anUnconfinedClientSeesEverythingThisRuleGoverns() {
        // Confinement restricts clients that opted into it; it does not
        // restrict the session's own components, which are exactly the things
        // that need these globals. Xwayland's protocol is scoped to a single
        // client instead, which RouterHost decides before consulting this.
        for interface in PrivilegedGlobals.interfaceNames {
            #expect(
                PrivilegedGlobals.allows(
                    interface: interface, identity: nil), "\(interface)")
        }
    }

    @Test func xwaylandsProtocolIsAlsoDeniedToSandboxedClients() {
        // RouterHost restricts it to the Xwayland client; listing it here as
        // well means a sandboxed client is denied it by both rules rather than
        // relying on either one alone.
        #expect(PrivilegedGlobals.interfaceNames.contains("xwayland_shell_v1"))
        #expect(
            !PrivilegedGlobals.allows(
                interface: "xwayland_shell_v1", identity: sandboxed))
    }

    @Test func aSandboxedClientIsDeniedEveryPrivilegedGlobal() {
        for interface in PrivilegedGlobals.interfaceNames {
            #expect(
                !PrivilegedGlobals.allows(
                    interface: interface, identity: sandboxed), "\(interface)")
        }
    }

    @Test func aSandboxedClientStillSeesOrdinaryGlobals() {
        // Confinement must not break the client: it still needs to make
        // surfaces, take input, and present.
        for interface in [
            "wl_compositor", "wl_subcompositor", "wl_seat", "wl_output",
            "wl_shm", "xdg_wm_base", "zwp_linux_dmabuf_v1", "wp_presentation",
            "wp_viewporter", "zxdg_decoration_manager_v1",
            "wp_fractional_scale_manager_v1", "wl_data_device_manager",
        ] {
            #expect(
                PrivilegedGlobals.allows(
                    interface: interface, identity: sandboxed), "\(interface)")
        }
    }

    @Test func theClipboardAndCaptureGlobalsAreCovered() {
        // The two that motivated the protocol: today any client can read the
        // clipboard and record the screen with no consent step.
        #expect(
            PrivilegedGlobals.interfaceNames
                .contains("ext_data_control_manager_v1"))
        #expect(
            PrivilegedGlobals.interfaceNames
                .contains("zwlr_screencopy_manager_v1"))
    }

    @Test func theManagerWithholdsItself() {
        // Nesting is a protocol error, but hiding the global is what makes the
        // error unreachable — a sandboxed client cannot mint its own identity.
        #expect(
            !PrivilegedGlobals.allows(
                interface: "wp_security_context_manager_v1", identity: sandboxed))
    }

    @Test func sessionWideObservationAndControlGlobalsAreWithheld() {
        for interface in [
            "zwlr_output_manager_v1", "zwp_input_method_manager_v2",
            "ext_foreign_toplevel_list_v1",
        ] {
            #expect(
                PrivilegedGlobals.interfaceNames.contains(interface),
                "\(interface) must be gated before it is advertised")
        }
    }
}

@Suite @MainActor struct SecurityContextListenerTests {
    /// A real listening socketpair-backed listener plus a close pipe.
    private func makeListener(
        engine: String = "org.flatpak"
    ) -> (SecurityContextListener, listenPath: String, closeWrite: Int32) {
        let path = "/tmp/nucleus-sec-\(UInt64.random(in: 0..<UInt64.max)).sock"
        let listen = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path) - 1
        let bytes = Array(path.utf8)
        withUnsafeMutablePointer(to: &address.sun_path) {
            unsafe $0.withMemoryRebound(
                to: UInt8.self, capacity: capacity + 1
            ) { destination in
                for index in bytes.indices {
                    unsafe destination[index] = bytes[index]
                }
                unsafe destination[bytes.count] = 0
            }
        }
        _ = withUnsafePointer(to: &address) {
            unsafe $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                unsafe bind(
                    listen, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        _ = Glibc.listen(listen, 4)

        var closePipe = [Int32](repeating: -1, count: 2)
        _ = unsafe pipe(&closePipe)
        let listener = SecurityContextListener(
            identity: SecurityContextIdentity(sandboxEngine: engine),
            listenFD: listen,
            closeFD: closePipe[0])
        return (listener, path, closePipe[1])
    }

    @Test func acceptingReturnsNilWhenNothingIsQueued() {
        let (listener, path, closeWrite) = makeListener()
        defer {
            listener.stop()
            _ = Glibc.close(closeWrite)
            _ = unsafe unlink(path)
        }
        // The descriptor arrives from the client and may be blocking; the
        // listener forces O_NONBLOCK, without which this call would never
        // return and would wedge the compositor's main actor.
        #expect(listener.acceptOne() == nil)
    }

    @Test func aQueuedConnectionIsAccepted() {
        let (listener, path, closeWrite) = makeListener()
        defer {
            listener.stop()
            _ = Glibc.close(closeWrite)
            _ = unsafe unlink(path)
        }
        let client = connect(to: path)
        #expect(client >= 0)
        defer { _ = Glibc.close(client) }

        let accepted = listener.acceptOne()
        #expect(accepted != nil)
        if let accepted { _ = Glibc.close(accepted) }
    }

    @Test func anOpenCloseFdIsNotTreatedAsClosure() {
        let (listener, path, closeWrite) = makeListener()
        defer {
            listener.stop()
            _ = Glibc.close(closeWrite)
            _ = unsafe unlink(path)
        }
        // A sandbox manager holds this open for the confined app's lifetime;
        // reading it as closure would retire a live listener.
        #expect(!listener.isClosedByPeer())
    }

    @Test func closingTheCloseFdRetiresTheListener() {
        let (listener, path, closeWrite) = makeListener()
        defer {
            listener.stop()
            _ = unsafe unlink(path)
        }
        _ = Glibc.close(closeWrite)
        #expect(listener.isClosedByPeer())
    }

    @Test func stoppingIsIdempotentAndReleasesBothDescriptors() {
        let (listener, path, closeWrite) = makeListener()
        defer {
            _ = Glibc.close(closeWrite)
            _ = unsafe unlink(path)
        }
        listener.stop()
        #expect(listener.listenFD == -1)
        #expect(listener.closeFD == -1)
        // A second stop must not double-close, which would risk closing a
        // descriptor another part of the compositor has since been handed.
        listener.stop()
        #expect(listener.listenFD == -1)
    }

    @Test func theIdentityIsCarriedByTheSocketRatherThanTheClient() {
        let (listener, path, closeWrite) = makeListener(engine: "org.snap")
        defer {
            listener.stop()
            _ = Glibc.close(closeWrite)
            _ = unsafe unlink(path)
        }
        // Nothing a connecting client does contributes to this — it is fixed
        // when the sandbox manager commits, which is what makes it unforgeable.
        #expect(listener.identity.sandboxEngine == "org.snap")
    }

    private func connect(to path: String) -> Int32 {
        let client = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path) - 1
        let bytes = Array(path.utf8)
        withUnsafeMutablePointer(to: &address.sun_path) {
            unsafe $0.withMemoryRebound(
                to: UInt8.self, capacity: capacity + 1
            ) { destination in
                for index in bytes.indices {
                    unsafe destination[index] = bytes[index]
                }
                unsafe destination[bytes.count] = 0
            }
        }
        let result = withUnsafePointer(to: &address) {
            unsafe $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                unsafe Glibc.connect(
                    client, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            _ = Glibc.close(client)
            return -1
        }
        return client
    }
}
