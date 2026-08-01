// The layers→render producer feed (Swift-direct).
//
// `RenderTransactionLowering` lowers a `NucleusLayers.LayerTransactionBatch` into a
// `NucleusRenderModel.Transaction` ready to fold into a `RetainedTreeStore`.
//
// Scope mirrors the retained-model `Transaction` boundary (see
// `RenderTransactionApply.swift`): only created/inserted/removed/detached/
// property updates and compositor-side animation records are lowered.
//
// The field mappings, the default-action compound-frame decomposition, the
// backdrop-attachment derivation, and the content/shadow/visual-style deltas
// cover create/insert/property-update. Double-domain authoring values must be
// finite and representable in the renderer's Float domain.

package import NucleusLayers
package import NucleusRenderModel
import NucleusTypes

package enum RenderTransactionLowering {
    /// Lower one committed layers transaction into a render-model transaction
    /// (minus the commit-sink push, which the `RenderCommitSink` performs).
    package static func lower(
        _ batch: NucleusLayers.LayerTransactionBatch
    ) -> NucleusRenderModel.Transaction {
        let contextId = NucleusRenderModel.ContextID(raw: batch.contextID.rawValue)
        var txn = NucleusRenderModel.Transaction(contextId: contextId)
        txn.revision = UInt64(batch.revision)
        txn.groupId = batch.groupID
        txn.groupSeq = batch.groupSequence
        txn.completionToken = batch.completionToken

        for (id, descriptor) in batch.created {
            txn.created.append(lowerCreated(id, descriptor, contextId: contextId))
        }
        for entry in batch.inserted {
            txn.inserted.append(
                NucleusRenderModel.LayerInserted(
                    nodeId: entry.layer.rawValue,
                    parentId: entry.parent?.rawValue ?? 0,
                    index: entry.index
                ))
        }
        for id in batch.removed {
            txn.removed.append(NucleusRenderModel.LayerRemoved(nodeId: id.rawValue))
        }
        for id in batch.detached {
            txn.detached.append(NucleusRenderModel.LayerDetached(nodeId: id.rawValue))
        }
        for (layer, properties) in batch.propertyUpdates {
            txn.propertyUpdates.append(lowerPropertyUpdate(layer, properties, contextId: contextId))
        }
        let beginTimeNanoseconds =
            batch.targetPresentationNanoseconds != 0
            ? batch.targetPresentationNanoseconds
            : batch.predictedPresentationNanoseconds
        let beginTimeSeconds = Double(beginTimeNanoseconds) / 1_000_000_000
        txn.animationBeginTimeSeconds = beginTimeSeconds
        txn.animationBeginTimePending = beginTimeNanoseconds == 0
        for (layer, animation) in batch.animationsAdded {
            guard
                let lowered = lowerAnimation(
                    animation,
                    layerID: layer.rawValue,
                    transactionID: batch.transactionID,
                    inheritedCompletionToken: batch.completionToken,
                    beginTimeSeconds: beginTimeSeconds
                )
            else {
                continue
            }
            txn.animationsAdded.append(lowered)
        }
        for removal in batch.animationsRemoved {
            guard let keyPath = lowerAnimationKeyPath(removal.keyPath) else { continue }
            txn.animationsRemoved.append(
                NucleusRenderModel.AnimationRemoval(
                    layerId: removal.layer.rawValue,
                    keyPath: keyPath
                ))
        }
        return txn
    }

    private static func lowerAnimation(
        _ animation: NucleusLayers.Animation,
        layerID: UInt64,
        transactionID: UInt64,
        inheritedCompletionToken: UInt64,
        beginTimeSeconds: Double
    ) -> NucleusRenderModel.AnimationRecord? {
        guard let keyPath = lowerAnimationKeyPath(animation.keyPath) else {
            return nil
        }
        let loweredAnimation: NucleusRenderModel.Animation
        if keyPath == .transform {
            guard case .transform(let authoredFrom) = animation.fromEndpoint,
                case .transform(let authoredTo) = animation.toEndpoint
            else { return nil }
            let from = makeRenderTransform(authoredFrom)
            let to = makeRenderTransform(authoredTo)
            switch animation.curve {
            case .spring(let stiffness, let damping, let mass, _):
                loweredAnimation = .springTransform(
                    NucleusRenderModel.SpringTransformAnimation(
                        fromValue: from,
                        toValue: to,
                        mass: mass,
                        stiffness: stiffness,
                        damping: damping,
                        beginTime: beginTimeSeconds
                    ))
            case .linear:
                loweredAnimation = .basicTransform(
                    NucleusRenderModel.BasicTransformAnimation(
                        fromValue: from,
                        toValue: to,
                        duration: animation.duration,
                        timingFunction: .linear,
                        beginTime: beginTimeSeconds
                    ))
            case .bezier(let p1x, let p1y, let p2x, let p2y):
                loweredAnimation = .basicTransform(
                    NucleusRenderModel.BasicTransformAnimation(
                        fromValue: from,
                        toValue: to,
                        duration: animation.duration,
                        timingFunction: makeRenderTimingFunction(
                            p1x: p1x, p1y: p1y, p2x: p2x, p2y: p2y),
                        beginTime: beginTimeSeconds
                    ))
            }
        } else {
            guard case .scalar(let authoredFrom) = animation.fromEndpoint,
                case .scalar(let authoredTo) = animation.toEndpoint
            else { return nil }
            let from = renderFloat(authoredFrom)
            let to = renderFloat(authoredTo)
            switch animation.curve {
            case .spring(let stiffness, let damping, let mass, let initialVelocity):
                loweredAnimation = .spring(
                    NucleusRenderModel.SpringAnimation(
                        keyPath: keyPath,
                        fromValue: from,
                        toValue: to,
                        mass: mass,
                        stiffness: stiffness,
                        damping: damping,
                        initialVelocity: initialVelocity,
                        beginTime: beginTimeSeconds
                    ))
            case .linear:
                loweredAnimation = .basic(
                    NucleusRenderModel.BasicAnimation(
                        keyPath: keyPath,
                        fromValue: from,
                        toValue: to,
                        duration: animation.duration,
                        timingFunction: .linear,
                        beginTime: beginTimeSeconds
                    ))
            case .bezier(let p1x, let p1y, let p2x, let p2y):
                loweredAnimation = .basic(
                    NucleusRenderModel.BasicAnimation(
                        keyPath: keyPath,
                        fromValue: from,
                        toValue: to,
                        duration: animation.duration,
                        timingFunction: makeRenderTimingFunction(
                            p1x: p1x, p1y: p1y, p2x: p2x, p2y: p2y),
                        beginTime: beginTimeSeconds
                    ))
            }
        }
        return NucleusRenderModel.AnimationRecord(
            id: NucleusRenderModel.AnimationID(raw: animation.id),
            layerId: layerID,
            animation: loweredAnimation,
            completionToken: NucleusRenderModel.CompletionToken(
                raw: animation.completionToken != 0
                    ? animation.completionToken
                    : inheritedCompletionToken
            ),
            transactionId: transactionID,
            beginTimePending: beginTimeSeconds == 0
        )
    }

    private static func makeRenderTimingFunction(
        p1x: Float, p1y: Float, p2x: Float, p2y: Float
    ) -> NucleusRenderModel.TimingFunction {
        NucleusRenderModel.TimingFunction(
            c1x: p1x,
            c1y: p1y,
            c2x: p2x,
            c2y: p2y
        )
    }

    private static func lowerAnimationKeyPath(
        _ keyPath: NucleusTypes.LayerAnimationKeyPath
    ) -> NucleusRenderModel.RenderAnimationKeyPath? {
        switch keyPath {
        case .none: nil
        case .opacity: .opacity
        case .cornerRadius: .cornerRadius
        case .positionX: .positionX
        case .positionY: .positionY
        case .boundsW: .boundsWidth
        case .boundsH: .boundsHeight
        case .anchorPointX: .anchorPointX
        case .anchorPointY: .anchorPointY
        case .scrollOffsetX: .scrollOffsetX
        case .scrollOffsetY: .scrollOffsetY
        case .transform: .transform
        case .borderTopWidth, .borderRightWidth,
            .borderBottomWidth, .borderLeftWidth:
            nil
        }
    }

    // MARK: - Created

    /// Decomposes the authored frame into renderer `position` + `bounds`;
    /// `anchorPoint` is fixed to (0, 0) on creation.
    private static func lowerCreated(
        _ id: NucleusLayers.LayerID,
        _ descriptor: NucleusLayers.LayerDescriptor,
        contextId: NucleusRenderModel.ContextID
    ) -> NucleusRenderModel.LayerCreated {
        let frame = descriptor.frame
        let frameW = renderFloat(frame.width)
        let frameH = renderFloat(frame.height)
        return NucleusRenderModel.LayerCreated(
            nodeId: id.rawValue,
            kind: lowerLayerKind(descriptor, frameW: frameW, frameH: frameH, contextId: contextId),
            role: descriptor.role,
            backdropAttachment: lowerBackdropAttachment(
                contextId: contextId,
                effect: descriptor.backdropMaterial,
                groupId: descriptor.backdropGroupID,
                frameWidth: frameW,
                frameHeight: frameH
            ),
            position: NucleusRenderModel.Point2D(x: renderFloat(frame.x), y: renderFloat(frame.y)),
            anchorPoint: NucleusRenderModel.Point2D(x: 0, y: 0),
            opacity: descriptor.isHidden ? 0 : renderFloat(descriptor.opacity),
            bounds: NucleusRenderModel.Bounds(w: frameW, h: frameH),
            visualStyle: initialVisualStyle(descriptor),
            initialContent: lowerInitialContent(descriptor.initialContent)
        )
    }

    /// `.backdrop` carries the material role plus a rounded shape from the frame;
    /// `.host` carries the target context; everything else is a plain container.
    private static func lowerLayerKind(
        _ descriptor: NucleusLayers.LayerDescriptor,
        frameW: Float,
        frameH: Float,
        contextId: NucleusRenderModel.ContextID
    ) -> NucleusRenderModel.LayerKind {
        switch descriptor.kind {
        case .backdrop:
            let effect = descriptor.backdropMaterial
            let params = NucleusRenderModel.BackdropKindParams(
                materialRole: lowerBackdropMaterialRole(
                    contextId: contextId, material: effect.material),
                shape: .rrect(
                    rect: (0, 0, frameW, frameH),
                    radii: uniformRadii(renderFloat(effect.cornerRadius))
                )
            )
            return .backdrop(params)
        case .host:
            let target = descriptor.targetContextID?.rawValue ?? 0
            return .remoteHost(NucleusRenderModel.ContextID(raw: target))
        case .none, .container:
            return .container
        }
    }

    // MARK: - Property update

    /// Lowers every producer-side sparse property into its retained renderer
    /// counterpart, including default-action frame decomposition and resource
    /// content changes.
    private static func lowerPropertyUpdate(
        _ layer: NucleusLayers.LayerID,
        _ p: NucleusLayers.LayerPropertyUpdate,
        contextId: NucleusRenderModel.ContextID
    ) -> NucleusRenderModel.LayerPropertyUpdate {
        var update = NucleusRenderModel.LayerPropertyUpdate(nodeId: layer.rawValue)

        if let opacity = p.opacity {
            update.opacity = renderFloat(opacity)
        } else if let hidden = p.isHidden, hidden {
            update.opacity = 0
        }

        if let effect = p.backdropMaterial {
            let style = makeRenderVisualStyle(effect)
            update.backgroundColor = style.backgroundColor
            update.cornerRadii = style.cornerRadii
            update.backdropAttachment = .some(
                lowerBackdropAttachment(
                    contextId: contextId,
                    effect: effect,
                    groupId: p.backdropGroupID ?? 0,
                    frameWidth: renderFloat(p.bounds?.width ?? 0),
                    frameHeight: renderFloat(p.bounds?.height ?? 0)
                ))
        }
        update.backdropGroupID = p.backdropGroupID

        if let shadow = p.shadow {
            update.shadow = lowerShadowDelta(shadow)
        }

        let isDefaultAction = p.actionPolicy == .default
        update.usesDefaultOpacityAction =
            isDefaultAction && (p.opacity != nil || p.isHidden != nil)
        if let position = p.position, let bounds = p.bounds, isDefaultAction {
            let x = renderFloat(position.x)
            let y = renderFloat(position.y)
            let w = renderFloat(bounds.width)
            let h = renderFloat(bounds.height)
            update.frame = NucleusRenderModel.Frame(left: x, top: y, right: x + w, bottom: y + h)
            update.usesDefaultFrameAction = true
        } else {
            if let position = p.position {
                update.position = NucleusRenderModel.Point2D(
                    x: renderFloat(position.x), y: renderFloat(position.y))
            }
            if let bounds = p.bounds {
                update.bounds = NucleusRenderModel.Bounds(
                    w: renderFloat(bounds.width), h: renderFloat(bounds.height))
            }
        }

        if let anchor = p.anchorPoint {
            update.anchorPoint = NucleusRenderModel.Point2D(
                x: renderFloat(anchor.x), y: renderFloat(anchor.y))
        }
        if let transform = p.transform {
            update.transform = makeRenderTransform(transform)
        }
        if let scroll = p.scrollOffset {
            update.scrollOffset = NucleusRenderModel.Point2D(
                x: renderFloat(scroll.x), y: renderFloat(scroll.y))
        }
        update.foregroundVibrancy = p.foregroundVibrancy
        if let radii = p.cornerRadii {
            update.cornerRadii = (radii.tl, radii.tr, radii.br, radii.bl)
        }
        update.borderTop = p.borderTop
        update.borderRight = p.borderRight
        update.borderBottom = p.borderBottom
        update.borderLeft = p.borderLeft
        if let clipMutation = p.clip {
            switch clipMutation {
            case .set(let authoredClip):
                update.clip = .some(lowerClip(authoredClip))
            case .clear:
                update.clip = .some(nil)
            }
        }
        if let content = p.content {
            update.content = lowerContentDelta(content)
            update.contentDamage = p.contentDamage.map {
                NucleusRenderModel.RenderRect(
                    x: renderFloat($0.x),
                    y: renderFloat($0.y),
                    w: renderFloat($0.width),
                    h: renderFloat($0.height))
            }
        }
        if let sample = p.contentSample {
            update.contentSample = lowerContentSample(sample)
        }
        if let backgroundEffect = p.backgroundEffect {
            update.backgroundEffect = backgroundEffect
        }
        if let regions = p.backgroundEffectRegions {
            update.backgroundEffectRegions = lowerBackgroundEffectRegions(regions)
        }
        return update
    }

    // MARK: - Content

    /// A zero resource handle lowers to `.none`.
    private static func lowerInitialContent(_ content: NucleusLayers.LayerContent)
        -> NucleusRenderModel.InitialContent
    {
        switch content {
        case .paint(let content):
            return content.handle == 0
                ? .none : .paint(NucleusRenderModel.PaintContentHandle(raw: content.handle))
        case .external(let content):
            return content.handle == 0
                ? .none
                : .external(
                    NucleusRenderModel.IOSurfaceID(raw: UInt32(truncatingIfNeeded: content.handle)))
        case .snapshot(let content):
            return content.handle == 0
                ? .none : .snapshot(NucleusRenderModel.SnapshotHandle(raw: content.handle))
        case .none:
            return .none
        }
    }

    /// A zero resource handle lowers to `.none`.
    private static func lowerContentDelta(_ content: NucleusLayers.LayerContent)
        -> NucleusRenderModel.ContentDelta
    {
        switch content {
        case .none:
            return .none
        case .paint(let content):
            return content.handle == 0
                ? .none : .paint(NucleusRenderModel.PaintContentHandle(raw: content.handle))
        case .external(let content):
            return content.handle == 0
                ? .none
                : .external(
                    NucleusRenderModel.IOSurfaceID(raw: UInt32(truncatingIfNeeded: content.handle)))
        case .snapshot(let content):
            return content.handle == 0
                ? .none : .snapshot(NucleusRenderModel.SnapshotHandle(raw: content.handle))
        }
    }

    private static func lowerContentSample(_ s: NucleusLayers.ContentSample)
        -> NucleusRenderModel.ContentSample
    {
        NucleusRenderModel.ContentSample(
            sourceSurfaceId: s.sourceSurfaceID,
            srcOrigin: (s.srcX, s.srcY),
            srcSize: (s.srcWidth, s.srcHeight),
            logicalSize: NucleusRenderModel.Bounds(w: s.logicalWidth, h: s.logicalHeight),
            opaqueFullSurface: s.opaqueFullSurface
        )
    }

    private static func lowerBackgroundEffectRegions(
        _ regions: NucleusLayers.BackgroundEffectRegions
    )
        -> NucleusRenderModel.BackgroundEffectRegions
    {
        let maxRects = NucleusRenderModel.BackgroundEffectRegions.maxRects
        let count = min(regions.rects.count, maxRects)
        var rects = Array(repeating: NucleusRenderModel.BackgroundEffectRect(), count: maxRects)
        for i in 0..<count {
            let r = regions.rects[i]
            rects[i] = NucleusRenderModel.BackgroundEffectRect(
                x: r.x, y: r.y, w: r.width, h: r.height)
        }
        return NucleusRenderModel.BackgroundEffectRegions(
            rects: rects,
            count: UInt32(count),
            wholeSurface: regions.wholeSurface
        )
    }

    // MARK: - Shadow / visual style

    private static func initialVisualStyle(
        _ descriptor: NucleusLayers.LayerDescriptor
    ) -> NucleusRenderModel.VisualStyle? {
        var style: NucleusRenderModel.VisualStyle?
        if descriptor.backdropMaterial.material != .none {
            style = makeRenderVisualStyle(descriptor.backdropMaterial)
        }
        if case .set(let shadow) = lowerShadowDelta(descriptor.shadow) {
            var resolved = style ?? NucleusRenderModel.VisualStyle()
            resolved.shadow = shadow
            style = resolved
        }
        return style
    }

    /// CALayer-style effective alpha is opacity × color.a; a nonpositive result
    /// clears the renderer shadow so the decoration cache frees its texture.
    private static func lowerShadowDelta(_ shadow: NucleusLayers.Shadow)
        -> NucleusRenderModel.ShadowDelta
    {
        let effectiveAlpha = renderFloat(shadow.opacity * Double(shadow.color.a))
        if effectiveAlpha <= 0 { return .clear }
        return .set(
            NucleusRenderModel.LayerShadow(
                offsetX: renderFloat(shadow.offsetX),
                offsetY: renderFloat(shadow.offsetY),
                blurRadius: renderFloat(shadow.blurRadius),
                spreadRadius: 0,
                cornerRadius: renderFloat(shadow.cornerRadius),
                color: NucleusTypes.Color(
                    r: shadow.color.r,
                    g: shadow.color.g,
                    b: shadow.color.b,
                    a: effectiveAlpha)
            ))
    }

    /// The fill rounds to the same per-corner shape as the backdrop: explicit
    /// shape radii win over the uniform `cornerRadius`. Background fill is
    /// normalized black at the material opacity.
    private static func makeRenderVisualStyle(_ effect: NucleusLayers.BackdropMaterial)
        -> NucleusRenderModel.VisualStyle
    {
        let shapeRadii = lowerEffectShapeRadii(effect)
        let hasShapeRadii =
            shapeRadii.0 > 0 || shapeRadii.1 > 0 || shapeRadii.2 > 0 || shapeRadii.3 > 0
        let cornerRadii =
            hasShapeRadii ? shapeRadii : uniformRadii(renderFloat(effect.cornerRadius))
        return NucleusRenderModel.VisualStyle(
            backgroundColor: NucleusTypes.Color(0, 0, 0, renderFloat(effect.opacity)),
            cornerRadii: cornerRadii,
            shadow: nil
        )
    }

    // MARK: - Backdrop attachment

    /// Returns `nil` only when the authored material is `.none`. `.default` is
    /// a real catalog role and retains a backdrop attachment.
    private static func lowerBackdropAttachment(
        contextId: NucleusRenderModel.ContextID,
        effect: NucleusLayers.BackdropMaterial,
        groupId: UInt64,
        frameWidth: Float,
        frameHeight: Float
    ) -> NucleusRenderModel.BackdropAttachment? {
        if effect.material == .none { return nil }
        let role = lowerBackdropMaterialRole(contextId: contextId, material: effect.material)
        return NucleusRenderModel.BackdropAttachment(
            materialRole: role,
            blendingMode: effect.blendingMode,
            state: effect.state,
            appearance: effect.appearance,
            emphasized: effect.emphasized,
            mask: lowerBackdropMask(effect),
            shape: lowerEffectShape(effect, frameWidth: frameWidth, frameHeight: frameHeight),
            tint: effect.tint,
            opacity: renderFloat(effect.opacity),
            groupId: groupId
        )
    }

    /// `.default` derives from context: the shell-overlay slot maps to
    /// `.shellOverlay`; every other context maps to `.default`. `.none` has no
    /// renderer material role because it is lowered as an absent attachment.
    private static func lowerBackdropMaterialRole(
        contextId: NucleusRenderModel.ContextID,
        material: NucleusLayers.BackdropMaterialKind
    ) -> NucleusRenderModel.BackdropMaterialRole {
        switch material {
        case .sidebar: return .sidebar
        case .hudWindow: return .hudWindow
        case .menu: return .menu
        case .popover: return .popover
        case .titlebar: return .titlebar
        case .sheet: return .sheet
        case .headerView: return .headerView
        case .selection: return .selection
        case .underWindowBackground: return .underWindowBackground
        case .underPageBackground: return .underPageBackground
        case .fullScreenUi: return .fullScreenUI
        case .toolTip: return .toolTip
        case .windowBackground: return .windowBackground
        case .contentBackground: return .contentBackground
        case .shellOverlay: return .shellOverlay
        case .default:
            return contextId == NucleusRenderModel.shellOverlayContextId ? .shellOverlay : .default
        case .none:
            preconditionFailure("an absent backdrop material has no renderer role")
        }
    }

    private static func lowerBackdropMask(_ effect: NucleusLayers.BackdropMaterial)
        -> NucleusRenderModel.BackdropMask
    {
        switch effect.maskKind {
        case .roundedRect: return .roundedRect(renderFloat(effect.cornerRadius))
        case .image:
            return effect.maskImageHandle == 0
                ? .none : .image(NucleusRenderModel.SnapshotHandle(raw: effect.maskImageHandle))
        case .none: return .none
        }
    }

    /// A zero shape rect falls back to the frame
    /// rect; `.none` shape kind picks rrect when any radius is set, else rect.
    private static func lowerEffectShape(
        _ effect: NucleusLayers.BackdropMaterial,
        frameWidth: Float,
        frameHeight: Float
    ) -> NucleusRenderModel.EffectShape {
        let shapeRect = effect.shapeRect
        let rect: NucleusRenderModel.Float4 =
            (shapeRect.z > 0 && shapeRect.w > 0)
            ? (shapeRect.x, shapeRect.y, shapeRect.z, shapeRect.w)
            : (0, 0, frameWidth, frameHeight)
        let radii = lowerEffectShapeRadii(effect)
        switch effect.shapeKind {
        case .rect:
            return .rect(rect)
        case .rrect:
            return .rrect(rect: rect, radii: radii)
        case .none:
            if radii.0 > 0 || radii.1 > 0 || radii.2 > 0 || radii.3 > 0 {
                return .rrect(rect: rect, radii: radii)
            }
            return .rect(rect)
        }
    }

    /// The explicit per-corner shape radius
    /// run wins if any lane is positive; otherwise the uniform scalar `cornerRadius`
    /// (clamped to `>= 0`).
    private static func lowerEffectShapeRadii(_ effect: NucleusLayers.BackdropMaterial)
        -> NucleusRenderModel.Float4
    {
        let r = effect.shapeRadius
        if r.x > 0 || r.y > 0 || r.z > 0 || r.w > 0 {
            return (r.x, r.y, r.z, r.w)
        }
        return uniformRadii(max(0, renderFloat(effect.cornerRadius)))
    }

    // MARK: - Geometry

    private static func renderFloat(_ value: Double) -> Float {
        let narrowed = Float(value)
        precondition(
            value.isFinite && narrowed.isFinite,
            "render scalar must be finite and representable as Float"
        )
        return narrowed
    }

    private static func makeRenderTransform(
        _ t: NucleusLayers.GeometryTransform
    ) -> NucleusRenderModel.M44 {
        NucleusRenderModel.M44(m: [
            renderFloat(t.m00), renderFloat(t.m01), renderFloat(t.m02), renderFloat(t.m03),
            renderFloat(t.m10), renderFloat(t.m11), renderFloat(t.m12), renderFloat(t.m13),
            renderFloat(t.m20), renderFloat(t.m21), renderFloat(t.m22), renderFloat(t.m23),
            renderFloat(t.m30), renderFloat(t.m31), renderFloat(t.m32), renderFloat(t.m33),
        ])
    }

    /// A non-positive clip width or height lowers to no renderer clip.
    private static func lowerClip(
        _ value: NucleusLayers.ClipOp
    ) -> NucleusRenderModel.RenderClip? {
        if value.rect.z <= 0 || value.rect.w <= 0 { return nil }
        return NucleusRenderModel.RenderClip(
            rect: (value.rect.x, value.rect.y, value.rect.z, value.rect.w),
            radii: (value.radii.x, value.radii.y, value.radii.z, value.radii.w),
            antiAlias: value.antiAlias,
            transform: value.transform
        )
    }

    private static func uniformRadii(_ r: Float) -> NucleusRenderModel.Float4 {
        (r, r, r, r)
    }
}
