import Glibc
import NucleusSessionProtocol
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
        let descriptors = try SessionChannel.socketPair()
        let bytes = expected.encoded
        try SessionChannel.send(bytes, to: descriptors.1)
        close(descriptors.1)

        let decoded = try SessionConfiguration.inherited(arguments: [
            "fixture",
            SessionConfiguration.descriptorArgument,
            String(descriptors.0),
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

    @Test func reporterSendsOneTypedPacketAndClosesItsChannel() throws {
        let descriptors = try SessionChannel.socketPair()
        defer { _ = close(descriptors.0) }
        let reporter = SessionReadinessReporter(
            role: .compositor, descriptor: descriptors.1)
        try reporter.report(.compositorReady)

        let bytes = try SessionChannel.receive(
            from: descriptors.0,
            maximumBytes: SessionReadinessMessage.encodedSize)
        #expect(SessionReadinessMessage(encoded: bytes) ==
            SessionReadinessMessage(
                role: .compositor,
                milestone: .compositorReady))
    }
}
