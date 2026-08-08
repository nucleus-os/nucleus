import WaylandServerC

/// A generated, type-checked declaration of one Wayland global.
///
/// The descriptor phantom type fixes the native interface and request vtable.
/// Handwritten policy supplies only the implementation object, the per-client
/// owner factory, and optional post-install behavior.
@MainActor
@safe
package struct WaylandGlobalSpecification<
    Interface: WaylandServerInterface
> {
    package let implementation: AnyObject
    package let advertisedVersion: Int32
    package let makeOwner:
        (
            OpaquePointer,
            Int32,
            UInt32
        ) -> AnyObject?

    package init<Implementation: AnyObject, Owner: AnyObject>(
        implementation: Implementation,
        advertisedVersion: Int32,
        owner:
            @escaping (
                Implementation,
                WaylandResourceHandle<Interface>
            ) -> Owner?,
        handler: @escaping (Owner) -> Interface.Requests?,
        installed:
            @escaping (
                Implementation,
                Owner,
                WaylandResourceHandle<Interface>
            ) -> Void
    ) {
        self.implementation = implementation
        self.advertisedVersion = Swift.min(
            advertisedVersion, Interface.maximumVersion)
        unsafe self.makeOwner = { client, version, id in
            var installedHandle: WaylandResourceHandle<Interface>?
            let created: Owner? = unsafe WaylandResource.create(
                client: client,
                interface: Interface.self,
                version: version,
                id: id,
                owner: { handle in
                    installedHandle = handle
                    return owner(implementation, handle)
                },
                handler: handler,
                installed: { resourceOwner in
                    guard let installedHandle else { return }
                    installed(
                        implementation, resourceOwner, installedHandle)
                })
            return created
        }
    }
}

/// Owns one native global and the complete Swift state required to bind it.
///
/// The native userdata points to this registration, so one process-wide C
/// callback can serve every generated global without erasing the implementation
/// object or repeating a handwritten actor boundary.
@MainActor
@safe
package final class WaylandGlobalRegistration {
    package let implementation: AnyObject
    private let bindOwner:
        (
            OpaquePointer,
            Int32,
            UInt32
        ) -> AnyObject?
    private let advertisedVersion: Int32
    private var global: WaylandGlobal?

    package init?<Interface: WaylandServerInterface>(
        display: WaylandDisplay,
        specification: WaylandGlobalSpecification<Interface>
    ) {
        implementation = specification.implementation
        unsafe bindOwner = specification.makeOwner
        advertisedVersion = specification.advertisedVersion
        global = nil

        let data = unsafe Unmanaged.passUnretained(self).toOpaque()
        guard
            let nativeGlobal = unsafe WaylandGlobal(
                display: display,
                interface: Interface.descriptor.nativeInterface,
                version: specification.advertisedVersion,
                data: data,
                bind: waylandGlobalBind)
        else { return nil }
        global = nativeGlobal
    }

    fileprivate func bind(
        client: OpaquePointer,
        requestedVersion: UInt32,
        id: UInt32
    ) {
        let version = Swift.min(
            Int32(clamping: requestedVersion),
            advertisedVersion)
        _ = unsafe bindOwner(client, version, id)
    }

    /// Stop advertising the global. Existing bound resources remain owned by
    /// their clients and continue to use their installed Swift owners.
    package func remove() {
        global = nil
    }

    isolated deinit {
        // Destroy the native global while its userdata registration and display
        // are both still alive.
        global = nil
    }
}

private let waylandGlobalBind:
    @convention(c) (
        OpaquePointer?,
        UnsafeMutableRawPointer?,
        UInt32,
        UInt32
    ) -> Void = { client, data, version, id in
        guard let client = unsafe client, let data = unsafe data else { return }
        let registration = unsafe Unmanaged<WaylandGlobalRegistration>
            .fromOpaque(data).takeUnretainedValue()
        nonisolated(unsafe) let actorClient = unsafe client
        let actorRegistration = registration
        MainActor.assumeIsolated {
            unsafe actorRegistration.bind(
                client: actorClient,
                requestedVersion: version,
                id: id)
        }
    }
