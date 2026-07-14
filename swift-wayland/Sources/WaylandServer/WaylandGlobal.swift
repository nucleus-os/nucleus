// A registered protocol global. Its bind callback runs Swift-side: it creates the
// bound resource and attaches a Swift owner (see WaylandResource.create). The bind
// closure is @convention(c) and cannot capture, so per-global context travels
// through wl_global_create's `data` pointer or process-global state.

import WaylandServerC

public final class WaylandGlobal {
    public let global: OpaquePointer

    public init?(
        display: WaylandDisplay,
        interface: UnsafePointer<wl_interface>?,
        version: Int32,
        data: UnsafeMutableRawPointer? = nil,
        bind: @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?, UInt32, UInt32) -> Void
    ) {
        guard let global = wl_global_create(display.display, interface, version, data, bind)
        else { return nil }
        self.global = global
    }

    deinit { wl_global_destroy(global) }
}
