/// Baseline metrics a container uses to align unlike text-bearing children.
public struct LayoutBaselineMetrics: Sendable, Equatable {
    public var firstFromTop: Double
    public var lastFromBottom: Double

    public init(firstFromTop: Double, lastFromBottom: Double) {
        self.firstFromTop = firstFromTop.isFinite ? max(0, firstFromTop) : 0
        self.lastFromBottom = lastFromBottom.isFinite ? max(0, lastFromBottom) : 0
    }
}

/// A view that can expose text baselines for a proposed final size.
///
/// Passing the size matters for wrapped text: its last baseline changes when
/// the container width changes.
@MainActor
public protocol LayoutBaselineProviding: AnyObject {
    func layoutBaselines(for size: Size) -> LayoutBaselineMetrics
}
