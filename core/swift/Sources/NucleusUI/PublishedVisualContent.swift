/// A foreign layer root for a scene to place in its z-order.
///
/// The embedder owns content the scene does not: the compositor places client
/// surfaces, and other embedders may place their own roots. Publication needs
/// only enough to order that content against its windows — it does not need to
/// know *what* the content is. `HostedSurface` and its registry are compositor
/// vocabulary and live in the compositor, which maps its surfaces to these
/// values when publishing.
public struct ScenePlacement: Sendable, Equatable {
    /// Embedder-assigned identity, echoed back on the published record so the
    /// embedder can match results to its own objects.
    public var id: UInt64
    public var rootLayerID: UInt64
    public var level: WindowLevel
    public var visible: Bool

    public init(
        id: UInt64,
        rootLayerID: UInt64,
        level: WindowLevel = .normal,
        visible: Bool = true
    ) {
        self.id = id
        self.rootLayerID = rootLayerID
        self.level = level
        self.visible = visible
    }
}

/// One item of a published scene, in final z-order.
///
/// There is deliberately no kind discriminant. An embedder that places its own
/// content already knows which ids are its own, so a discriminant would be the
/// scene telling the embedder something it assigned in the first place.
public struct PublishedVisualContent: Sendable, Equatable {
    public var id: UInt64
    public var rootLayerID: UInt64
    public var orderIndex: UInt32
    public var visible: Bool

    package init(id: UInt64, rootLayerID: UInt64, orderIndex: UInt32, visible: Bool = true) {
        self.id = id
        self.rootLayerID = rootLayerID
        self.orderIndex = orderIndex
        self.visible = visible
    }
}

public struct PublishedScene: Sendable, Equatable {
    public var visualContent: [PublishedVisualContent]

    package var hasVisualContent: Bool {
        !visualContent.isEmpty
    }

    package init(visualContent: [PublishedVisualContent] = []) {
        self.visualContent = visualContent
    }
}
