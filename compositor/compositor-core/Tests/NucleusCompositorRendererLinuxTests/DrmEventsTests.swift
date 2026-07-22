import Testing
@testable import NucleusRenderer
@testable import NucleusCompositorRendererLinux
import NucleusCompositorDrmC

// The token → user_data → trampoline → handler round-trip and the
// timestamp/field delivery are hardware-independent. The fixture's best-effort
// real-DRM readability probe + drain (which asserted nothing) is dropped.
@MainActor
@Suite struct DrmEventsTests {
    @Test func pageFlipTrampoline() {
        // Token → user_data → trampoline → handler round-trip. Drives the exact
        // @convention(c) trampoline libdrm would call, with a synthetic
        // completion, and asserts the decoded event matches. Ownership is a
        // borrowed handoff: the owning scope keeps the token alive.
        var received: [DrmPageFlipEvent] = []
        let token = DrmPageFlipToken { received.append($0) }
        drmPageFlipTrampoline(token.commitUserData(), 123_456_789, 42, 7)
        #expect(received.count == 1, "trampoline-dispatches-once")
        #expect(received.first == DrmPageFlipEvent(timestampNs: 123_456_789, sequence: 42, crtcId: 7),
                "trampoline-delivers-fields")

        // A second armed flip reuses the stable token pointer.
        drmPageFlipTrampoline(token.commitUserData(), 999, 43, 7)
        #expect(received.count == 2 && received[1].sequence == 43, "trampoline-reused")

        // A nil user_data (commit staged without a token) is ignored, not a crash.
        drmPageFlipTrampoline(nil, 1, 1, 1)
        #expect(received.count == 2, "trampoline-nil-userdata-ignored")

        #expect(token.commitUserData() == token.commitUserData(), "stable-borrowed-userdata")
        withExtendedLifetime(token) {}
    }
}
