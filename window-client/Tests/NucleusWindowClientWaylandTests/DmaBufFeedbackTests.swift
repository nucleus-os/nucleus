import Glibc
import Testing
@testable import NucleusWindowClientWayland

@MainActor
@Suite struct DmaBufFeedbackTests {
    @Test func parsesFormatModifierTableWithoutAlignmentAssumptions()
        throws
    {
        let descriptor = unsafe memfd_create(
            "nucleus-window-client-dmabuf-feedback",
            UInt32(MFD_CLOEXEC))
        try #require(descriptor >= 0)
        defer { _ = close(descriptor) }
        let bytes: [UInt8] = [
            0x41, 0x52, 0x32, 0x34,
            0, 0, 0, 0,
            0x08, 0x07, 0x06, 0x05,
            0x04, 0x03, 0x02, 0x01,
            0x58, 0x52, 0x32, 0x34,
            0, 0, 0, 0,
            0x18, 0x17, 0x16, 0x15,
            0x14, 0x13, 0x12, 0x11,
        ]
        let written = bytes.withUnsafeBytes {
            unsafe write(descriptor, $0.baseAddress, $0.count)
        }
        try #require(written == bytes.count)

        #expect(NucleusDesktopDmaBufFeedback.readFormatTable(
            descriptor: descriptor,
            size: UInt32(bytes.count)
        ) == [
            NucleusDesktopDmaBufFormat(
                format: 0x3432_5241,
                modifier: 0x0102_0304_0506_0708),
            NucleusDesktopDmaBufFormat(
                format: 0x3432_5258,
                modifier: 0x1112_1314_1516_1718),
        ])
    }

    @Test func rejectsMalformedOrUnboundedFormatTables() {
        #expect(NucleusDesktopDmaBufFeedback.readFormatTable(
            descriptor: -1, size: 16).isEmpty)
        #expect(NucleusDesktopDmaBufFeedback.readFormatTable(
            descriptor: -1, size: 15).isEmpty)
        #expect(NucleusDesktopDmaBufFeedback.readFormatTable(
            descriptor: -1, size: 1_048_592).isEmpty)
    }
}
