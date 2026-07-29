import Testing
@testable import NucleusWindowClientRender

@Suite
struct WaylandVulkanSelectionTests {
    @Test
    func linuxDeviceIdentityDecodesExtendedMajorAndMinor() {
        #expect(linuxDeviceNumbers(0xe281)
            == (major: 226, minor: 129))
        let encoded = UInt64(0x123 & 0xff)
            | UInt64(0xabc & 0xfff) << 8
            | UInt64(0x123 & ~0xff) << 12
            | UInt64(0xabc & ~0xfff) << 32
        #expect(linuxDeviceNumbers(encoded)
            == (major: 0xabc, minor: 0x123))
    }
}
