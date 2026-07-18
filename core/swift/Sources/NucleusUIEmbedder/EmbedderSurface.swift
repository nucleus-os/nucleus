@_spi(NucleusCompositor) import NucleusLayers
import NucleusTypes
import NucleusUI

// The embedder-facing surface of NucleusUI.
//
// These are members NucleusUI declares `package` and this module re-exposes as
// plain `public`. That indirection is the point: `package` access is scoped to
// the `Nucleus` package by the compiler, so the only way to reach these from
// outside is to depend on *this* module — which is a line in `Package.swift`
// that the build graph enforces and a reader can review.
//
// The alternative, marking them `@_spi` on NucleusUI directly, grants
// all-or-nothing access per group to anyone willing to write the import. That
// is a speed bump, not a boundary.

// MARK: - Recording and registration

/// Registered paint content plus the layer update that binds it. Hold it until
/// the update has been applied or appended; it keeps the content and any
/// transient text handles alive.
public struct RegisteredPaintContent {
    package let inner: RegisteredPaint

    /// The property update binding the registered content.
    public var update: NucleusLayers.LayerPropertyUpdate { inner.update }

    /// Bind this content to `layer`: apply the update locally and append it to
    /// the ambient transaction so the compositor sees it.
    ///
    /// One call rather than three, and it keeps the registered content and any
    /// transient text handles alive across both steps — releasing between them
    /// would drop the content's last reference before it was published.
    @MainActor
    public func bind(to layer: Layer) {
        layer.apply(update)
        LayerTransaction.appendAmbient(
            .properties(layer: layer.id, update), in: layer.context)
        withExtendedLifetime(inner) {}
    }
}

extension PaintRecording {
    /// The lowered command stream. Embedder-only: a product view authors
    /// through `GraphicsContext` and never inspects what it produced.
    public var paintCommands: [PaintCommand] { commands }
    public var payloadBytes: [UInt8] { payload }
}

/// Lower and register one recorded drawing, independent of the view tree.
///
/// The single path from a recording to a layer update. `ViewLayerPublisher`
/// uses it from its diff path; React Native's mount path calls it directly,
/// because RN builds its own layer tree and has no publisher.
@MainActor
public func registerPaint(
    _ recording: PaintRecording,
    width: Float,
    height: Float,
    in context: Context
) throws(LayerError) -> RegisteredPaintContent {
    RegisteredPaintContent(
        inner: try PaintRegistration.register(
            recording, width: width, height: height, in: context))
}

extension Layer {
    /// Apply `update` to this layer, optionally appending it to the ambient
    /// transaction so a compositor reading committed state sees it too.
    ///
    /// An embedder that builds its own layer tree needs this; one publishing
    /// through `WindowScene` does not, because the publisher batches its own
    /// transactions.
    @MainActor
    public func applyProperties(
        _ update: NucleusLayers.LayerPropertyUpdate, ambient: Bool = false
    ) {
        apply(update)
        guard ambient else { return }
        LayerTransaction.appendAmbient(.properties(layer: id, update), in: context)
    }
}

// MARK: - Views

extension View {
    /// The layer this view draws into. An embedder that builds its own layer
    /// tree parents and binds content here.
    public var embedderBackingLayer: Layer { backingLayer }

    /// What this view last drew. `displayIfNeeded()` refreshes it.
    public var recordedDrawing: PaintRecording { layerContent.recording }
}

// MARK: - Graphics contexts

extension GraphicsContext {
    /// Record a drawing outside the normal display pass. Product code receives
    /// a context in `View.draw(in:)` and never constructs one.
    public static func makeEmbedderContext() -> GraphicsContext {
        GraphicsContext()
    }

    /// The recorded drawing, with any unbalanced `saveGState` closed off.
    public var recordedDrawing: PaintRecording { recording }
}

// MARK: - Scenes

extension WindowScene {
    /// The scene's root layer, created and attached on first use. An embedder
    /// attaching its own content parents it here.
    public func attachedRootLayer() throws(UIError) -> Layer {
        try ensureRootAttached()
    }

    /// The sublayer index at which embedder-owned content at `level` should be
    /// inserted, so it lands above the scene's own windows at or below it.
    public func sublayerIndex(forLevel level: WindowLevel) -> UInt32 {
        insertionIndex(forLevel: level)
    }

    /// Publish this scene's windows interleaved with embedder-owned content by
    /// window level.
    public func publish(
        placing placements: [ScenePlacement] = [],
        includes windowIncluded: @MainActor (Window) -> Bool = { _ in true }
    ) throws(UIError) -> PublishedScene {
        try publishPlacing(placements, includes: windowIncluded)
    }
}

// MARK: - Application

public enum EmbedderApplication {
    /// Install `context` as the current render context for the duration of
    /// `body`. Views minted inside it attach to that context's layer tree.
    @MainActor
    public static func withContext<T>(_ context: Context, _ body: () throws -> T) rethrows -> T {
        try Application.withContext(context, body)
    }

    @MainActor
    public static func pushContext(_ context: Context) {
        Application.pushContext(context)
    }

    @MainActor
    public static func popContext() {
        Application.popContext()
    }
}
