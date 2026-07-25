import Testing
import WaylandServerC

// Proves swift-wayland's WaylandServerC module imports under C++ interop and that
// both the libwayland-server interface symbols (wl_compositor) and the generated
// extension symbols compiled from wayland-scanner private-code (xdg_wm_base,
// zwlr_layer_shell_v1) link and resolve through the accessor façades.
@Test func coreInterfaceDescriptorResolves() {
    #expect(coreInterfaceName() == "wl_compositor")
}

@Test func extensionInterfaceDescriptorsLink() {
    #expect(xdgInterfaceName() == "xdg_wm_base")
    #expect(layerShellInterfaceName() == "zwlr_layer_shell_v1")
}

@safe private func coreInterfaceName() -> String? {
    guard let interface = unsafe swift_wayland_iface_wl_compositor() else { return nil }
    return unsafe String(cString: interface.pointee.name)
}

@safe private func xdgInterfaceName() -> String? {
    guard let interface = unsafe swift_wayland_iface_xdg_wm_base() else { return nil }
    return unsafe String(cString: interface.pointee.name)
}

@safe private func layerShellInterfaceName() -> String? {
    guard let interface = unsafe swift_wayland_iface_zwlr_layer_shell_v1() else { return nil }
    return unsafe String(cString: interface.pointee.name)
}
