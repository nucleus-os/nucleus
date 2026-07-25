// Generic registry binding — the client mirror of the server advertising globals with WaylandGlobal.
// A consumer declares the globals it wants (interface + max version + whether it may appear more than
// once); the registry watches wl_registry, binds each match (version-capped), tracks it by registry
// name, and fires onBind / onRemove so the consumer can attach a listener and react to hotplug.
//
// It is @MainActor: the registry mutates its bound-set from the wl_registry listener, which libwayland
// invokes synchronously from whatever thread pumps the connection. The common client pumps its display
// on the main actor (as a GUI event loop does), so the listener reasserts that with assumeIsolated and
// the consumer's callbacks run main-actor-clean. A client dispatching off the main thread should drive
// WaylandClientDispatch's WlRegistryClient directly instead.

public import WaylandClientC
public import WaylandClientDispatch

/// A global the consumer wants bound. Matched against the registry's advertised interface by name
/// (read from the interface descriptor); bound at min(advertised, maxVersion).
/// The interface descriptor points at process-lifetime generated protocol storage.
@safe public struct DesiredGlobal {
    public let interface: UnsafePointer<wl_interface>
    public let maxVersion: UInt32
    /// wl_output / wl_seat and friends can be advertised multiple times; a manager global once.
    public let allowsMultiple: Bool

    public init(_ interface: UnsafePointer<wl_interface>, maxVersion: UInt32, allowsMultiple: Bool = false) {
        unsafe self.interface = interface
        self.maxVersion = maxVersion
        self.allowsMultiple = allowsMultiple
    }

    /// The wire interface name (the registry advertises globals by this string).
    public var interfaceName: String { unsafe String(cString: interface.pointee.name) }
}

/// A bound registry global: its numeric registry `name`, the bound proxy, the negotiated `version`,
/// and the interface it satisfies (pointer-identical to the DesiredGlobal's, for reverse lookup).
/// Retains the display connection so the borrowed proxy cannot outlive its
/// owning native connection. Interface descriptors have process lifetime.
@safe public struct BoundGlobal {
    public let name: UInt32
    public let proxy: OpaquePointer
    public let version: UInt32
    public let interface: UnsafePointer<wl_interface>
    private let connectionOwner: WaylandConnection

    fileprivate init(
        name: UInt32,
        proxy: OpaquePointer,
        version: UInt32,
        interface: UnsafePointer<wl_interface>,
        connectionOwner: WaylandConnection
    ) {
        self.name = name
        unsafe self.proxy = proxy
        self.version = version
        unsafe self.interface = interface
        self.connectionOwner = connectionOwner
    }
}

@MainActor
/// Owns its registry proxy and confines listener-driven mutation to the main actor.
@safe public final class WaylandRegistry {
    /// The registry proxy is valid only while its display connection is alive.
    private let connection: WaylandConnection
    private let registry: OpaquePointer
    /// Desired globals keyed by interface name (the registry advertises by name).
    private let wanted: [String: DesiredGlobal]
    /// Bound globals keyed by registry name, so global_remove can find and drop them.
    private var bound: [UInt32: BoundGlobal] = [:]

    /// Fired when a wanted global is bound (attach its listener here). Runs on the main actor.
    public var onBind: ((BoundGlobal) -> Void)?
    /// Fired when a previously bound global is removed (hotplug / compositor teardown).
    public var onRemove: ((BoundGlobal) -> Void)?

    public init?(_ connection: WaylandConnection, wanting: [DesiredGlobal]) {
        guard let reg = unsafe connection.getRegistry() else { return nil }
        self.connection = connection
        unsafe registry = reg
        var m: [String: DesiredGlobal] = [:]
        for g in wanting { m[g.interfaceName] = g }
        wanted = m
        unsafe WlRegistryClient.addListener(registry, owner: self)
    }

    isolated deinit {
        unsafe wl_registry_destroy(registry)
    }

    /// The single bound global for an interface (nil if none / not yet advertised).
    public func singleton(_ interface: UnsafePointer<wl_interface>) -> BoundGlobal? {
        bound.values.first { unsafe $0.interface == interface }
    }

    /// Every bound global for a multi-instance interface (e.g. all wl_outputs).
    public func instances(_ interface: UnsafePointer<wl_interface>) -> [BoundGlobal] {
        bound.values.filter { unsafe $0.interface == interface }
    }

    private func bindGlobal(name: UInt32, interfaceName: String, version: UInt32) {
        guard let want = wanted[interfaceName] else { return }
        // Singleton globals: first advertisement wins; ignore duplicates.
        if !want.allowsMultiple,
           bound.values.contains(where: { unsafe $0.interface == want.interface })
        {
            return
        }
        let useVersion = min(version, want.maxVersion)
        guard let raw = unsafe wl_registry_bind(registry, name, want.interface, useVersion) else {
            return
        }
        let global = unsafe BoundGlobal(
            name: name,
            proxy: OpaquePointer(raw),
            version: useVersion,
            interface: want.interface,
            connectionOwner: connection)
        bound[name] = global
        onBind?(global)
    }

    private func removeGlobal(name: UInt32) {
        guard let gone = bound.removeValue(forKey: name) else { return }
        onRemove?(gone)
    }
}

// The generated listener copies the interface name before invoking this synchronous
// callback, so only Sendable values cross into the main actor.
extension WaylandRegistry: WlRegistryEvents {
    public nonisolated func global(
        _ proxy: WaylandBorrowedProxy<WlRegistryClient>,
        name: UInt32,
        interface: String,
        version: UInt32
    ) {
        MainActor.assumeIsolated {
            bindGlobal(
                name: name, interfaceName: interface, version: version)
        }
    }
    public nonisolated func globalRemove(
        _ proxy: WaylandBorrowedProxy<WlRegistryClient>,
        name: UInt32
    ) {
        MainActor.assumeIsolated { removeGlobal(name: name) }
    }
}
