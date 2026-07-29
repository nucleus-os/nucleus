import Testing
@testable import NucleusCompositorRendererLinux

// Adaptive sync is a user-facing setting, not just a KMS property. The value
// that matters is an explicit disable: a capable connector drives VRR by
// default, so someone whose panel flickers or shifts brightness under it needs
// a way to turn it off, and until this existed there was none.
@Suite struct VrrPreferenceTests {
    @Test func aCapableOutputDrivesVrrWhenNoPreferenceIsStated() {
        let state = VrrState(capable: true, adaptiveSync: nil)
        #expect(state.policy == .fullscreenDirectScanoutOnly)
        #expect(state.requestedFor(directScanoutEligible: true))
    }

    @Test func anExplicitDisableTurnsItOffOnCapableHardware() {
        // The whole point of the setting.
        let state = VrrState(capable: true, adaptiveSync: false)
        #expect(state.policy == .disabled)
        #expect(!state.requestedFor(directScanoutEligible: true))
    }

    @Test func anExplicitEnableMatchesTheDefaultOnCapableHardware() {
        #expect(VrrState(capable: true, adaptiveSync: true).policy
            == VrrState(capable: true, adaptiveSync: nil).policy)
    }

    @Test func anIncapableOutputStaysOffHoweverItIsConfigured() {
        // Asking for VRR on a connector without it must not produce a policy
        // that claims otherwise, or the head would advertise a lie.
        for preference: Bool? in [nil, true, false] {
            let state = VrrState(capable: false, adaptiveSync: preference)
            #expect(state.policy == .disabled, "\(String(describing: preference))")
            #expect(!state.requestedFor(directScanoutEligible: true))
        }
    }

    @Test func togglingForcesAModesetButHoldingSteadyDoesNot() {
        // VRR_ENABLED is a modeset property; committing it every frame would
        // stall scanout, so the flag is only raised on an actual change.
        var state = VrrState(capable: true)
        #expect(state.flagsForCommit(requestedVrr: true) != 0)
        state.applyAfterCommit(requestedVrr: true)
        #expect(state.flagsForCommit(requestedVrr: true) == 0)
        #expect(state.flagsForCommit(requestedVrr: false) != 0)
    }

    @Test func vrrIsNeverRequestedWithoutDirectScanout() {
        // Composited output cannot benefit, and engaging VRR for it would
        // change refresh behavior for no reason.
        let state = VrrState(capable: true, adaptiveSync: true)
        #expect(!state.requestedFor(directScanoutEligible: false))
    }
}
