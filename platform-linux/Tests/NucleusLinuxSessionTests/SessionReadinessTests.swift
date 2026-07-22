import Glibc
import NucleusLinuxSession
import Testing

@Suite struct SessionReadinessTests {
    @Test func typedConfigurationRoundTripsBinaryAndHexEncoding() throws {
        let expected = try SessionConfiguration(
            outputScale: 1.75,
            presentMode: .mailboxLatestWins,
            enableVulkanValidation: true,
            traceProtocol: true,
            traceDrmDemand: true,
            drmDevicePath: "/dev/dri/renderD129",
            wallpaperPath: "~/Pictures/wallpaper.jpeg")
        #expect(try SessionConfiguration(encoded: expected.encoded) == expected)
        #expect(try SessionConfiguration(hexEncoded: expected.hexEncoded) == expected)
    }

    @Test func typedConfigurationRejectsInvalidValuesAndBytes() {
        #expect(throws: SessionConfigurationFailure.self) {
            _ = try SessionConfiguration(outputScale: 0)
        }
        #expect(throws: SessionConfigurationFailure.self) {
            _ = try SessionConfiguration(drmDevicePath: "renderD129")
        }
        #expect(throws: SessionConfigurationFailure.self) {
            _ = try SessionConfiguration(encoded: [1, 2, 3])
        }
        var unknownFlags = SessionConfiguration.defaults.encoded
        unknownFlags[6] |= 1 << 7
        #expect(throws: SessionConfigurationFailure.self) {
            _ = try SessionConfiguration(encoded: unknownFlags)
        }
        #expect(throws: SessionConfigurationFailure.self) {
            _ = try SessionConfiguration.inherited(arguments: [
                "fixture",
                SessionConfiguration.descriptorArgument, "7",
                SessionConfiguration.descriptorArgument, "8",
            ])
        }
        #expect(throws: SessionReadinessFailure.self) {
            _ = try SessionProcessRole.inherited(arguments: [
                "fixture",
                SessionProcessRole.argument, "1",
                SessionProcessRole.argument, "2",
            ])
        }
    }

    @Test func childReadsConfigurationFromItsInheritedDescriptor() throws {
        let expected = try SessionConfiguration(
            outputScale: 2,
            presentMode: .mailboxLatestWins,
            wallpaperPath: "/tmp/wallpaper.jpeg")
        var descriptors = [Int32](repeating: -1, count: 2)
        try #require(pipe(&descriptors) == 0)
        let bytes = expected.encoded
        try #require(write(descriptors[1], bytes, bytes.count) == bytes.count)
        close(descriptors[1])

        let decoded = try SessionConfiguration.inherited(arguments: [
            "fixture",
            SessionConfiguration.descriptorArgument,
            String(descriptors[0]),
        ])
        #expect(decoded == expected)
    }

    @Test func messageRoundTripsEveryField() throws {
        let expected = SessionReadinessMessage(
            role: .supervisor,
            milestone: .failed,
            detail: -73)
        #expect(SessionReadinessMessage(encoded: expected.encoded) == expected)
    }

    @Test func decoderRejectsWrongSizeAndMagic() {
        #expect(SessionReadinessMessage(encoded: []) == nil)
        var corrupt = SessionReadinessMessage(
            role: .shell,
            milestone: .shellReady).encoded
        corrupt[0] ^= 0xff
        #expect(SessionReadinessMessage(encoded: corrupt) == nil)
    }

    @Test func reporterWritesOneTypedRecordAndClosesItsPipe() throws {
        var descriptors = [Int32](repeating: -1, count: 2)
        try #require(pipe(&descriptors) == 0)
        defer { _ = close(descriptors[0]) }
        let reporter = SessionReadinessReporter(
            role: .compositor,
            descriptor: descriptors[1])
        try reporter.report(.compositorReady)

        var bytes = [UInt8](
            repeating: 0,
            count: SessionReadinessMessage.encodedSize)
        let count = read(descriptors[0], &bytes, bytes.count)
        #expect(count == bytes.count)
        #expect(SessionReadinessMessage(encoded: bytes) ==
            SessionReadinessMessage(
                role: .compositor,
                milestone: .compositorReady))
        #expect(read(descriptors[0], &bytes, bytes.count) == 0)
    }
}
