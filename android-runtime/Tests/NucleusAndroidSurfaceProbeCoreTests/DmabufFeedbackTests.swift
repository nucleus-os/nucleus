import Foundation
import Testing
import NucleusAndroidGraphicsContract
@testable import NucleusAndroidSurfaceProbeCore

@Test func feedbackTableDecodesNativeFormatModifierRecords() throws {
    var data = Data(count: 32)
    data.withUnsafeMutableBytes { bytes in
        bytes.storeBytes(of: UInt32(0x3432_5258), toByteOffset: 0, as: UInt32.self)
        bytes.storeBytes(of: UInt64(7), toByteOffset: 8, as: UInt64.self)
        bytes.storeBytes(of: UInt32(0x3432_5241), toByteOffset: 16, as: UInt32.self)
        bytes.storeBytes(of: UInt64(11), toByteOffset: 24, as: UInt64.self)
    }
    #expect(try DmabufFeedbackTable.decode(data) == [
        DrmFormatModifier(format: 0x3432_5258, modifier: 7),
        DrmFormatModifier(format: 0x3432_5241, modifier: 11),
    ])
}

@Test func feedbackAccumulatorPreservesTranchePriorityAndFlags() throws {
    var data = Data(count: 16)
    data.withUnsafeMutableBytes { bytes in
        bytes.storeBytes(of: UInt32(0x3432_5258), toByteOffset: 0, as: UInt32.self)
        bytes.storeBytes(of: UInt64(3), toByteOffset: 8, as: UInt64.self)
    }
    let accumulator = DmabufFeedbackAccumulator()
    try accumulator.setFormatTable(data)
    let device = GraphicsDeviceID(major: 226, minor: 128)
    accumulator.setMainDevice(device)
    accumulator.setTargetDevice(device)
    accumulator.setIndices([0])
    accumulator.setFlags(1)
    try accumulator.finishTranche()
    let feedback = try accumulator.finish()
    #expect(feedback.mainDevice == device)
    #expect(feedback.tranches[0].scanout)
    #expect(feedback.tranches[0].formats[0].modifier == 3)
}

@Test func malformedFeedbackTableFailsClosed() {
    #expect(throws: SurfaceProbeError.invalidFormatTable) {
        try DmabufFeedbackTable.decode(Data(count: 15))
    }
}
