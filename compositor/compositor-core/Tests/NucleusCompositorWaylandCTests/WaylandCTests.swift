import Testing
import WaylandServerC

// Proves swift-wayland's WaylandServerC module imports under C++ interop and that
// both the libwayland-server interface symbols (wl_compositor) and the generated
// extension symbols compiled from wayland-scanner private-code (xdg_wm_base,
// zwlr_layer_shell_v1) link and resolve through the accessor façades.
@Test func coreInterfaceDescriptorResolves() {
    let iface = swift_wayland_iface_wl_compositor()
    #expect(iface != nil)
    #expect(String(cString: iface!.pointee.name) == "wl_compositor")
}

@Test func extensionInterfaceDescriptorsLink() {
    let xdg = swift_wayland_iface_xdg_wm_base()
    #expect(String(cString: xdg!.pointee.name) == "xdg_wm_base")

    let layer = swift_wayland_iface_zwlr_layer_shell_v1()
    #expect(String(cString: layer!.pointee.name) == "zwlr_layer_shell_v1")
}
