@_spi(NucleusCompositor) import NucleusUI
@_spi(NucleusCompositor) import NucleusLayers

/// Binds a mounted component's drawing to its backing layer.
///
/// Lowering and registration now live in `NucleusUI.PaintRegistration`, the one
/// shared seam; what remains here is RN's own layer-binding path, which does
/// not go through `ViewLayerPublisher`. Phase 6 collapses the remaining
/// indirection by making the paragraph component a real `View` subclass.
enum ReactLayerContentCommitter {
    @MainActor
    static func commitDisplayContentIfNeeded(for view: View) throws {
        view.displayIfNeeded()
        try commit(recording: view.layerContent.recording, for: view)
    }

    @MainActor
    static func commit(recording: PaintRecording, for view: View) throws {
        let registered = try PaintRegistration.register(
            recording,
            width: Float(view.bounds.size.width),
            height: Float(view.bounds.size.height),
            in: view.backingLayer.context)
        view.backingLayer.apply(registered.update)
        LayerTransaction.appendAmbient(
            .properties(layer: view.backingLayer.id, registered.update),
            in: view.backingLayer.context
        )
        // Hold the registered content and any transient text handles until the
        // update has been applied and appended.
        withExtendedLifetime(registered) {}
    }
}
