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

import WaylandClientC
import WaylandClientDispatch

/// A global the consumer wants bound. Matched against the registry's advertised interface by name
/// (read from the interface descriptor); bound at min(advertised, maxVersion).
public struct DesiredGlobal {
    public let interface: UnsafePointer<wl_interface>
    public let maxVersion: UInt32
    /// wl_output / wl_seat and friends can be advertised multiple times; a manager global once.
    public let allowsMultiple: Bool

    public init(_ interface: UnsafePointer<wl_interface>, maxVersion: UInt32, allowsMultiple: Bool = false) {
        self.interface = interface
        self.maxVersion = maxVersion
        self.allowsMultiple = allowsMultiple
    }

    /// The wire interface name (the registry advertises globals by this string).
    public var interfaceName: String { String(cString: interface.pointee.name) }
}

/// A bound registry global: its numeric registry `name`, the bound proxy, the negotiated `version`,
/// and the interface it satisfies (pointer-identical to the DesiredGlobal's, for reverse lookup).
public struct BoundGlobal {
    public let name: UInt32
    public let proxy: OpaquePointer
    public let version: UInt32
    public let interface: UnsafePointer<wl_interface>
}

@MainActor
public final class WaylandRegistry {
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
        guard let reg = connection.getRegistry() else { return nil }
        registry = reg
        var m: [String: DesiredGlobal] = [:]
        for g in wanting { m[g.interfaceName] = g }
        wanted = m
        WlRegistryClient.addListener(registry, owner: self)
    }

    /// The single bound global for an interface (nil if none / not yet advertised).
    public func singleton(_ interface: UnsafePointer<wl_interface>) -> BoundGlobal? {
        bound.values.first { $0.interface == interface }
    }

    /// Every bound global for a multi-instance interface (e.g. all wl_outputs).
    public func instances(_ interface: UnsafePointer<wl_interface>) -> [BoundGlobal] {
        bound.values.filter { $0.interface == interface }
    }

    private func bindGlobal(name: UInt32, interfaceName: String, version: UInt32) {
        guard let want = wanted[interfaceName] else { return }
        // Singleton globals: first advertisement wins; ignore duplicates.
        if !want.allowsMultiple, bound.values.contains(where: { $0.interface == want.interface }) {
            return
        }
        let useVersion = min(version, want.maxVersion)
        guard let raw = wl_registry_bind(registry, name, want.interface, useVersion) else { return }
        let global = BoundGlobal(name: name, proxy: OpaquePointer(raw),
                                 version: useVersion, interface: want.interface)
        bound[name] = global
        onBind?(global)
    }

    private func removeGlobal(name: UInt32) {
        guard let gone = bound.removeValue(forKey: name) else { return }
        onRemove?(gone)
    }
}

// The registry listener is a nonisolated @convention(c) callback; the interface name is decoded to a
// Sendable String before hopping to the main actor (the CChar pointer must not cross the boundary).
extension WaylandRegistry: WlRegistryEvents {
    public nonisolated func global(_ proxy: OpaquePointer, name: UInt32,
                                   interface: UnsafePointer<CChar>?, version: UInt32) {
        guard let interface else { return }
        let interfaceName = String(cString: interface)
        MainActor.assumeIsolated { bindGlobal(name: name, interfaceName: interfaceName, version: version) }
    }
    public nonisolated func globalRemove(_ proxy: OpaquePointer, name: UInt32) {
        MainActor.assumeIsolated { removeGlobal(name: name) }
    }
}
