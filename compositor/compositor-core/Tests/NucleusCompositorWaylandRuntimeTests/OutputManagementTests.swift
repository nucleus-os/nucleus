import Testing
@testable import NucleusCompositorWaylandRuntime

// What a display tool can and cannot ask for. The protocol is atomic, so the
// interesting property is not "does scale work" but "does an unsupported
// request take the whole configuration down with it" — a partially applied
// atomic configuration is the failure mode worth guarding.
@Suite struct OutputConfigurationRejectionTests {
    @Test func everyRejectionExplainsItself() {
        // These reach the log, not the client — the protocol only ever says
        // `failed` — so they have to be readable on their own.
        for rejection: OutputConfigurationRejection in [
            .modeChangeUnsupported, .customModeUnsupported,
            .transformUnsupported, .adaptiveSyncUnsupported,
            .disableUnsupported, .unknownHead,
        ] {
            #expect(!rejection.reason.isEmpty, "\(rejection)")
        }
    }

    @Test func distinctCausesAreDistinctValues() {
        // A single "unsupported" case would make the log useless for telling
        // a rotation request apart from a mode request.
        #expect(OutputConfigurationRejection.modeChangeUnsupported
            != .customModeUnsupported)
        #expect(OutputConfigurationRejection.transformUnsupported
            != .adaptiveSyncUnsupported)
    }
}

@Suite struct OutputConfigurationRequestTests {
    @Test func aRequestCarriesOnlyWhatCanBeApplied() {
        // Scale and position are what the topology reconciler can honor;
        // nothing else appears in the request at all, so there is no way to
        // accidentally plumb an unsupported field through to it.
        let request = OutputConfigurationRequest(
            outputID: 7, scale: 1.5, positionX: 2560, positionY: 0)
        #expect(request.outputID == 7)
        #expect(request.scale == 1.5)
        #expect(request.positionX == 2560)
        #expect(request.positionY == 0)
    }

    @Test func unsetFieldsStayUnsetRatherThanDefaulting() {
        // A configuration that sets only position must not silently reset the
        // output's scale to some default.
        let request = OutputConfigurationRequest(
            outputID: 1, scale: nil, positionX: 100, positionY: 200)
        #expect(request.scale == nil)

        let scaleOnly = OutputConfigurationRequest(
            outputID: 1, scale: 2.0, positionX: nil, positionY: nil)
        #expect(scaleOnly.positionX == nil)
        #expect(scaleOnly.positionY == nil)
    }

    @Test func requestsAreComparableSoNoOpAppliesAreDetectable() {
        let a = OutputConfigurationRequest(
            outputID: 3, scale: 1, positionX: 0, positionY: 0)
        let b = OutputConfigurationRequest(
            outputID: 3, scale: 1, positionX: 0, positionY: 0)
        #expect(a == b)
    }
}

@Suite @MainActor struct OutputManagementGatingTests {
    @Test func theOutputManagerIsWithheldFromSandboxedClients() {
        // Reconfiguring the display is session-wide authority; a confined
        // application must not have it.
        #expect(PrivilegedGlobals.interfaceNames
            .contains("zwlr_output_manager_v1"))
        #expect(!PrivilegedGlobals.allows(
            interface: "zwlr_output_manager_v1",
            identity: SecurityContextIdentity(sandboxEngine: "org.flatpak")))
    }

    @Test func anUnconfinedDisplayToolStillReachesIt() {
        // wlr-randr and kanshi are ordinary unconfined clients.
        #expect(PrivilegedGlobals.allows(
            interface: "zwlr_output_manager_v1", identity: nil))
    }
}
