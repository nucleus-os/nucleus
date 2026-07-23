import Testing
@testable import NucleusAndroidGraphicsContract

private let feedback = WaylandDmabufFeedback(
    mainDevice: GraphicsDeviceID(major: 226, minor: 1),
    tranches: [
        WaylandDmabufTranche(
            targetDevice: GraphicsDeviceID(major: 226, minor: 1),
            scanout: true,
            formats: [
                DrmFormatModifier(format: 0x3432_5258, modifier: 0),
                DrmFormatModifier(format: 0x3432_5258, modifier: 7),
            ])
    ])

@Test func allocationRequestEnforcesTheThreeBufferContract() throws {
    let envelope = BrokerEnvelope(
        messageID: 1,
        kind: .allocate,
        allocationRequest: BufferAllocationRequest(
            width: 1280,
            height: 720,
            feedback: feedback))
    try envelope.validate(receivedFileDescriptorCount: 0)

    let invalid = BrokerEnvelope(
        messageID: 2,
        kind: .allocate,
        allocationRequest: BufferAllocationRequest(
            width: 1280,
            height: 720,
            bufferCount: 2,
            feedback: feedback))
    #expect(throws: GraphicsContractValidationError.invalidBufferCount(2)) {
        try invalid.validate(receivedFileDescriptorCount: 0)
    }
}

@Test func descriptorSlotsMustBeDenseAndMatchTheAncillaryData() {
    let envelope = BrokerEnvelope(
        messageID: 3,
        kind: .helloReply,
        descriptorSlots: [
            GraphicsFileDescriptorSlot(index: 1, role: .acquireTimeline)
        ])
    #expect(throws: GraphicsContractValidationError.invalidDescriptorSlots) {
        try envelope.validate(receivedFileDescriptorCount: 1)
    }
}

@Test func feedbackPreservesTranchePriorityWhileRemovingDuplicates() {
    let repeated = WaylandDmabufFeedback(
        mainDevice: feedback.mainDevice,
        tranches: feedback.tranches + [
            WaylandDmabufTranche(
                targetDevice: feedback.mainDevice,
                scanout: false,
                formats: [feedback.tranches[0].formats[0]])
        ])
    #expect(repeated.orderedFormats == feedback.tranches[0].formats)
}

@Test func messageKindRequiresItsExactPayload() {
    let envelope = BrokerEnvelope(messageID: 4, kind: .render)
    #expect(throws: GraphicsContractValidationError.invalidPayload(.render)) {
        try envelope.validate(receivedFileDescriptorCount: 0)
    }
}

@Test func renderRequestsRejectZeroFrameAndBufferIdentifiers() {
    let envelope = BrokerEnvelope(
        messageID: 5,
        kind: .render,
        renderRequest: RenderRequest(bufferID: 0, frameNumber: 0))
    #expect(throws: GraphicsContractValidationError.invalidRenderContract) {
        try envelope.validate(receivedFileDescriptorCount: 0)
    }
}

@Test func allocationReplyDescriptorRolesMustMatchEveryBufferPlaneAndTimeline() {
    let diagnostic = BrokerDeviceDiagnostic(
        renderNode: "/dev/dri/renderD128",
        primaryNode: "/dev/dri/card1",
        renderDevice: GraphicsDeviceID(major: 226, minor: 128),
        primaryDevice: GraphicsDeviceID(major: 226, minor: 1),
        pci: PciDeviceID(
            domain: 0,
            bus: 1,
            device: 0,
            function: 0,
            vendor: 0x10de,
            product: 0x2684),
        vulkanDeviceName: "GPU",
        vulkanDriverName: "driver",
        vulkanDriverInfo: "1",
        vulkanDeviceUUID: "00112233445566778899aabbccddeeff",
        vulkanAPIVersion: 1,
        hardwareDriver: true,
        gbmBackend: "drm")
    var buffers: [BrokerBuffer] = []
    for index in 0..<3 {
        let planeFDIndex = UInt8(index * 2)
        let releaseFDIndex = UInt8(index * 2 + 1)
        buffers.append(BrokerBuffer(
            id: UInt64(index + 1),
            width: 64,
            height: 64,
            format: 0x3432_5258,
            modifier: 0,
            planes: [DmabufPlane(fdIndex: planeFDIndex, offset: 0, stride: 256)],
            releaseTimelineFDIndex: releaseFDIndex))
    }
    var slots: [GraphicsFileDescriptorSlot] = []
    for index in 0..<3 {
        slots.append(GraphicsFileDescriptorSlot(
            index: UInt8(index * 2),
            role: .dmaBufPlane,
            bufferID: UInt64(index + 1),
            planeIndex: 0))
        slots.append(GraphicsFileDescriptorSlot(
            index: UInt8(index * 2 + 1),
            role: .releaseTimeline,
            bufferID: UInt64(index + 1)))
    }
    slots.append(GraphicsFileDescriptorSlot(index: 6, role: .acquireTimeline))
    let valid = BrokerEnvelope(
        messageID: 6,
        kind: .allocationReply,
        allocationReply: BufferAllocationReply(
            device: diagnostic,
            buffers: buffers,
            acquireTimelineFDIndex: 6),
        descriptorSlots: slots)
    #expect(throws: Never.self) {
        try valid.validate(receivedFileDescriptorCount: 7)
    }
    var mismatched = valid
    mismatched.descriptorSlots[1] = GraphicsFileDescriptorSlot(
        index: 1,
        role: .releaseTimeline,
        bufferID: 2)
    #expect(throws: GraphicsContractValidationError.invalidAllocationReply) {
        try mismatched.validate(receivedFileDescriptorCount: 7)
    }
}
