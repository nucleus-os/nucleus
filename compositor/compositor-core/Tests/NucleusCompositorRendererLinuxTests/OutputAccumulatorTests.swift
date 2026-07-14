import Testing
@testable import NucleusRenderer
import VulkanC
import Vulkan
import NucleusSkiaGraphiteBridge

// Converted from OutputAccumulatorFixture: the AccumulatorState
// resize/invalidation state machine is hardware-independent and asserts
// directly; the GPU-backed OutputAccumulator lifecycle (allocate → draw →
// snapshot prefix → present → resize) runs best-effort over a real Graphite
// context and asserts nothing hardware-conditional.
@Suite struct OutputAccumulatorTests {
    @Test func accumulatorStateMachine() {
        var state = AccumulatorState(width: 800, height: 600)
        #expect(state.width == 800 && state.height == 600, "state-init-dims")
        // Fresh accumulator needs a full redraw (redrawnGen 0 < invalidationGen 1).
        #expect(state.needsFullRedraw, "state-fresh-needs-redraw")
        state.markRedrawn()
        #expect(!state.needsFullRedraw, "state-redrawn-clears")

        // Same-size resize is a no-op and does not invalidate. resize() mutates,
        // so it is hoisted out of #expect (which binds its expression immutably).
        let noopResize = state.resize(width: 800, height: 600)
        #expect(!noopResize, "state-resize-noop")
        #expect(!state.needsFullRedraw, "state-resize-noop-clean")

        // A dimension change reallocates + invalidates.
        let changedResize = state.resize(width: 1024, height: 768)
        #expect(changedResize, "state-resize-changed")
        #expect(state.width == 1024 && state.height == 768, "state-resize-dims")
        #expect(state.needsFullRedraw, "state-resize-needs-redraw")
        state.markRedrawn()
        #expect(!state.needsFullRedraw, "state-resize-redrawn-clears")

        // Explicit invalidation forces a full redraw.
        state.invalidate()
        #expect(state.needsFullRedraw, "state-invalidate-needs-redraw")
        state.markRedrawn()
        #expect(!state.needsFullRedraw, "state-invalidate-redrawn-clears")
    }

    // Best-effort GPU: OutputAccumulator lifecycle. Asserts nothing
    // hardware-conditional; verifies compile + link and headless safety.
    @Test(.disabled("requires a live GPU/Vulkan device")) func outputAccumulatorLifecycleBestEffort() {
        let base = VK.loadBaseDispatch()
        let contract = VkRequirements.contract()
        guard let instance = InstanceOwner.create(
            base: base, applicationName: "OutputAccumulatorTests",
            contract: contract, enableValidation: false
        ) else { return }
        guard let selection = DeviceOwner.selectPhysicalDevice(
            instance: instance.handle, dispatch: instance.dispatch, contract: contract
        ) else { return }
        guard let device = DeviceOwner.create(
            selection: selection, instanceDispatch: instance.dispatch,
            contract: contract
        ) else { return }
        guard let queue = device.queue(family: selection.graphicsQueueFamily) else { return }

        withCStringArray(contract.deviceExtensions) { extPtr, extCount in
            var desc = nucleus.skia.VulkanContextDescriptor()
            desc.instance = UnsafeMutableRawPointer(instance.handle)
            desc.physicalDevice = UnsafeMutableRawPointer(selection.physicalDevice)
            desc.device = UnsafeMutableRawPointer(device.handle)
            desc.queue = UnsafeMutableRawPointer(queue)
            desc.graphicsQueueIndex = selection.graphicsQueueFamily
            desc.maxApiVersion = VkRequirements.minimumApiVersion.raw
            desc.deviceExtensions = extPtr
            desc.deviceExtensionCount = extCount

            let context = nucleus.skia.makeGraphiteVulkanContext(desc)
            guard context.isValid() else { return }
            let recorder = context.makeRecorder()
            guard recorder.isValid() else { return }

            guard let accumulator = OutputAccumulator.create(
                recorder: recorder, outputId: 1, width: 256, height: 128
            ) else { return }

            // Compose into the accumulator, snapshot the prefix, mark redrawn.
            let canvas = accumulator.canvas
            var bg = nucleus.skia.Color()
            bg.r = 0.2; bg.g = 0.3; bg.b = 0.4; bg.a = 1
            canvas.clear(bg)
            accumulator.snapshotPrefix()
            accumulator.markRedrawn()

            // Present the accumulator into a standalone scanout-like surface.
            let scanout = recorder.makeOffscreenSurface(256, 128)
            _ = accumulator.present(onto: scanout, alpha: 1)

            // Resize reallocates the surface + re-arms a full redraw.
            _ = accumulator.ensure(recorder: recorder, width: 320, height: 200)

            // Flush the recorded work so the context tears down cleanly.
            let recording = recorder.snapRecording()
            if recording.isValid() { _ = context.submit(recording) }
        }
    }
}
