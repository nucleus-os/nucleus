import Swift

public let rootContextId: Swift.UInt32 = 1
public let shellOverlayContextId: Swift.UInt32 = 62

public struct PresentReport: Swift.Equatable, Swift.Sendable {
    public var predictedPresentationNanoseconds: Swift.UInt64
    public var targetPresentationNanoseconds: Swift.UInt64
    public var nextPresentID: Swift.UInt64
    public init(
        predictedPresentationNanoseconds: Swift.UInt64 = Swift.UInt64(),
        targetPresentationNanoseconds: Swift.UInt64 = Swift.UInt64(),
        nextPresentID: Swift.UInt64 = Swift.UInt64()
    ) {
        self.predictedPresentationNanoseconds = predictedPresentationNanoseconds
        self.targetPresentationNanoseconds = targetPresentationNanoseconds
        self.nextPresentID = nextPresentID
    }
}
