public import NucleusLayers

public struct ViewProperties: Sendable, Equatable {
    public var frame: Rect?
    public var isHidden: Bool?
    /// Resolved backdrop material (already turned from the AppKit-typed
    /// `VisualEffectView.Material` into the substrate `BackdropMaterial`
    /// by the producer view). `nil` means the view contributes no
    /// backdrop on this commit.
    public var backdropMaterial: BackdropMaterial?

    public init(
        frame: Rect? = nil,
        isHidden: Bool? = nil,
        backdropMaterial: BackdropMaterial? = nil
    ) {
        self.frame = frame
        self.isHidden = isHidden
        self.backdropMaterial = backdropMaterial
    }
}
