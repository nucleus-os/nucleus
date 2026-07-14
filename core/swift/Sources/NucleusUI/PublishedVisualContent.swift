package enum PublishedVisualContentKind: UInt8, Sendable {
    case viewLayer = 1
    case hostedSurface = 2
}

@_spi(NucleusCompositor) public struct PublishedVisualContent: Sendable, Equatable {
    package var kind: PublishedVisualContentKind
    package var id: UInt64
    package var rootLayerID: UInt64
    package var orderIndex: UInt32
    package var visible: Bool

    package static func viewLayer(
        id: UInt64,
        rootLayerID: UInt64,
        orderIndex: UInt32,
        visible: Bool = true
    ) -> PublishedVisualContent {
        .init(kind: .viewLayer, id: id, rootLayerID: rootLayerID, orderIndex: orderIndex, visible: visible)
    }

    package static func hostedSurface(
        id: UInt64,
        rootLayerID: UInt64,
        orderIndex: UInt32,
        visible: Bool = true
    ) -> PublishedVisualContent {
        .init(kind: .hostedSurface, id: id, rootLayerID: rootLayerID, orderIndex: orderIndex, visible: visible)
    }
}

@_spi(NucleusCompositor) public struct HostedVisualContent: Sendable, Equatable {
    package var id: UInt64
    package var rootLayerID: UInt64
    package var role: WindowRole
    package var level: WindowLevel
    package var visible: Bool

    package init(
        id: UInt64,
        rootLayerID: UInt64,
        role: WindowRole = .hostedSurface,
        level: WindowLevel = .normal,
        visible: Bool = true
    ) {
        self.id = id
        self.rootLayerID = rootLayerID
        self.role = role
        self.level = level
        self.visible = visible
    }
}

@_spi(NucleusCompositor) public struct PublishedScene: Sendable, Equatable {
    @_spi(NucleusCompositor) public var visualContent: [PublishedVisualContent]

    package var hasVisualContent: Bool {
        !visualContent.isEmpty
    }

    package init(visualContent: [PublishedVisualContent]) {
        self.visualContent = visualContent
    }
}
