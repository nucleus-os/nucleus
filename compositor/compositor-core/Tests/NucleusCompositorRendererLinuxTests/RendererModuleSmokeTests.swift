import Testing
@testable import NucleusCompositorRendererLinux

// Converted from RendererModuleSmokeFixture — module + link proof for the
// `NucleusRenderer` graph module. Constructs trivial pure public values and
// drives the renderer-owner bring-up entry through its fail-closed path.
@Suite struct RendererModuleSmokeTests {
    @Test func pureValueTypes() {
        // A pure public value type from the module's vk surface.
        let layout = GbmPlaneLayout(offset: 0, stride: 256, handle: 7)
        #expect(layout.stride == 256 && layout.handle == 7, "gbm-plane-layout-fields")

        let layout2 = GbmPlaneLayout(offset: 4096, stride: 512, handle: 9)
        #expect(layout2.offset == 4096 && layout2 != layout, "gbm-plane-layout-distinct")
    }

    // Exercise the renderer-owner's public bring-up entry. With an invalid DRM
    // fd the GBM-device step fails closed (after Vulkan instance/device select),
    // so `create` returns nil without constructing a context — proving the
    // public API compiles + links and the failure path is clean. The live
    // compositor passes the real DRM master fd at bring-up.
    @Test(.disabled("creates a real Vulkan instance (flaky on partial-ICD hosts)")) @MainActor func bringUpFailsClosed() {
        #expect(RendererRuntime.create(drmDeviceFd: -1) == nil, "runtime-failed-closed")
    }
}
