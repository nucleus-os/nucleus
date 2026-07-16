import NucleusLayers
import Tracy

@MainActor
package final class ViewLayerPublisher: ~Sendable {
    private struct SnapshotRect: Sendable, Equatable {
        var x: Float
        var y: Float
        var w: Float
        var h: Float
    }

    private struct ViewLayerSnapshot: Sendable, Equatable {
        var backingLayerID: UInt64
        var parentBackingLayerID: UInt64
        var x: Float
        var y: Float
        var w: Float
        var h: Float
        var opacity: Float
        var shadow: Shadow?
        var layerKind: LayerKind
        var backdropMaterial: BackdropMaterial
        var commands: [ViewLayerContentCommand]
        var role: LayerRole
        var backdropGroup: BackdropGroup
        var actionPolicy: ActionPolicy
        var creationFrame: SnapshotRect?
        var creationOpacity: Float?
    }

    private struct BackingLayerCache: ~Sendable {
        var backingLayer: Layer
        var backdropLayer: Layer?
        var contentLayer: Layer?
        var parentBackingLayerID: UInt64
        var frame: GeometryRect?
        var opacity: Double?
        var shadow: Shadow?
        var backdropGroup: BackdropGroup
        var backdropFrame: GeometryRect?
        var backdropOpacity: Double?
        var backdropMaterial: BackdropMaterial?
        var contentFrame: GeometryRect?
        var paintBackingLayerID: UInt64?
        var paintWidth: Float?
        var paintHeight: Float?
        var paintCommands: [PaintCommand]
    }

    private struct BackingLayerUpdate: ~Sendable {
        var state: BackingLayerCache
        var created: Bool
        var targetFrame: GeometryRect
    }

    package let context: Context
    private var rootLayer: Layer?
    private var rootAttached = false
    private var backingLayerCache: [UInt64: BackingLayerCache] = [:]

    package init(context: Context) {
        self.context = context
    }

    package func ensureRootAttached() throws(UIError) -> Layer {
        var transaction = LayerTransaction(context: context)
        let rootLayer = ensureRootLayer(transaction: &transaction)
        guard !rootAttached else {
            transaction.abort()
            return rootLayer
        }

        do {
            try transaction.insert(rootLayer)
            try transaction.commit()
            rootAttached = true
        } catch let error {
            transaction.abort()
            throw UIError(error)
        }
        return rootLayer
    }

    package func publish(roots: [View]) throws(UIError) -> [PublishedVisualContent] {
        let traceZone = Trace.beginZone("nucleus.view_layer.publish", color: Trace.Color.blue)
        defer {
            traceZone.end()
        }
        do {
            try LayerTransaction.flushImplicit(in: context)
        } catch let error {
            throw UIError(error)
        }

        var snapshots: [ViewLayerSnapshot] = []
        for root in roots {
            appendViewTree(root, parentBackingLayerID: 0, snapshots: &snapshots)
        }
        Trace.plot("swift.nucleus.view_layer.snapshots", UInt64(snapshots.count))

        try publish(snapshots: snapshots)
        let visualRoots = snapshots.filter { $0.parentBackingLayerID == 0 }
        return visualRoots.enumerated().map { index, snapshot in
            PublishedVisualContent.viewLayer(
                id: snapshot.backingLayerID,
                rootLayerID: snapshot.backingLayerID,
                orderIndex: UInt32(index)
            )
        }
    }

    @discardableResult
    private func appendViewTree(
        _ view: View,
        parentBackingLayerID: UInt64,
        snapshots: inout [ViewLayerSnapshot]
    ) -> Bool {
        guard !view.isHidden else {
            return false
        }
        view.layoutIfNeeded()
        view.displayIfNeeded()
        let content = view.layerContent
        let presentation = content.presentation
        let frame = view.frame
        let backingLayerID = view.backingLayer.id.rawValue
        let publicationBackdropMaterial = view.properties.layerUpdate().backdropMaterial ??
            view.backingLayer.descriptor.backdropMaterial
        let creationFrame = presentation.creationFrame.map {
            SnapshotRect(
                x: Float($0.origin.x),
                y: Float($0.origin.y),
                w: Float($0.size.width),
                h: Float($0.size.height)
            )
        }
        var childSnapshots: [ViewLayerSnapshot] = []
        for child in view.childViews {
            appendViewTree(child, parentBackingLayerID: backingLayerID, snapshots: &childSnapshots)
        }
        let hasSemanticLayer = view.backingLayer.descriptor.kind != .container
        let hasOwnContent = hasSemanticLayer ||
            !content.commands.isEmpty ||
            content.shadow != nil ||
            presentation.role != .generic ||
            presentation.backdropGroup != .none ||
            presentation.actionPolicy != .none ||
            presentation.creationFrame != nil ||
            presentation.creationOpacity != nil
        guard hasOwnContent || !childSnapshots.isEmpty else {
            return false
        }
        snapshots.append(ViewLayerSnapshot(
            backingLayerID: backingLayerID,
            parentBackingLayerID: parentBackingLayerID,
            x: Float(frame.origin.x),
            y: Float(frame.origin.y),
            w: Float(frame.size.width),
            h: Float(frame.size.height),
            opacity: Float(view.alphaValue),
            shadow: content.shadow,
            layerKind: view.backingLayer.descriptor.kind,
            backdropMaterial: publicationBackdropMaterial,
            commands: content.commands,
            role: presentation.role,
            backdropGroup: presentation.backdropGroup,
            actionPolicy: presentation.actionPolicy,
            creationFrame: creationFrame,
            creationOpacity: presentation.creationOpacity.map(Float.init)
        ))
        snapshots.append(contentsOf: childSnapshots)
        return true
    }

    private func publish(snapshots: [ViewLayerSnapshot]) throws(UIError) {
        var transaction = LayerTransaction(context: context)
        var didMutate = false
        let rootLayer = ensureRootLayer(transaction: &transaction)
        let shouldAttachRoot = !rootAttached
        if shouldAttachRoot {
            do {
                try transaction.insert(rootLayer)
            } catch let error {
                transaction.abort()
                throw UIError(error)
            }
            didMutate = true
        }

        do {
            var seen = Set<UInt64>()

            for snapshot in snapshots {
                seen.insert(snapshot.backingLayerID)
                let update = try ensureBackingLayer(for: snapshot, transaction: &transaction)
                var state = update.state
                if update.created {
                    didMutate = true
                }
                try reconcileBackingLayer(
                    snapshot: snapshot,
                    update: update,
                    state: &state,
                    rootLayer: rootLayer,
                    transaction: &transaction,
                    didMutate: &didMutate
                )
                let usesBackdropLayer = try reconcileBackdrop(
                    snapshot: snapshot,
                    state: &state,
                    transaction: &transaction,
                    didMutate: &didMutate
                )
                try publishPaint(
                    snapshot: snapshot,
                    state: &state,
                    transaction: &transaction,
                    usesBackdropLayer: usesBackdropLayer,
                    didMutate: &didMutate
                )
                backingLayerCache[snapshot.backingLayerID] = state
            }

            try collectGarbage(seen: seen, transaction: &transaction, didMutate: &didMutate)

            if didMutate {
                try transaction.commit()
                if shouldAttachRoot {
                    rootAttached = true
                }
            } else {
                transaction.abort()
            }
        } catch let error {
            transaction.abort()
            throw UIError(error)
        }
    }

    private func publishPaint(
        snapshot: ViewLayerSnapshot,
        state: inout BackingLayerCache,
        transaction: inout LayerTransaction,
        usesBackdropLayer: Bool,
        didMutate: inout Bool
    ) throws(LayerError) {
        let paintCommands = snapshot.commands
            .filter { $0.kind != .backdrop }
            .map { layerPaintCommand($0) }
        defer {
            releaseTransientTextLayoutHandles(paintCommands)
        }
        let paintWidth = snapshot.w
        let paintHeight = snapshot.h

        let paintLayer: Layer?
        if paintCommands.isEmpty {
            if let content = state.contentLayer {
                try transaction.remove(content)
                state.contentLayer = nil
                didMutate = true
            }
            state.contentFrame = nil
            if state.paintBackingLayerID == state.backingLayer.id.rawValue {
                try transaction.setContent(.none, for: state.backingLayer)
                didMutate = true
            }
            if state.paintBackingLayerID != nil {
                state.paintBackingLayerID = nil
                state.paintWidth = nil
                state.paintHeight = nil
                state.paintCommands = []
            }
            paintLayer = nil
        } else if usesBackdropLayer {
            let hadContentLayer = state.contentLayer != nil
            let content = try ensureContentLayer(state: state, transaction: &transaction)
            state.contentLayer = content
            if !hadContentLayer {
                didMutate = true
            }
            if state.paintBackingLayerID == state.backingLayer.id.rawValue {
                try transaction.setContent(.none, for: state.backingLayer)
                state.paintBackingLayerID = nil
                state.paintWidth = nil
                state.paintHeight = nil
                state.paintCommands = []
                didMutate = true
            }
            let contentFrame = GeometryRect(x: 0, y: 0, width: Double(paintWidth), height: Double(paintHeight))
            if state.contentFrame != contentFrame {
                var properties = LayerPropertyUpdate.decomposedFrame(contentFrame)
                properties.opacity = 1
                try transaction.setProperties(properties, for: content)
                state.contentFrame = contentFrame
                didMutate = true
            }
            paintLayer = content
        } else {
            if let content = state.contentLayer {
                try transaction.remove(content)
                state.contentLayer = nil
                if state.paintBackingLayerID == content.id.rawValue {
                    state.paintBackingLayerID = nil
                    state.paintWidth = nil
                    state.paintHeight = nil
                    state.paintCommands = []
                }
                didMutate = true
            }
            state.contentFrame = nil
            paintLayer = state.backingLayer
        }

        if let paintLayer, state.paintBackingLayerID != nil && state.paintBackingLayerID != paintLayer.id.rawValue {
            state.paintBackingLayerID = nil
            state.paintWidth = nil
            state.paintHeight = nil
            state.paintCommands = []
        }
        if let paintLayer, state.paintWidth != paintWidth ||
            state.paintHeight != paintHeight ||
            state.paintCommands != paintCommands
        {
            try transaction.setPaintCommands(
                paintCommands,
                width: paintWidth,
                height: paintHeight,
                for: paintLayer
            )
            state.paintBackingLayerID = paintLayer.id.rawValue
            state.paintWidth = paintWidth
            state.paintHeight = paintHeight
            state.paintCommands = paintCommands
            didMutate = true
        }
    }

    /// Insert/reparent the backing layer under its resolved parent and diff its
    /// geometry/opacity/shadow/backdrop-group properties against the cached state,
    /// writing only what changed. Mutates `state` and `didMutate` in place.
    private func reconcileBackingLayer(
        snapshot: ViewLayerSnapshot,
        update: BackingLayerUpdate,
        state: inout BackingLayerCache,
        rootLayer: Layer,
        transaction: inout LayerTransaction,
        didMutate: inout Bool
    ) throws(LayerError) {
        let parent = parentLayer(for: snapshot, rootLayer: rootLayer)
        if update.created || state.parentBackingLayerID != snapshot.parentBackingLayerID {
            try transaction.insert(state.backingLayer, into: parent)
            state.parentBackingLayerID = snapshot.parentBackingLayerID
            didMutate = true
        }

        let targetOpacity = Double(snapshot.opacity)
        let semanticBackdropMaterial = snapshot.layerKind == .backdrop ? snapshot.backdropMaterial : nil
        let shadowChanged = state.shadow != snapshot.shadow
        if state.frame != update.targetFrame ||
            state.opacity != targetOpacity ||
            shadowChanged ||
            state.backdropGroup != snapshot.backdropGroup ||
            (semanticBackdropMaterial != nil && state.backdropMaterial != semanticBackdropMaterial)
        {
            try transaction.setProperties(
                layerProperties(
                    for: snapshot,
                    actionPolicy: snapshot.actionPolicy,
                    writesShadow: shadowChanged
                ),
                for: state.backingLayer
            )
            state.frame = update.targetFrame
            state.opacity = targetOpacity
            state.shadow = snapshot.shadow
            state.backdropGroup = snapshot.backdropGroup
            if let semanticBackdropMaterial {
                state.backdropMaterial = semanticBackdropMaterial
            }
            didMutate = true
        }
    }

    /// Reconcile the dedicated backdrop sublayer: create + diff it when the snapshot
    /// carries a backdrop command, or tear it down when it no longer does. Returns
    /// whether a backdrop layer is in use (paint then composites into a separate
    /// content layer rather than the backing layer). Mutates `state`/`didMutate`.
    private func reconcileBackdrop(
        snapshot: ViewLayerSnapshot,
        state: inout BackingLayerCache,
        transaction: inout LayerTransaction,
        didMutate: inout Bool
    ) throws(LayerError) -> Bool {
        let backdropCommand = snapshot.commands.first(where: { $0.kind == .backdrop })
        if let backdropCommand {
            let hadBackdrop = state.backdropLayer != nil
            let backdrop = try ensureBackdrop(
                state: state,
                command: backdropCommand,
                transaction: &transaction
            )
            state.backdropLayer = backdrop
            if !hadBackdrop {
                didMutate = true
            }
            let backdropFrame = rect(backdropCommand)
            let backdropOpacity = Double(backdropCommand.color.a)
            let backdropMaterial = backdropCommand.backdropMaterial
            if state.backdropFrame != backdropFrame ||
                state.backdropOpacity != backdropOpacity ||
                state.backdropMaterial != backdropMaterial
            {
                var properties = LayerPropertyUpdate.decomposedFrame(backdropFrame)
                properties.opacity = backdropOpacity
                properties.backdropMaterial = backdropMaterial
                try transaction.setProperties(properties, for: backdrop)
                state.backdropFrame = backdropFrame
                state.backdropOpacity = backdropOpacity
                state.backdropMaterial = backdropMaterial
                didMutate = true
            }
        } else if let backdrop = state.backdropLayer {
            try transaction.remove(backdrop)
            state.backdropLayer = nil
            state.backdropFrame = nil
            state.backdropOpacity = nil
            state.backdropMaterial = nil
            didMutate = true
        }
        return backdropCommand != nil
    }

    /// Remove the backing layer (and its backdrop/content sublayers) and drop the
    /// cache entry for every layer not present in the current snapshot set.
    private func collectGarbage(
        seen: Set<UInt64>,
        transaction: inout LayerTransaction,
        didMutate: inout Bool
    ) throws(LayerError) {
        for id in Array(backingLayerCache.keys) where !seen.contains(id) {
            if let state = backingLayerCache[id] {
                if let backdrop = state.backdropLayer {
                    try transaction.remove(backdrop)
                }
                if let content = state.contentLayer {
                    try transaction.remove(content)
                }
                try transaction.remove(state.backingLayer)
                didMutate = true
            }
            backingLayerCache.removeValue(forKey: id)
        }
    }

    private func ensureRootLayer(transaction: inout LayerTransaction) -> Layer {
        if let rootLayer {
            return rootLayer
        }
        let rootLayer = transaction.createLayer(.init(frame: .zero, opacity: 1))
        self.rootLayer = rootLayer
        return rootLayer
    }

    private func parentLayer(for snapshot: ViewLayerSnapshot, rootLayer: Layer) -> Layer {
        if snapshot.parentBackingLayerID == 0 {
            return rootLayer
        }
        return backingLayerCache[snapshot.parentBackingLayerID]?.backingLayer ?? rootLayer
    }

    private func ensureBackingLayer(
        for snapshot: ViewLayerSnapshot,
        transaction: inout LayerTransaction
    ) throws(LayerError) -> BackingLayerUpdate {
        let targetFrame = GeometryRect(
            x: Double(snapshot.x),
            y: Double(snapshot.y),
            width: Double(snapshot.w),
            height: Double(snapshot.h)
        )
        if let state = backingLayerCache[snapshot.backingLayerID] {
            return .init(state: state, created: false, targetFrame: targetFrame)
        }

        let initialFrame = snapshot.creationFrame ?? SnapshotRect(
            x: snapshot.x,
            y: snapshot.y,
            w: snapshot.w,
            h: snapshot.h
        )
        let creationFrame = GeometryRect(
            x: Double(initialFrame.x),
            y: Double(initialFrame.y),
            width: Double(initialFrame.w),
            height: Double(initialFrame.h)
        )
        let creationOpacity = Double(snapshot.creationOpacity ?? snapshot.opacity)
        let initialSemanticBackdropMaterial = snapshot.layerKind == .backdrop ? snapshot.backdropMaterial : nil
        let backingLayer = transaction.createLayer(id: LayerID(rawValue: snapshot.backingLayerID), .init(
            kind: snapshot.layerKind,
            role: snapshot.role.layersRole,
            frame: creationFrame,
            opacity: creationOpacity,
            backdropMaterial: snapshot.backdropMaterial,
            backdropGroupID: snapshot.backdropGroup.rawValue
        ))
        let state = BackingLayerCache(
            backingLayer: backingLayer,
            backdropLayer: nil,
            contentLayer: nil,
            parentBackingLayerID: UInt64.max,
            frame: creationFrame,
            opacity: creationOpacity,
            shadow: nil,
            backdropGroup: snapshot.backdropGroup,
            backdropFrame: nil,
            backdropOpacity: nil,
            backdropMaterial: initialSemanticBackdropMaterial,
            contentFrame: nil,
            paintBackingLayerID: nil,
            paintWidth: nil,
            paintHeight: nil,
            paintCommands: []
        )
        backingLayerCache[snapshot.backingLayerID] = state
        return .init(state: state, created: true, targetFrame: targetFrame)
    }

    private func ensureBackdrop(
        state: BackingLayerCache,
        command: ViewLayerContentCommand,
        transaction: inout LayerTransaction
    ) throws(LayerError) -> Layer {
        if let backdrop = state.backdropLayer {
            return backdrop
        }

        let backdrop = transaction.createLayer(.init(
            kind: .backdrop,
            frame: rect(command),
            opacity: Double(command.color.a),
            backdropMaterial: command.backdropMaterial
        ))
        try transaction.insert(backdrop, into: state.backingLayer, at: 0)
        return backdrop
    }

    private func ensureContentLayer(
        state: BackingLayerCache,
        transaction: inout LayerTransaction
    ) throws(LayerError) -> Layer {
        if let content = state.contentLayer {
            return content
        }

        let content = transaction.createLayer()
        try transaction.insert(content, into: state.backingLayer)
        return content
    }

    private func layerProperties(
        for snapshot: ViewLayerSnapshot,
        actionPolicy: ActionPolicy,
        writesShadow: Bool
    ) -> LayerPropertyUpdate {
        var properties = LayerPropertyUpdate.decomposedFrame(
            .init(
                x: Double(snapshot.x),
                y: Double(snapshot.y),
                width: Double(snapshot.w),
                height: Double(snapshot.h)
            ),
            actionPolicy: actionPolicy.layersPolicy
        )
        properties.opacity = Double(snapshot.opacity)
        if writesShadow {
            properties.shadow = (snapshot.shadow ?? .none).layersShadow
        }
        properties.backdropGroupID = snapshot.backdropGroup.rawValue
        if snapshot.layerKind == .backdrop {
            properties.backdropMaterial = snapshot.backdropMaterial
        }
        return properties
    }

    private func rect(_ command: ViewLayerContentCommand) -> GeometryRect {
        .init(
            x: Double(command.x),
            y: Double(command.y),
            width: Double(command.w),
            height: Double(command.h)
        )
    }

    private func layerPaintCommand(_ command: ViewLayerContentCommand) -> PaintCommand {
        let layoutHandle = command.kind == .textLayout ? makeTextLayoutHandle(command) : 0
        return PaintCommand(
            kind: layerPaintKind(command.kind),
            x: command.x,
            y: command.y,
            w: command.w,
            h: command.h,
            radius: command.radius,
            strokeWidth: command.strokeWidth,
            fontSize: 0,
            color: command.color.layersColor,
            imageHandle: command.imageHandle,
            textLayoutHandle: layoutHandle
        )
    }

    private func layerPaintKind(_ kind: LayerContentCommandKind) -> PaintCommandKind {
        switch kind {
        case .rect:
            .rect
        case .roundedRect:
            .roundedRect
        case .image:
            .image
        case .line:
            .line
        case .textLayout:
            .textLayout
        case .backdrop:
            .rect
        }
    }

    private func releaseTransientTextLayoutHandles(_ commands: [PaintCommand]) {
        for command in commands where command.kind == .textLayout && command.textLayoutHandle != 0 {
            TextSystem.shared.releaseLayoutHandle(command.textLayoutHandle)
        }
    }

    private func makeTextLayoutHandle(_ command: ViewLayerContentCommand) -> UInt64 {
        guard let layout = command.textLayout else {
            return 0
        }
        if let storageHandle = layout.storage?.retainedHandle(), storageHandle != 0 {
            return storageHandle
        }
        return TextSystem.shared.makeLayoutHandle(for: layout)
    }

}
