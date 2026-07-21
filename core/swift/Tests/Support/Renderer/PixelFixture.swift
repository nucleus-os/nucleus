public enum PixelColorFormat: String, Sendable, Equatable {
    case rgba8888
    case bgra8888
}

public struct PixelFixtureMetadata: Sendable, Equatable {
    public var backend: String
    public var colorFormat: PixelColorFormat
    public var colorSpace: String
    public var channelTolerance: UInt8

    public init(
        backend: String,
        colorFormat: PixelColorFormat,
        colorSpace: String,
        channelTolerance: UInt8 = 0
    ) {
        self.backend = backend
        self.colorFormat = colorFormat
        self.colorSpace = colorSpace
        self.channelTolerance = channelTolerance
    }
}

public struct PixelFixtureResult: Sendable, Equatable {
    public var differingChannels: Int
    public var maximumDifference: UInt8

    public var matches: Bool { differingChannels == 0 }
}

public enum PixelFixtureComparator {
    public static func compare(
        actual: [UInt8],
        expected: [UInt8],
        metadata: PixelFixtureMetadata
    ) -> PixelFixtureResult {
        guard actual.count == expected.count else {
            return PixelFixtureResult(
                differingChannels: max(actual.count, expected.count),
                maximumDifference: .max)
        }
        var differingChannels = 0
        var maximumDifference: UInt8 = 0
        for (actualChannel, expectedChannel) in zip(actual, expected) {
            let difference = UInt8(abs(
                Int(actualChannel) - Int(expectedChannel)))
            maximumDifference = max(maximumDifference, difference)
            if difference > metadata.channelTolerance {
                differingChannels += 1
            }
        }
        return PixelFixtureResult(
            differingChannels: differingChannels,
            maximumDifference: maximumDifference)
    }
}
