import Testing
import NucleusRenderModel
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

    // Exercise the renderer-owner's public bring-up entry. The invalid descriptor
    // fails the initial fstat check before Vulkan access, proving the public API
    // compiles, links, and rejects an invalid host handle.
    @Test @MainActor func bringUpFailsClosed() {
        let resourceHost = SwiftResourceHost()
        let store = RetainedTreeStore(resourceHost: resourceHost)
        #expect(DRMScanoutPresenter.create(
            drmDeviceFd: -1,
            enableValidation: false,
            presentPolicy: .vsync,
            store: store,
            resourceHost: resourceHost,
            asyncRenderWakeSink: RendererTestWakeSink()) == nil,
            "runtime-failed-closed")
    }
}
