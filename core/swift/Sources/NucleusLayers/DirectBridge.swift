// Bridge extensions between Swift idiomatic layers types and the
// NucleusTypes wire types. Hand-
// maintained (the original DirectBridge.swift produced an equivalent
// shape against the now-deleted nucleus_* translate-c types).
//
// The `.wireValue` accessor and `init(wireValue:)` initializer names
// describe direct wire structs, not C ABI bridge values.

package import NucleusTypes

// Geometry (`GeometryPoint`/`GeometrySize`/`GeometryRect`) is now the wire
// type itself (see Geometry.swift); no adapter arm is needed.

// `BackdropMaterial` is `NucleusTypes.VisualEffect` itself (see
// BackdropMaterial.swift); no domain↔wire adapter is needed — the generated
// ergonomic accessors read the pinned wire layout directly.

// `Color` is `NucleusTypes.Color` itself (see PaintCommand.swift); no adapter.

// `BorderEdge` is `NucleusTypes.BorderEdge` itself (see BorderEdge.swift).

// `GeometryTransform` is `NucleusTypes.Transform` itself (see GeometryTransform.swift).

// `ClipOp` is `NucleusTypes.ClipOp` itself (see ClipOp.swift).

// MARK: - Shadow ↔ NucleusTypes.Shadow

extension Shadow {
    package var wireValue: NucleusTypes.Shadow {
        NucleusTypes.Shadow(
            offsetX: offsetX,
            offsetY: offsetY,
            blurRadius: blurRadius,
            cornerRadius: cornerRadius,
            opacity: opacity,
            color: color,
        )
    }

    package init(wireValue c: NucleusTypes.Shadow) {
        self.init(
            offsetX: c.offsetX,
            offsetY: c.offsetY,
            blurRadius: c.blurRadius,
            cornerRadius: c.cornerRadius,
            opacity: c.opacity,
            color: c.color,
        )
    }
}

// MARK: - LayerPropertyUpdate ↔ NucleusTypes.LayerPropertyUpdate

extension LayerPropertyUpdate {
    package var wireValue: NucleusTypes.LayerPropertyUpdate {
        let mask: UInt64 =
            (opacity != nil ? NucleusTypes.layerPropertyOpacity : 0) |
            (isHidden != nil ? NucleusTypes.layerPropertyHidden : 0) |
            (foregroundVibrancy != nil ? NucleusTypes.layerPropertyForegroundVibrancy : 0) |
            (backdropMaterial != nil ? NucleusTypes.layerPropertyVisualEffect : 0) |
            (shadow != nil ? NucleusTypes.layerPropertyShadow : 0) |
            (position != nil ? NucleusTypes.layerPropertyPosition : 0) |
            (bounds != nil ? NucleusTypes.layerPropertyBounds : 0) |
            (anchorPoint != nil ? NucleusTypes.layerPropertyAnchorPoint : 0) |
            (scrollOffset != nil ? NucleusTypes.layerPropertyScrollOffset : 0) |
            (transform != nil ? NucleusTypes.layerPropertyTransform : 0) |
            (clip != nil ? NucleusTypes.layerPropertyClip : 0) |
            (cornerRadii != nil ? NucleusTypes.layerPropertyCornerRadii : 0) |
            (borderTop != nil ? NucleusTypes.layerPropertyBorderTop : 0) |
            (borderRight != nil ? NucleusTypes.layerPropertyBorderRight : 0) |
            (borderBottom != nil ? NucleusTypes.layerPropertyBorderBottom : 0) |
            (borderLeft != nil ? NucleusTypes.layerPropertyBorderLeft : 0) |
            (content != nil ? NucleusTypes.layerPropertyContent : 0) |
            (backdropGroupID != nil ? NucleusTypes.layerPropertyBackdropGroup : 0) |
            (contentSample != nil ? NucleusTypes.layerPropertyContentSample : 0) |
            (backgroundEffect != nil ? NucleusTypes.layerPropertyBackgroundEffect : 0) |
            (contentDamage != nil ? NucleusTypes.layerPropertyContentDamage : 0)
        return NucleusTypes.LayerPropertyUpdate(
            mask: mask,
            opacity: opacity ?? 1,
            hidden: isHidden ?? false,
            actionPolicy: actionPolicy,
            foregroundVibrancy: foregroundVibrancy ?? .inherit,
            backgroundEffect: backgroundEffect ?? false,
            reserved2: 0,
            backdropGroupId: backdropGroupID ?? 0,
            visualEffect: backdropMaterial ?? .none,
            shadow: (shadow ?? .none).wireValue,
            position: position ?? .zero,
            bounds: bounds ?? .zero,
            anchorPoint: anchorPoint ?? .zero,
            scrollOffset: scrollOffset ?? .zero,
            transform: transform ?? .identity,
            clip: clip ?? ClipOp(rectX: 0, rectY: 0, rectW: 0, rectH: 0),
            cornerRadiusTl: (cornerRadii ?? CornerRadii.zero).tl,
            cornerRadiusTr: (cornerRadii ?? CornerRadii.zero).tr,
            cornerRadiusBr: (cornerRadii ?? CornerRadii.zero).br,
            cornerRadiusBl: (cornerRadii ?? CornerRadii.zero).bl,
            borderTop: borderTop ?? .none,
            borderRight: borderRight ?? .none,
            borderBottom: borderBottom ?? .none,
            borderLeft: borderLeft ?? .none,
            content: (content ?? .none).wireValue,
            contentSample: (contentSample ?? ContentSample()).wireValue,
            backgroundEffectRegions: (backgroundEffectRegions ?? BackgroundEffectRegions()).wireValue,
            contentDamage: contentDamage ?? .zero,
        )
    }

    package init(wireValue c: NucleusTypes.LayerPropertyUpdate) {
        self.init(
            isHidden: (c.mask & NucleusTypes.layerPropertyHidden) != 0 ? c.hidden : nil,
            opacity: (c.mask & NucleusTypes.layerPropertyOpacity) != 0 ? c.opacity : nil,
            backdropMaterial: (c.mask & NucleusTypes.layerPropertyVisualEffect) != 0 ? c.visualEffect : nil,
            backdropGroupID: (c.mask & NucleusTypes.layerPropertyBackdropGroup) != 0 ? c.backdropGroupId : nil,
            shadow: (c.mask & NucleusTypes.layerPropertyShadow) != 0 ? Shadow(wireValue: c.shadow) : nil,
            actionPolicy: c.actionPolicy,
            foregroundVibrancy: (c.mask & NucleusTypes.layerPropertyForegroundVibrancy) != 0 ? c.foregroundVibrancy : nil,
            position: (c.mask & NucleusTypes.layerPropertyPosition) != 0 ? c.position : nil,
            bounds: (c.mask & NucleusTypes.layerPropertyBounds) != 0 ? c.bounds : nil,
            anchorPoint: (c.mask & NucleusTypes.layerPropertyAnchorPoint) != 0 ? c.anchorPoint : nil,
            scrollOffset: (c.mask & NucleusTypes.layerPropertyScrollOffset) != 0 ? c.scrollOffset : nil,
            transform: (c.mask & NucleusTypes.layerPropertyTransform) != 0 ? c.transform : nil,
            clip: (c.mask & NucleusTypes.layerPropertyClip) != 0 ? c.clip : nil,
            cornerRadii: (c.mask & NucleusTypes.layerPropertyCornerRadii) != 0 ? CornerRadii(tl: c.cornerRadiusTl, tr: c.cornerRadiusTr, br: c.cornerRadiusBr, bl: c.cornerRadiusBl) : nil,
            borderTop: (c.mask & NucleusTypes.layerPropertyBorderTop) != 0 ? c.borderTop : nil,
            borderRight: (c.mask & NucleusTypes.layerPropertyBorderRight) != 0 ? c.borderRight : nil,
            borderBottom: (c.mask & NucleusTypes.layerPropertyBorderBottom) != 0 ? c.borderBottom : nil,
            borderLeft: (c.mask & NucleusTypes.layerPropertyBorderLeft) != 0 ? c.borderLeft : nil,
            content: (c.mask & NucleusTypes.layerPropertyContent) != 0 ? LayerContent(wireValue: c.content) : nil,
            contentDamage: (c.mask & NucleusTypes.layerPropertyContentDamage) != 0 ? c.contentDamage : nil,
            contentSample: (c.mask & NucleusTypes.layerPropertyContentSample) != 0 ? ContentSample(wireValue: c.contentSample) : nil,
            backgroundEffect: (c.mask & NucleusTypes.layerPropertyBackgroundEffect) != 0 ? c.backgroundEffect : nil,
            backgroundEffectRegions: (c.mask & NucleusTypes.layerPropertyBackgroundEffect) != 0 ? BackgroundEffectRegions(wireValue: c.backgroundEffectRegions) : nil,
        )
    }
}

// MARK: - BackgroundEffectRegions ↔ NucleusTypes.BackgroundEffectRegions

extension BackgroundEffectRegions {
    package var wireValue: NucleusTypes.BackgroundEffectRegions {
        func rect(_ index: Int) -> BackgroundEffectRect {
            index < rects.count ? rects[index] : BackgroundEffectRect()
        }
        let r0 = rect(0), r1 = rect(1), r2 = rect(2), r3 = rect(3)
        let r4 = rect(4), r5 = rect(5), r6 = rect(6), r7 = rect(7)
        return NucleusTypes.BackgroundEffectRegions(
            count: UInt32(min(rects.count, Self.maxRects)),
            wholeSurface: wholeSurface,
            reserved0: 0,
            reserved1: 0,
            rect0X: r0.x, rect0Y: r0.y, rect0W: r0.width, rect0H: r0.height,
            rect1X: r1.x, rect1Y: r1.y, rect1W: r1.width, rect1H: r1.height,
            rect2X: r2.x, rect2Y: r2.y, rect2W: r2.width, rect2H: r2.height,
            rect3X: r3.x, rect3Y: r3.y, rect3W: r3.width, rect3H: r3.height,
            rect4X: r4.x, rect4Y: r4.y, rect4W: r4.width, rect4H: r4.height,
            rect5X: r5.x, rect5Y: r5.y, rect5W: r5.width, rect5H: r5.height,
            rect6X: r6.x, rect6Y: r6.y, rect6W: r6.width, rect6H: r6.height,
            rect7X: r7.x, rect7Y: r7.y, rect7W: r7.width, rect7H: r7.height,
        )
    }

    package init(wireValue c: NucleusTypes.BackgroundEffectRegions) {
        let all = [
            BackgroundEffectRect(x: c.rect0X, y: c.rect0Y, width: c.rect0W, height: c.rect0H),
            BackgroundEffectRect(x: c.rect1X, y: c.rect1Y, width: c.rect1W, height: c.rect1H),
            BackgroundEffectRect(x: c.rect2X, y: c.rect2Y, width: c.rect2W, height: c.rect2H),
            BackgroundEffectRect(x: c.rect3X, y: c.rect3Y, width: c.rect3W, height: c.rect3H),
            BackgroundEffectRect(x: c.rect4X, y: c.rect4Y, width: c.rect4W, height: c.rect4H),
            BackgroundEffectRect(x: c.rect5X, y: c.rect5Y, width: c.rect5W, height: c.rect5H),
            BackgroundEffectRect(x: c.rect6X, y: c.rect6Y, width: c.rect6W, height: c.rect6H),
            BackgroundEffectRect(x: c.rect7X, y: c.rect7Y, width: c.rect7W, height: c.rect7H),
        ]
        self.init(rects: Array(all.prefix(Int(min(c.count, UInt32(Self.maxRects))))), wholeSurface: c.wholeSurface)
    }
}

// MARK: - ContentSample ↔ NucleusTypes.ContentSample

extension ContentSample {
    package var wireValue: NucleusTypes.ContentSample {
        NucleusTypes.ContentSample(
            sourceSurfaceId: sourceSurfaceID,
            srcX: srcX,
            srcY: srcY,
            srcW: srcWidth,
            srcH: srcHeight,
            logicalW: logicalWidth,
            logicalH: logicalHeight,
            opaqueFullSurface: opaqueFullSurface,
            reserved0: 0,
            reserved1: 0,
        )
    }

    package init(wireValue c: NucleusTypes.ContentSample) {
        self.init(
            sourceSurfaceID: c.sourceSurfaceId,
            srcX: c.srcX,
            srcY: c.srcY,
            srcWidth: c.srcW,
            srcHeight: c.srcH,
            logicalWidth: c.logicalW,
            logicalHeight: c.logicalH,
            opaqueFullSurface: c.opaqueFullSurface,
        )
    }
}

// `PaintCommand` is `NucleusTypes.PaintCommand` itself (see PaintCommand.swift);
// no adapter.

// `AnimationCurve` is `NucleusTypes.AnimationCurve` itself (see Animation.swift).

// `AnimationEndpoint` is `NucleusTypes.AnimationEndpoint` itself (see Animation.swift).

// MARK: - LayerContent ↔ NucleusTypes.LayerContent

extension LayerContent {
    package var wireValue: NucleusTypes.LayerContent {
        NucleusTypes.LayerContent(kind: kind, handle: handle)
    }

    package init(wireValue c: NucleusTypes.LayerContent) {
        self.init(
            kind: c.kind,
            handle: c.handle
        )
    }
}

// MARK: - Animation ↔ NucleusTypes.AnimationRecord

extension Animation {
    package func wireValue(layerID: LayerID) -> NucleusTypes.AnimationRecord {
        NucleusTypes.AnimationRecord(
            nodeId: layerID.rawValue,
            animationId: id,
            completionToken: completionToken,
            keyPath: keyPath,
            reserved: 0,
            duration: duration,
            fromEndpoint: fromEndpoint,
            toEndpoint: toEndpoint,
            curve: curve,
        )
    }
}
