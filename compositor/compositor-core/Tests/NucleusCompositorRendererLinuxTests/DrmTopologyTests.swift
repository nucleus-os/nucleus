import Testing
import NucleusCompositorDrmC
@testable import NucleusCompositorRendererLinux

@Suite struct DrmTopologyTests {
    private static func mode(
        _ name: String = "1920x1080",
        clock: UInt32 = 148_500,
        refresh: UInt32 = 60,
        preferred: Bool = true
    ) -> DrmModeInfo {
        DrmModeInfo(
            clock: clock,
            hdisplay: 1920,
            htotal: 2200,
            vdisplay: 1080,
            vtotal: 1125,
            vrefresh: refresh,
            type: preferred ? UInt32(DRM_MODE_TYPE_PREFERRED) : 0,
            name: name)
    }

    private static func connector(
        _ id: UInt32,
        crtcs: [UInt32],
        currentCrtc: UInt32? = nil,
        currentMode: DrmModeInfo? = nil,
        modes: [DrmModeInfo] = [mode()]
    ) -> DrmConnectorCandidate {
        DrmConnectorCandidate(
            connectorID: ConnectorID(rawValue: id),
            encoderCandidates: [
                DrmEncoderCandidate(
                    encoderID: EncoderID(rawValue: id + 1_000),
                    currentCrtcID: currentCrtc.map { CrtcID(rawValue: $0) },
                    compatibleCrtcIDs: Set(crtcs.map { CrtcID(rawValue: $0) })),
            ],
            modes: modes,
            currentCrtcID: currentCrtc.map { CrtcID(rawValue: $0) },
            currentMode: currentMode,
            physicalSizeMM: PhysicalSize(widthMM: 600, heightMM: 340),
            vrrCapable: false)
    }

    private static func plane(
        _ id: UInt32, _ kind: DrmPlaneKind, crtcs: [UInt32]
    ) -> DrmPlaneCandidate {
        DrmPlaneCandidate(
            planeID: PlaneID(rawValue: id),
            kind: kind,
            compatibleCrtcIDs: Set(crtcs.map { CrtcID(rawValue: $0) }))
    }

    private static func inventory(
        generation: UInt64 = 1,
        connectors: [DrmConnectorCandidate],
        planes: [DrmPlaneCandidate]
    ) -> DrmTopologyInventory {
        let crtcs = Set(
            connectors.flatMap { $0.compatibleCrtcIDs }).sorted()
        return DrmTopologyInventory(
            generation: generation,
            crtcIDs: crtcs,
            connectors: connectors,
            planes: planes)
    }

    @Test static func competingConnectorsFailOneClosed() {
        let result = DrmTopologyPlanner.plan(inventory(
            connectors: [
                connector(1, crtcs: [10]),
                connector(2, crtcs: [10]),
            ],
            planes: [plane(100, .primary, crtcs: [10])]))

        #expect(result.snapshot.assignments.count == 1)
        #expect(result.snapshot.assignments[0].connectorID == ConnectorID(rawValue: 1))
        #expect(result.rejections == [
            DrmTopologyRejection(
                connectorID: ConnectorID(rawValue: 2),
                reason: .allocationConflict),
        ])
    }

    @Test static func allocationIsUniqueAndIndependentOfEnumerationOrder() {
        let connectors = [
            connector(1, crtcs: [10, 20]),
            connector(2, crtcs: [10, 20]),
        ]
        let planes = [
            plane(100, .primary, crtcs: [10]),
            plane(200, .primary, crtcs: [20]),
        ]
        let forward = DrmTopologyPlanner.plan(inventory(
            connectors: connectors, planes: planes)).snapshot
        let reversed = DrmTopologyPlanner.plan(inventory(
            connectors: Array(connectors.reversed()),
            planes: Array(planes.reversed()))).snapshot

        #expect(forward.assignments == reversed.assignments)
        #expect(Set(forward.assignments.map(\.crtcID)).count == 2)
        #expect(Set(forward.assignments.map(\.primaryPlaneID)).count == 2)
    }

    @Test static func primaryAndCursorPlanesAreNeverShared() {
        let result = DrmTopologyPlanner.plan(inventory(
            connectors: [
                connector(1, crtcs: [10]),
                connector(2, crtcs: [20]),
            ],
            planes: [
                plane(100, .primary, crtcs: [10, 20]),
                plane(300, .cursor, crtcs: [10, 20]),
            ]))

        #expect(result.snapshot.assignments.count == 1)
        #expect(Set(result.snapshot.assignments.map(\.primaryPlaneID)).count == 1)
        #expect(result.snapshot.assignments.compactMap(\.cursorPlaneID).count == 1)
    }

    @Test static func validExistingPipelineSurvivesUnrelatedConnector() {
        let oldMode = mode()
        let previous = OutputTopologySnapshot(
            generation: 1,
            assignments: [
                DrmPipelineAssignment(
                    connectorID: ConnectorID(rawValue: 1),
                    crtcID: CrtcID(rawValue: 20),
                    primaryPlaneID: PlaneID(rawValue: 200),
                    cursorPlaneID: nil,
                    mode: oldMode),
            ])
        let result = DrmTopologyPlanner.plan(
            inventory(
                generation: 2,
                connectors: [
                    connector(2, crtcs: [10]),
                    connector(1, crtcs: [10, 20], currentCrtc: 20, currentMode: oldMode),
                ],
                planes: [
                    plane(100, .primary, crtcs: [10]),
                    plane(200, .primary, crtcs: [20]),
                ]),
            preserving: previous)

        let surviving = result.snapshot.assignments.first {
            $0.connectorID == ConnectorID(rawValue: 1)
        }
        #expect(surviving?.crtcID == CrtcID(rawValue: 20))
        #expect(surviving?.primaryPlaneID == PlaneID(rawValue: 200))
        #expect(result.snapshot.assignments.count == 2)
    }

    @Test static func removedConnectorFreesItsPipeline() {
        let first = DrmTopologyPlanner.plan(inventory(
            generation: 1,
            connectors: [
                connector(1, crtcs: [10]),
                connector(2, crtcs: [10]),
            ],
            planes: [plane(100, .primary, crtcs: [10])])).snapshot
        let second = DrmTopologyPlanner.plan(
            inventory(
                generation: 2,
                connectors: [connector(2, crtcs: [10])],
                planes: [plane(100, .primary, crtcs: [10])]),
            preserving: first).snapshot

        #expect(second.assignments.map(\.connectorID) == [ConnectorID(rawValue: 2)])
        #expect(second.assignments[0].crtcID == CrtcID(rawValue: 10))
        #expect(second.assignments[0].primaryPlaneID == PlaneID(rawValue: 100))
    }

    @Test static func modeSelectionUsesHighestRefreshAtPreferredResolution() {
        let sixty = mode("1080p60", clock: 148_500, refresh: 60)
        let oneTwenty = mode("1080p120", clock: 297_000, refresh: 120, preferred: false)
        let withCurrent = connector(
            1, crtcs: [10], currentCrtc: 10, currentMode: sixty,
            modes: [sixty, oneTwenty])
        #expect(DrmTopologyPlanner.selectMode(for: withCurrent) == oneTwenty)

        let withoutCurrent = connector(
            1, crtcs: [10], modes: [sixty, oneTwenty])
        #expect(DrmTopologyPlanner.selectMode(for: withoutCurrent) == oneTwenty)
    }

    @Test static func modeRefreshRetainsFractionalMillihertz() {
        let fractional = mode(
            "1080p59.94", clock: 148_352, refresh: 59)
        #expect(fractional.refreshMilliHz == 59_940)
    }
}
