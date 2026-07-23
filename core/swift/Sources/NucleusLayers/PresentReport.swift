package import NucleusTypes

public struct PresentReport: Sendable, Equatable {
    public var predictedPresentationNanoseconds: UInt64
    public var targetPresentationNanoseconds: UInt64
    public var nextPresentID: UInt64

    public init(
        predictedPresentationNanoseconds: UInt64,
        targetPresentationNanoseconds: UInt64,
        nextPresentID: UInt64
    ) {
        self.predictedPresentationNanoseconds = predictedPresentationNanoseconds
        self.targetPresentationNanoseconds = targetPresentationNanoseconds
        self.nextPresentID = nextPresentID
    }

    package init(_ report: NucleusTypes.PresentReport) {
        self.init(
            predictedPresentationNanoseconds: report.predictedPresentationNs,
            targetPresentationNanoseconds: report.targetPresentationNs,
            nextPresentID: report.nextPresentId
        )
    }
}
