import NucleusConfig
import Testing

@Suite struct ConfigSnapshotCodecTests {
    @Test func resolvedSnapshotRoundTripsDeterministically() throws {
        var configuration = NucleusConfiguration.defaults
        configuration.outputs = [
            OutputConfig(
                name: "DP-2",
                scale: 1.5,
                position: OutputPosition(x: 1920, y: 0)),
            OutputConfig(
                name: "DP-1",
                scale: 1,
                position: OutputPosition(x: 0, y: 0)),
        ]

        let first = try NucleusConfigSnapshotCodec.encode(configuration)
        let second = try NucleusConfigSnapshotCodec.encode(configuration)

        #expect(first == second)
        #expect(try NucleusConfigSnapshotCodec.decode(first) == configuration)
    }

    @Test func malformedSnapshotIsRejected() {
        #expect(throws: (any Error).self) {
            _ = try NucleusConfigSnapshotCodec.decode([0xff, 0x00])
        }
    }
}
