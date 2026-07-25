import Testing
@testable import NucleusRenderer
import VulkanC
import Vulkan
import NucleusSkiaGraphiteBridge

// Converted from OutputAccumulatorFixture: the AccumulatorState
// resize/invalidation state machine is hardware-independent and asserts
// directly; the GPU-backed OutputAccumulator lifecycle (allocate → draw →
// snapshot prefix → present → resize) runs over the mandatory headless Graphite
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

}
