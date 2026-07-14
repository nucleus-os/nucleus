@_spi(NucleusCompositor) import NucleusLayers

@MainActor
@_spi(NucleusCompositor) public final class HostedSurface: ~Sendable {
    @_spi(NucleusCompositor) public let surfaceID: Int
    package let rootView: View
    package var role: WindowRole
    package var level: WindowLevel
    package private(set) var frame: Rect?
    package private(set) var commitsFrameUpdates: Bool = false
    package private(set) var hasCommittedContent: Bool = false

    package init(
        surfaceID: Int,
        context: Context,
        role: WindowRole = .hostedSurface,
        level: WindowLevel = .normal,
        frame: Rect? = nil
    ) throws(UIError) {
        self.surfaceID = surfaceID
        self.role = role
        self.level = level
        do {
            self.rootView = try Application.withContext(context) {
                try View()
            }
        } catch let error as UIError {
            throw error
        } catch {
            throw UIError.invalidArgument(detail: String(describing: error))
        }
        if let frame {
            updateFrame(frame)
        }
    }

    package func beginCommittedFrameUpdates() {
        commitsFrameUpdates = true
    }

    package func markCommittedContent() {
        hasCommittedContent = true
    }

    package func detach() throws(UIError) {
        hasCommittedContent = false
        commitsFrameUpdates = false
        var transaction = LayerTransaction(context: rootView.backingLayer.context)
        do {
            try transaction.remove(rootView.backingLayer)
            try transaction.commit()
        } catch {
            transaction.abort()
            throw UIError.invalidArgument(detail: String(describing: error))
        }
    }

    package func updateFrame(_ frame: Rect) {
        self.frame = frame
        let update = LayerPropertyUpdate.decomposedFrame(GeometryRect(
            x: frame.origin.x,
            y: frame.origin.y,
            width: frame.size.width,
            height: frame.size.height
        ))
        rootView.backingLayer.apply(update)
        if commitsFrameUpdates {
            LayerTransaction.appendAmbient(
                .properties(layer: rootView.backingLayer.id, update),
                in: rootView.backingLayer.context
            )
        }
    }
}

@MainActor
@_spi(NucleusCompositor) public final class HostedSurfaceRegistry<Identifier: Hashable>: ~Sendable {
    private let context: Context
    private var records: [Identifier: HostedSurface] = [:]
    private var order: [Identifier] = []
    private var nextSurfaceID: Int

    package init(context: Context, firstSurfaceID: Int = 1) {
        self.context = context
        self.nextSurfaceID = firstSurfaceID
    }

    @_spi(NucleusCompositor) public func surface(
        for identifier: Identifier,
        frame: Rect? = nil,
        role: WindowRole = .hostedSurface,
        level: WindowLevel = .normal
    ) throws(UIError) -> HostedSurface {
        if let surface = records[identifier] {
            surface.role = role
            surface.level = level
            if let frame {
                surface.updateFrame(frame)
            }
            return surface
        }
        let surface = try HostedSurface(
            surfaceID: nextSurfaceID,
            context: context,
            role: role,
            level: level,
            frame: frame
        )
        records[identifier] = surface
        order.append(identifier)
        nextSurfaceID += 1
        return surface
    }

    @_spi(NucleusCompositor) public func surfaceID(for identifier: Identifier) -> Int? {
        records[identifier]?.surfaceID
    }

    @_spi(NucleusCompositor) public var surfaces: [HostedSurface] {
        order.compactMap { records[$0] }
    }

    @discardableResult
    @_spi(NucleusCompositor) public func detachSurface(_ identifier: Identifier) throws(UIError) -> Bool {
        guard let surface = records.removeValue(forKey: identifier) else {
            return false
        }
        order.removeAll { $0 == identifier }
        try surface.detach()
        return true
    }

    @_spi(NucleusCompositor) public func updateFrame(_ frame: Rect) {
        for surface in records.values {
            surface.updateFrame(frame)
        }
    }

    @_spi(NucleusCompositor) public func visualContent() -> [HostedVisualContent] {
        order.compactMap { identifier -> HostedVisualContent? in
            guard let surface = records[identifier] else {
                return nil
            }
            return HostedVisualContent(
                id: UInt64(surface.surfaceID),
                rootLayerID: surface.rootView.backingLayer.id.rawValue,
                role: surface.role,
                level: surface.level,
                visible: surface.hasCommittedContent
            )
        }
    }
}
