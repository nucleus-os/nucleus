// The layers→render producer feed (Swift-direct).
//
// `RenderTransactionLowering` lowers a `NucleusLayers.EncodedTransaction` into a
// `NucleusRenderModel.Transaction` ready to fold into a `RetainedTreeStore`.
//
// Scope mirrors the retained-model `Transaction` boundary (see
// `RenderTransactionApply.swift`): only created/inserted/removed/detached/
// propertyUpdates are lowered. Animations, animation-removes, fences, and the
// renderer-owned presentation-transition expansion of layer `transitions`
// are excluded by design — they don't participate in the retained tree.
//
// The field mappings, the default-action compound-frame decomposition, the
// backdrop-attachment derivation, and the content/shadow/visual-style deltas
// cover create/insert/property-update. Numeric narrowing is `Float(_:)`.

import NucleusTypes
import NucleusLayers
import NucleusRenderModel

public enum RenderTransactionLowering {
    /// Lower one committed layers transaction into a render-model transaction
    /// (minus the commit-sink push, which the `RenderCommitSink` performs).
    public static func lower(_ encoded: NucleusLayers.EncodedTransaction) -> NucleusRenderModel.Transaction {
        let contextId = NucleusRenderModel.ContextID(raw: encoded.contextID.rawValue)
        var txn = NucleusRenderModel.Transaction(contextId: contextId)
        txn.revision = UInt64(encoded.revision)
        txn.groupId = encoded.groupID
        txn.groupSeq = encoded.groupSequence
        txn.completionToken = encoded.completionToken

        for (id, descriptor) in encoded.created {
            txn.created.append(lowerCreated(id, descriptor, contextId: contextId))
        }
        for entry in encoded.inserted {
            txn.inserted.append(NucleusRenderModel.LayerInserted(
                nodeId: entry.layer.rawValue,
                parentId: entry.parent?.rawValue ?? 0,
                index: entry.index
            ))
        }
        for id in encoded.removed {
            txn.removed.append(NucleusRenderModel.LayerRemoved(nodeId: id.rawValue))
        }
        for id in encoded.detached {
            txn.detached.append(NucleusRenderModel.LayerDetached(nodeId: id.rawValue))
        }
        for (layer, properties) in encoded.propertyUpdates {
            txn.propertyUpdates.append(lowerPropertyUpdate(layer, properties, contextId: contextId))
        }
        // Animations, animation-removes, fences, and the layers `transitions`
        // presentation-transition expansion are renderer-owned — excluded here.
        return txn
    }

    // MARK: - Created

    /// Mirrors `appendCreated`. The compound frame is decomposed into
    /// `position` + `bounds`; `anchorPoint` is fixed to (0, 0); the descriptor
    /// anchor is not read on create.
    private static func lowerCreated(
        _ id: NucleusLayers.LayerID,
        _ descriptor: NucleusLayers.LayerDescriptor,
        contextId: NucleusRenderModel.ContextID
    ) -> NucleusRenderModel.LayerCreated {
        let frame = descriptor.frame
        let frameW = Float(frame.width)
        let frameH = Float(frame.height)
        return NucleusRenderModel.LayerCreated(
            nodeId: id.rawValue,
            kind: layerKind(descriptor, frameW: frameW, frameH: frameH, contextId: contextId),
            role: layerRole(descriptor.role),
            backdropAttachment: backdropAttachmentFromWire(
                contextId: contextId,
                effect: descriptor.backdropMaterial,
                groupId: descriptor.backdropGroupID,
                frameWidth: frameW,
                frameHeight: frameH
            ),
            position: NucleusRenderModel.Point2D(x: Float(frame.x), y: Float(frame.y)),
            anchorPoint: NucleusRenderModel.Point2D(x: 0, y: 0),
            opacity: Float(descriptor.opacity),
            bounds: NucleusRenderModel.Bounds(w: frameW, h: frameH),
            initialContent: initialContent(descriptor.initialContent)
        )
    }

    /// Mirrors `layerKind`. `.backdrop` carries the material role + an rrect shape
    /// from the frame + uniform `cornerRadius`; `.host` carries the target context;
    /// everything else is a plain container.
    private static func layerKind(
        _ descriptor: NucleusLayers.LayerDescriptor,
        frameW: Float,
        frameH: Float,
        contextId: NucleusRenderModel.ContextID
    ) -> NucleusRenderModel.LayerKind {
        switch descriptor.kind {
        case .backdrop:
            let effect = descriptor.backdropMaterial
            let params = NucleusRenderModel.BackdropKindParams(
                materialRole: materialRoleFromWire(contextId: contextId, material: effect.material),
                shape: .rrect(
                    rect: (0, 0, frameW, frameH),
                    radii: uniformRadii(Float(effect.cornerRadius))
                )
            )
            return .backdrop(params)
        case .host:
            let target = descriptor.targetContextID?.rawValue ?? 0
            return .remoteHost(NucleusRenderModel.ContextID(raw: target))
        default:
            return .container
        }
    }

    private static func layerRole(_ role: NucleusLayers.LayerRole) -> NucleusRenderModel.LayerRole {
        switch role {
        case .windowRoot: return .windowRoot
        case .windowContentViewport: return .windowContentViewport
        case .notification: return .notification
        case .hotkeyOverlay: return .hotkeyOverlay
        case .wallpaper: return .wallpaper
        case .dock: return .dock
        case .generic: return .generic
        @unknown default: return .generic
        }
    }

    // MARK: - Property update

    /// Mirrors `appendPropertyUpdates`. Opacity/hidden, visual-effect (style +
    /// backdrop attachment), shadow, the default-action compound frame
    /// decomposition, anchor/transform/scroll/clip, content (+ generation reveal,
    /// dropped here as renderer-owned), content-sample, and background-effect.
    private static func lowerPropertyUpdate(
        _ layer: NucleusLayers.LayerID,
        _ p: NucleusLayers.LayerPropertyUpdate,
        contextId: NucleusRenderModel.ContextID
    ) -> NucleusRenderModel.LayerPropertyUpdate {
        var update = NucleusRenderModel.LayerPropertyUpdate(nodeId: layer.rawValue)

        if let opacity = p.opacity {
            update.opacity = Float(opacity)
        } else if let hidden = p.isHidden, hidden {
            update.opacity = 0
        }

        if let effect = p.backdropMaterial {
            update.visualStyle = .set(visualStyle(effect))
            update.backdropAttachment = .some(backdropAttachmentFromWire(
                contextId: contextId,
                effect: effect,
                groupId: p.backdropGroupID ?? 0,
                frameWidth: Float(p.bounds?.width ?? 0),
                frameHeight: Float(p.bounds?.height ?? 0)
            ))
        }

        if let shadow = p.shadow {
            update.shadow = shadowDelta(shadow)
        }

        let isDefaultAction = p.actionPolicy == .default
        if let position = p.position, let bounds = p.bounds, isDefaultAction {
            let x = Float(position.x)
            let y = Float(position.y)
            let w = Float(bounds.width)
            let h = Float(bounds.height)
            update.frame = NucleusRenderModel.Frame(left: x, top: y, right: x + w, bottom: y + h)
        } else {
            if let position = p.position {
                update.position = NucleusRenderModel.Point2D(x: Float(position.x), y: Float(position.y))
            }
            if let bounds = p.bounds {
                update.bounds = NucleusRenderModel.Bounds(w: Float(bounds.width), h: Float(bounds.height))
            }
        }

        if let anchor = p.anchorPoint {
            update.anchorPoint = NucleusRenderModel.Point2D(x: Float(anchor.x), y: Float(anchor.y))
        }
        if let transform = p.transform {
            update.transform = m44(transform)
        }
        if let scroll = p.scrollOffset {
            update.scrollOffset = NucleusRenderModel.Point2D(x: Float(scroll.x), y: Float(scroll.y))
        }
        if let c = p.clip, let lowered = clip(c) {
            // A degenerate clip (non-positive width/height) lowers to `nil`, which
            // leaves the field unchanged — so only emit a clip write
            // when the lowered clip is non-degenerate.
            update.clip = .some(lowered)
        }
        if let content = p.content {
            update.content = contentDelta(content)
        }
        if let sample = p.contentSample {
            update.contentSample = contentSample(sample)
        }
        if let backgroundEffect = p.backgroundEffect {
            update.backgroundEffect = backgroundEffect
            if let regions = p.backgroundEffectRegions {
                update.backgroundEffectRegions = backgroundEffectRegions(regions)
            }
        }
        return update
    }

    // MARK: - Content

    /// Mirrors `initialContent`. A zero handle in any content kind → `.none`.
    private static func initialContent(_ content: NucleusLayers.LayerContent) -> NucleusRenderModel.InitialContent {
        switch content.kind {
        case .paint:
            return content.handle == 0 ? .none : .paint(NucleusRenderModel.PaintContentHandle(raw: content.handle))
        case .external:
            return content.handle == 0 ? .none : .external(NucleusRenderModel.IOSurfaceID(raw: UInt32(truncatingIfNeeded: content.handle)))
        case .snapshot:
            return content.handle == 0 ? .none : .snapshot(NucleusRenderModel.SnapshotHandle(raw: content.handle))
        case .none:
            return .none
        @unknown default:
            return .none
        }
    }

    /// Mirrors `contentDelta`. A zero handle → `.none`; `.none` kind → `.none`.
    private static func contentDelta(_ content: NucleusLayers.LayerContent) -> NucleusRenderModel.ContentDelta {
        switch content.kind {
        case .none:
            return .none
        case .paint:
            return content.handle == 0 ? .none : .paint(NucleusRenderModel.PaintContentHandle(raw: content.handle))
        case .external:
            return content.handle == 0 ? .none : .external(NucleusRenderModel.IOSurfaceID(raw: UInt32(truncatingIfNeeded: content.handle)))
        case .snapshot:
            return content.handle == 0 ? .none : .snapshot(NucleusRenderModel.SnapshotHandle(raw: content.handle))
        @unknown default:
            return .none
        }
    }

    private static func contentSample(_ s: NucleusLayers.ContentSample) -> NucleusRenderModel.ContentSample {
        NucleusRenderModel.ContentSample(
            sourceSurfaceId: s.sourceSurfaceID,
            srcOrigin: (s.srcX, s.srcY),
            srcSize: (s.srcWidth, s.srcHeight),
            logicalSize: NucleusRenderModel.Bounds(w: s.logicalWidth, h: s.logicalHeight),
            opaqueFullSurface: s.opaqueFullSurface
        )
    }

    private static func backgroundEffectRegions(_ wire: NucleusLayers.BackgroundEffectRegions) -> NucleusRenderModel.BackgroundEffectRegions {
        let maxRects = NucleusRenderModel.BackgroundEffectRegions.maxRects
        let count = min(wire.rects.count, maxRects)
        var rects = Array(repeating: NucleusRenderModel.BackgroundEffectRect(), count: maxRects)
        for i in 0..<count {
            let r = wire.rects[i]
            rects[i] = NucleusRenderModel.BackgroundEffectRect(x: r.x, y: r.y, w: r.width, h: r.height)
        }
        return NucleusRenderModel.BackgroundEffectRegions(
            rects: rects,
            count: UInt32(count),
            wholeSurface: wire.wholeSurface
        )
    }

    // MARK: - Shadow / visual style

    /// Mirrors `shadowDelta`. CALayer-style effective alpha = opacity × color.a;
    /// `<= 0` lowers to a CLEAR so the decoration cache frees the texture.
    private static func shadowDelta(_ shadow: NucleusLayers.Shadow) -> NucleusRenderModel.ShadowDelta {
        let effectiveAlpha = Float(shadow.opacity * Double(shadow.color.a))
        if effectiveAlpha <= 0 { return .clear }
        return .set(NucleusRenderModel.LayerShadow(
            offsetX: Float(shadow.offsetX),
            offsetY: Float(shadow.offsetY),
            blurRadius: Float(shadow.blurRadius),
            spreadRadius: 0,
            cornerRadius: Float(shadow.cornerRadius),
            color: (shadow.color.r, shadow.color.g, shadow.color.b, effectiveAlpha)
        ))
    }

    /// Mirrors `visualStyleDelta`. The fill rounds to the same per-corner shape as
    /// the backdrop: prefer explicit per-corner shape radii, else the uniform
    /// scalar `cornerRadius`. Background fill is `(0, 0, 0, opacity)`.
    private static func visualStyle(_ effect: NucleusLayers.BackdropMaterial) -> NucleusRenderModel.VisualStyle {
        let shapeRadii = effectShapeRadiiFromWire(effect)
        let hasShapeRadii = shapeRadii.0 > 0 || shapeRadii.1 > 0 || shapeRadii.2 > 0 || shapeRadii.3 > 0
        let cornerRadii = hasShapeRadii ? shapeRadii : uniformRadii(Float(effect.cornerRadius))
        return NucleusRenderModel.VisualStyle(
            backgroundColor: (0, 0, 0, Float(effect.opacity)),
            cornerRadii: cornerRadii,
            shadow: nil
        )
    }

    // MARK: - Backdrop attachment

    /// Mirrors `backdropAttachmentFromWire`. `null` when the material is `.none`,
    /// or `.default` (which `materialRoleFromWire` maps to `.default`).
    private static func backdropAttachmentFromWire(
        contextId: NucleusRenderModel.ContextID,
        effect: NucleusLayers.BackdropMaterial,
        groupId: UInt64,
        frameWidth: Float,
        frameHeight: Float
    ) -> NucleusRenderModel.BackdropAttachment? {
        if effect.material == .none { return nil }
        let role = materialRoleFromWire(contextId: contextId, material: effect.material)
        if role == .default { return nil }
        return NucleusRenderModel.BackdropAttachment(
            materialRole: role,
            blendingMode: blendingModeFromWire(effect.blendingMode),
            state: backdropStateFromWire(effect.state),
            appearance: appearanceModeFromWire(effect.appearance),
            emphasized: effect.emphasized,
            mask: backdropMaskFromWire(effect),
            shape: effectShapeFromWire(effect, frameWidth: frameWidth, frameHeight: frameHeight),
            tint: (effect.tint.r, effect.tint.g, effect.tint.b, effect.tint.a),
            opacity: Float(effect.opacity),
            groupId: groupId
        )
    }

    /// Mirrors `materialRoleFromWire`. `.none`/`.default` derive from context (the
    /// shell-overlay slot maps to `.shellOverlay`; everything else to `.default`).
    private static func materialRoleFromWire(
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
        case .none, .default:
            return contextId == NucleusRenderModel.shellOverlayContextId ? .shellOverlay : .default
        @unknown default:
            return .default
        }
    }

    private static func blendingModeFromWire(_ mode: NucleusLayers.BackdropBlendingMode) -> NucleusRenderModel.BackdropBlendingMode {
        switch mode {
        case .withinWindow: return .withinWindow
        case .none, .behindWindow: return .behindWindow
        @unknown default: return .behindWindow
        }
    }

    private static func backdropStateFromWire(_ state: NucleusLayers.BackdropState) -> NucleusRenderModel.BackdropState {
        switch state {
        case .inactive: return .inactive
        case .followsWindowActiveState: return .followsWindowActive
        case .active: return .active
        @unknown default: return .active
        }
    }

    private static func appearanceModeFromWire(_ appearance: NucleusLayers.BackdropAppearance) -> NucleusRenderModel.AppearanceMode {
        switch appearance {
        case .light: return .light
        case .dark: return .dark
        case .auto: return .auto
        @unknown default: return .auto
        }
    }

    private static func backdropMaskFromWire(_ effect: NucleusLayers.BackdropMaterial) -> NucleusRenderModel.BackdropMask {
        switch effect.maskKind {
        case .roundedRect: return .roundedRect(Float(effect.cornerRadius))
        case .image: return effect.maskImageHandle == 0 ? .none : .image(NucleusRenderModel.SnapshotHandle(raw: effect.maskImageHandle))
        case .none: return .none
        @unknown default: return .none
        }
    }

    /// Mirrors `effectShapeFromWire`. A zero shape rect falls back to the frame
    /// rect; `.none` shape kind picks rrect when any radius is set, else rect.
    private static func effectShapeFromWire(
        _ effect: NucleusLayers.BackdropMaterial,
        frameWidth: Float,
        frameHeight: Float
    ) -> NucleusRenderModel.EffectShape {
        let shapeRect = effect.shapeRect
        let rect: NucleusRenderModel.Float4 = (shapeRect.z > 0 && shapeRect.w > 0)
            ? (shapeRect.x, shapeRect.y, shapeRect.z, shapeRect.w)
            : (0, 0, frameWidth, frameHeight)
        let radii = effectShapeRadiiFromWire(effect)
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
        @unknown default:
            return .rect(rect)
        }
    }

    /// Mirrors `effectShapeRadiiFromWire`. The explicit per-corner shape radius
    /// run wins if any lane is positive; otherwise the uniform scalar `cornerRadius`
    /// (clamped to `>= 0`).
    private static func effectShapeRadiiFromWire(_ effect: NucleusLayers.BackdropMaterial) -> NucleusRenderModel.Float4 {
        let r = effect.shapeRadius
        if r.x > 0 || r.y > 0 || r.z > 0 || r.w > 0 {
            return (r.x, r.y, r.z, r.w)
        }
        return uniformRadii(max(0, Float(effect.cornerRadius)))
    }

    // MARK: - Geometry

    private static func m44(_ t: NucleusLayers.GeometryTransform) -> NucleusRenderModel.M44 {
        NucleusRenderModel.M44(m: [
            Float(t.m00), Float(t.m01), Float(t.m02), Float(t.m03),
            Float(t.m10), Float(t.m11), Float(t.m12), Float(t.m13),
            Float(t.m20), Float(t.m21), Float(t.m22), Float(t.m23),
            Float(t.m30), Float(t.m31), Float(t.m32), Float(t.m33),
        ])
    }

    /// Mirrors `clip`. A non-positive clip rect width/height collapses to `nil`
    /// (no clip).
    private static func clip(_ value: NucleusLayers.ClipOp) -> NucleusRenderModel.ClipOp? {
        if value.rect.z <= 0 || value.rect.w <= 0 { return nil }
        return NucleusRenderModel.ClipOp(
            rect: (value.rect.x, value.rect.y, value.rect.z, value.rect.w),
            radii: (value.radii.x, value.radii.y, value.radii.z, value.radii.w),
            antiAlias: value.antiAlias,
            transform: [
                value.xform00, value.xform01, value.xform02,
                value.xform10, value.xform11, value.xform12,
                value.xform20, value.xform21, value.xform22,
            ]
        )
    }

    private static func uniformRadii(_ r: Float) -> NucleusRenderModel.Float4 {
        (r, r, r, r)
    }
}
