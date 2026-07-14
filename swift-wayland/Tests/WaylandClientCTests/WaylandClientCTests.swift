import Testing
import WaylandClientC

// Proves the generated client module imports under C++ interop (the mode consumers build it in —
// the generator's `namespace` neutralisation exists for exactly this) and that the marshalling in
// WaylandProtocolsC links.
@Suite struct WaylandClientCTests {
    @Test func extensionInterfaceLinks() {
        // xdg_wm_base_interface is defined by xdg-shell-protocol.c in WaylandProtocolsC; taking its
        // pointer proves the module imports and the marshalling target links.
        #expect(swift_wayland_iface_xdg_wm_base() != nil)
        #expect(swift_wayland_iface_wl_surface() != nil)
    }

    @Test func fixedPointHelpers() {
        #expect(swift_wayland_fixed_to_double(swift_wayland_fixed_from_double(1.5)) == 1.5)
        #expect(swift_wayland_fixed_to_double(swift_wayland_fixed_from_double(-0.25)) == -0.25)
    }
}
