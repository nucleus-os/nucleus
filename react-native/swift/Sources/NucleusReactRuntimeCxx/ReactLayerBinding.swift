import NucleusUI
import NucleusUIEmbedder
import NucleusLayers

// Binding a mounted component's drawing to its backing layer.
//
// React Native builds its own layer tree rather than publishing through
// `ViewLayerPublisher`, so this step has no equivalent on the normal path and
// belongs to RN. It lives in its own file because `NucleusLayers` and
// `NucleusUI` both define a `Rect`, and the mount consumer works in the
// NucleusUI one.
//
// What this is *not* is a second paint pipeline. The former
// `ReactLayerContentCommitter` duplicated the command vocabulary, the kind
// mapping, and the transient-handle minting; all of that now goes through
// `PaintRegistration`, the same unit `ViewLayerPublisher` uses.

extension ReactComponentView {
    /// Draw this component's view and bind the result to its backing layer.
    ///
    /// React Native builds its own layer tree instead of publishing through
    /// `ViewLayerPublisher`, so this is where a mounted component's drawing
    /// reaches its layer. Only the *binding* is RN-specific: lowering and
    /// registration go through `PaintRegistration`, the same unit the publisher
    /// uses, so there is one path rather than two vocabularies to keep in sync.
    public func commitDisplayContentIfNeeded() throws {
        view.displayIfNeeded()
        let layer = view.embedderBackingLayer
        let registered = try registerPaint(
            view.recordedDrawing,
            width: Float(view.bounds.size.width),
            height: Float(view.bounds.size.height),
            in: layer.context)
        registered.bind(to: layer)
    }
}

