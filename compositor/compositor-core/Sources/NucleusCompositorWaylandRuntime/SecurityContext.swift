// wp_security_context_v1 — sandbox identity, and the gate it exists to enable.
//
// The mechanism is the whole point: a sandboxed client is not identified by
// guessing at its pid, cgroup, or executable, but by *which socket it connected
// on*. A sandbox manager (Flatpak's portal, say) creates a listening socket,
// commits an identity for it, and hands that socket to the confined app. Every
// client that arrives on it carries that identity by construction, and nothing
// the client does can forge or shed it.
//
// Without this, every Wayland client on the system can read the clipboard
// through ext-data-control and capture the screen through wlr-screencopy, with
// no consent step. Those globals are hidden from sandboxed clients here.

import Glibc
import WaylandProtocolTypes
import WaylandServer
import WaylandServerC
import WaylandServerDispatch

/// The sandbox identity a client connected under.
package struct SecurityContextIdentity: Equatable, Hashable, Sendable {
    /// Reverse-DNS name of the sandbox technology, e.g. `org.flatpak`.
    package var sandboxEngine: String
    /// The confined application's identifier within that engine.
    package var appID: String
    /// Distinguishes two instances of the same application.
    package var instanceID: String

    package init(sandboxEngine: String, appID: String = "", instanceID: String = "") {
        self.sandboxEngine = sandboxEngine
        self.appID = appID
        self.instanceID = instanceID
    }
}

/// Globals withheld from sandboxed clients.
///
/// Each grants authority over the session as a whole rather than over the
/// client's own surfaces: reading what every other application copied, watching
/// or recording every other application's pixels, enumerating and controlling
/// windows the client does not own, or reconfiguring the display. A confined
/// application that could reach any of these would not be confined.
///
/// The security-context manager withholds itself, so a sandboxed client cannot
/// mint an identity — nesting is forbidden by the protocol, and hiding the
/// global is the enforcement that makes the error unreachable in practice.
package enum PrivilegedGlobals {
    package static let interfaceNames: Set<String> = [
        "ext_data_control_manager_v1",
        "zwlr_data_control_manager_v1",
        "zwlr_screencopy_manager_v1",
        "zwlr_foreign_toplevel_manager_v1",
        "ext_foreign_toplevel_list_v1",
        "ext_workspace_manager_v1",
        "zwlr_gamma_control_manager_v1",
        "zwlr_output_manager_v1",
        "zwlr_output_power_manager_v1",
        "zwlr_virtual_pointer_manager_v1",
        "zwp_virtual_keyboard_manager_v1",
        "zwp_input_method_manager_v2",
        "xwayland_shell_v1",
        "wp_security_context_manager_v1",
    ]

    /// Whether a client carrying `identity` may see `interface`.
    ///
    /// Confinement is the only rule here. Xwayland's protocol is scoped to one
    /// specific client rather than to confinement, so `RouterHost` owns that
    /// rule and applies it before consulting this one.
    package static func allows(
        interface: String, identity: SecurityContextIdentity?
    ) -> Bool {
        guard identity != nil else { return true }
        return !interfaceNames.contains(interface)
    }
}

@MainActor
@safe final class SecurityContextManager: WpSecurityContextManagerV1Requests {
    private unowned let display: WaylandDisplay
    /// Committed listeners, each accepting for one identity.
    private(set) var listeners: [SecurityContextListener] = []
    /// Identity per connected client. Cleared when the client goes away.
    private var identities: [WaylandClientID: SecurityContextIdentity] = [:]

    init(display: WaylandDisplay) {
        self.display = display
    }

    /// The identity a client connected under, or nil if it is unconfined.
    func identity(of client: WaylandClientID) -> SecurityContextIdentity? {
        identities[client]
    }

    func createListener(
        _ request: WaylandRequest<WpSecurityContextManagerV1Server>,
        id: WlNewId<WpSecurityContextV1Server>,
        listen_fd: consuming WaylandOwnedFileDescriptor,
        close_fd: consuming WaylandOwnedFileDescriptor
    ) {
        let listen = listen_fd.take()
        let close = close_fd.take()

        // A sandboxed client must not be able to mint identities. The global
        // filter already hides this manager from one, so reaching here means
        // the filter is misconfigured — fail loudly rather than silently
        // granting the escape.
        if let client = request.clientID, identities[client] != nil {
            _ = Glibc.close(listen)
            _ = Glibc.close(close)
            request.postError(
                .nested,
                message: "a sandboxed client cannot create a security context")
            return
        }

        guard Self.isListeningSocket(listen) else {
            _ = Glibc.close(listen)
            _ = Glibc.close(close)
            request.postError(
                .invalidListenFd,
                message: "listen_fd is not a listening socket")
            return
        }

        let context = id.create(owner: { _ in
            SecurityContext(manager: self, listenFD: listen, closeFD: close)
        })
        if context == nil {
            _ = Glibc.close(listen)
            _ = Glibc.close(close)
        }
    }

    /// `SO_ACCEPTCONN` is the only honest way to answer this: a socket the
    /// client never called `listen` on would silently accept nothing forever.
    private static func isListeningSocket(_ descriptor: Int32) -> Bool {
        var accepting: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        let result = withUnsafeMutablePointer(to: &accepting) {
            unsafe getsockopt(
                descriptor, SOL_SOCKET, SO_ACCEPTCONN, $0, &length)
        }
        return result == 0 && accepting != 0
    }

    fileprivate func activate(_ listener: SecurityContextListener) {
        listeners.append(listener)
    }

    fileprivate func retire(_ listener: SecurityContextListener) {
        listeners.removeAll { $0 === listener }
    }

    /// Accept everything queued on every committed listener, tagging each new
    /// client with the identity of the socket it arrived on.
    ///
    /// Returns true when any client was adopted, so the caller can treat it
    /// like any other reactor source that made progress.
    @discardableResult
    func acceptPendingClients() -> Bool {
        var adopted = false
        for listener in listeners {
            while let connection = listener.acceptOne() {
                guard let client = unsafe display.createClient(fd: connection),
                    let clientID = unsafe WaylandClientID(client)
                else {
                    _ = Glibc.close(connection)
                    continue
                }
                identities[clientID] = listener.identity
                adopted = true
            }
        }
        // A closed close_fd is the sandbox manager saying it is done handing
        // out this socket; the listener stops accepting but existing clients
        // keep their identity for as long as they live.
        for listener in listeners where listener.isClosedByPeer() {
            listener.stop()
            retire(listener)
        }
        return adopted
    }

    func clientDisconnected(_ client: WaylandClientID) {
        identities[client] = nil
    }

    /// Whether a client may see a global. Installed as the display filter.
    func allows(client: WaylandClientID, interface: String) -> Bool {
        PrivilegedGlobals.allows(
            interface: interface, identity: identities[client])
    }
}

/// One committed listening socket and the identity it confers.
@MainActor
@safe final class SecurityContextListener {
    let identity: SecurityContextIdentity
    private(set) var listenFD: Int32
    private(set) var closeFD: Int32

    init(identity: SecurityContextIdentity, listenFD: Int32, closeFD: Int32) {
        self.identity = identity
        self.listenFD = listenFD
        self.closeFD = closeFD
        // The client handed us these; nothing guarantees they are nonblocking,
        // and a blocking accept on a drained queue would wedge the compositor's
        // main actor permanently.
        Self.makeNonBlocking(listenFD)
        Self.makeNonBlocking(closeFD)
    }

    private static func makeNonBlocking(_ descriptor: Int32) {
        let flags = fcntl(descriptor, F_GETFL, 0)
        guard flags >= 0 else { return }
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
    }

    func acceptOne() -> Int32? {
        guard listenFD >= 0 else { return nil }
        while true {
            let connection = accept(listenFD, nil, nil)
            if connection >= 0 { return connection }
            if errno == EINTR { continue }
            return nil
        }
    }

    /// True once the sandbox manager closes its end of close_fd.
    func isClosedByPeer() -> Bool {
        guard closeFD >= 0 else { return false }
        var byte: UInt8 = 0
        while true {
            let count = withUnsafeMutablePointer(to: &byte) {
                unsafe read(closeFD, $0, 1)
            }
            if count == 0 { return true }
            if count < 0 {
                if errno == EINTR { continue }
                // EAGAIN: still open with nothing to say.
                return false
            }
            // The protocol sends no data on this fd; anything readable is
            // noise, so keep draining rather than treating it as closure.
            return false
        }
    }

    func stop() {
        if listenFD >= 0 { _ = Glibc.close(listenFD) }
        if closeFD >= 0 { _ = Glibc.close(closeFD) }
        listenFD = -1
        closeFD = -1
    }
}

/// One uncommitted security context: metadata being assembled.
@MainActor
@safe final class SecurityContext: WpSecurityContextV1Requests {
    private unowned let manager: SecurityContextManager
    private var listenFD: Int32
    private var closeFD: Int32
    private var sandboxEngine: String?
    private var appID: String?
    private var instanceID: String?
    private var committed = false

    init(manager: SecurityContextManager, listenFD: Int32, closeFD: Int32) {
        self.manager = manager
        self.listenFD = listenFD
        self.closeFD = closeFD
    }

    isolated deinit {
        // Uncommitted contexts own their descriptors; a committed one handed
        // them to its listener and zeroed these.
        if listenFD >= 0 { _ = Glibc.close(listenFD) }
        if closeFD >= 0 { _ = Glibc.close(closeFD) }
    }

    func destroy(_ request: WaylandRequest<WpSecurityContextV1Server>) {
        request.destroy()
    }

    func setSandboxEngine(
        _ request: WaylandRequest<WpSecurityContextV1Server>, name: String
    ) {
        guard check(request, current: sandboxEngine, value: name) else { return }
        sandboxEngine = name
    }

    func setAppId(
        _ request: WaylandRequest<WpSecurityContextV1Server>, app_id: String
    ) {
        guard check(request, current: appID, value: app_id) else { return }
        appID = app_id
    }

    func setInstanceId(
        _ request: WaylandRequest<WpSecurityContextV1Server>, instance_id: String
    ) {
        guard check(request, current: instanceID, value: instance_id)
        else { return }
        instanceID = instance_id
    }

    /// Shared precondition for every setter: not already committed, not already
    /// set, and the value itself well-formed.
    private func check(
        _ request: WaylandRequest<WpSecurityContextV1Server>,
        current: String?,
        value: String
    ) -> Bool {
        guard !committed else {
            request.postError(
                .alreadyUsed, message: "security context already committed")
            return false
        }
        guard current == nil else {
            request.postError(.alreadySet, message: "metadata already set")
            return false
        }
        guard !value.isEmpty, !value.utf8.contains(0) else {
            request.postError(
                .invalidMetadata, message: "metadata must be non-empty text")
            return false
        }
        return true
    }

    func commit(_ request: WaylandRequest<WpSecurityContextV1Server>) {
        guard !committed else {
            request.postError(
                .alreadyUsed, message: "security context already committed")
            return
        }
        // The engine names the confinement technology, which is what makes the
        // identity meaningful; an app id with no engine identifies nothing.
        guard let sandboxEngine else {
            request.postError(
                .invalidMetadata,
                message: "sandbox engine must be set before commit")
            return
        }
        committed = true
        let listener = SecurityContextListener(
            identity: SecurityContextIdentity(
                sandboxEngine: sandboxEngine,
                appID: appID ?? "",
                instanceID: instanceID ?? ""),
            listenFD: listenFD,
            closeFD: closeFD)
        // Ownership moves to the listener.
        listenFD = -1
        closeFD = -1
        manager.activate(listener)
    }
}
