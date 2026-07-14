import Testing
@testable import NucleusRenderer
@testable import NucleusCompositorRendererLinux
import NucleusCompositorDrmC

// Converted from DrmDeviceFixture (Phase 10a.1): the Swift DRM selection policy
// parity-tested against the fail-closed rule `Device.zig` implements, using
// synthetic candidates (no DRM hardware). The fixture's best-effort real
// `drmGetDevices2` enumeration + ownership exercise (which asserted nothing on a
// host without /dev/dri) is dropped.
@Suite struct DrmDeviceTests {
    static func candidate(
        _ render: String, vendor: UInt16 = 0x1002, primary: String? = nil,
        connectedDisplays: Int? = nil, bootVGA: Bool = false
    ) -> DrmDeviceCandidate {
        DrmDeviceCandidate(
            renderPath: render,
            primaryPath: primary,
            vendorId: vendor,
            deviceId: 0x1234,
            pciDomain: 0,
            pciBus: 1,
            pciDev: 0,
            pciFunc: 0,
            connectedDisplayCount: connectedDisplays,
            isBootVGA: bootVGA)
    }

    static func expectSelected(_ result: Result<DrmDeviceCandidate, DrmSelectionError>, _ render: String) -> Bool {
        if case .success(let c) = result, c.renderPath == render { return true }
        return false
    }

    static func expectError(_ result: Result<DrmDeviceCandidate, DrmSelectionError>, _ err: DrmSelectionError) -> Bool {
        if case .failure(let e) = result, e == err { return true }
        return false
    }

    @Test func selectionPolicy() {
        let card0 = Self.candidate("/dev/dri/renderD128", primary: "/dev/dri/card0")
        let card1 = Self.candidate("/dev/dri/renderD129", vendor: 0x10de, primary: "/dev/dri/card1")

        // Exactly one candidate → selected.
        #expect(Self.expectSelected(selectDrmDevice(from: [card0]), "/dev/dri/renderD128"),
                "single-candidate-selected")

        // No candidates → noCandidate.
        #expect(Self.expectError(selectDrmDevice(from: []), .noCandidate),
                "empty-no-candidate")

        // Two candidates, no override → fail closed as ambiguous.
        #expect(Self.expectError(selectDrmDevice(from: [card0, card1]), .ambiguousCandidate(count: 2)),
                "ambiguous-fail-closed")

        let displayGPU = Self.candidate("/dev/dri/renderD129", primary: "/dev/dri/card1", connectedDisplays: 2)
        #expect(Self.expectSelected(selectDrmDevice(from: [card0, displayGPU]), "/dev/dri/renderD129"),
                "unique-connected-display-gpu-selected")

        let disconnectedBootGPU = Self.candidate("/dev/dri/renderD128", primary: "/dev/dri/card0", connectedDisplays: 0, bootVGA: true)
        #expect(Self.expectSelected(selectDrmDevice(from: [disconnectedBootGPU, card1]), "/dev/dri/renderD128"),
                "boot-vga-fallback-selected")

        let connectedBootGPU = Self.candidate("/dev/dri/renderD128", primary: "/dev/dri/card0", connectedDisplays: 1, bootVGA: true)
        let connectedOtherGPU = Self.candidate("/dev/dri/renderD129", primary: "/dev/dri/card1", connectedDisplays: 1)
        #expect(Self.expectSelected(selectDrmDevice(from: [connectedBootGPU, connectedOtherGPU]), "/dev/dri/renderD128"),
                "boot-vga-breaks-multiple-connected-gpu-tie")

        // Two candidates + override picks one deterministically.
        #expect(Self.expectSelected(selectDrmDevice(from: [card0, card1], overrideRenderPath: "/dev/dri/renderD129"),
                                    "/dev/dri/renderD129"),
                "override-disambiguates")

        // Override matching nothing → noCandidate (not a silent fallback).
        #expect(Self.expectError(selectDrmDevice(from: [card0, card1], overrideRenderPath: "/dev/dri/renderD200"),
                                 .noCandidate),
                "override-no-match-fails")

        // PCI address formatting parity (DDDD:BB:DD.F).
        #expect(card0.pciAddress == "0000:01:00.0", "pci-address-format")
    }
}
