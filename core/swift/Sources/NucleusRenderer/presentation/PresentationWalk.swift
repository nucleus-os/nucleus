// Phase 10b.4 front-half + 10b.4j — the live presentation tree walk that builds a
// complete FramePlan from the Phase 8 retained LayerTree. 10b.4j replaces the
// footprint-fill skeleton with the renderer-coupled emit walker
// (`PresentationPlanEmit`): descend the tree accumulating world matrix / clip /
// opacity (via `lowerLayerInput`), and per visible layer emit the real op
// vocabulary — a backdrop ExecSpec (pushing its group onto the foreground-
// vibrancy stack for descendants), the resolved content TextureQuad (carrying the
// rounded-clip mask, combined opacity, and a foreground-vibrancy reference to the
// nearest ancestor backdrop group), and a decoration shadow. Content texture
// handles are the content's own id within its role's space; the renderer resolves
// (role, handle) → GPU image at the frame (10b.4k).

import NucleusRenderModel

enum PresentationWalk {
    /// Walk `tree` from its roots and produce a complete FramePlan onto `target`.
    ///
    /// `lockContexts` is the session-lock security boundary at the single scanout
    /// choke point: when non-nil, the compositor is locked and only content whose
    /// owning context is in the set — the mapped ext-session-lock surfaces on this
    /// output — may reach the plan. An empty set blanks the output entirely. This is
    /// authority-independent: the overlay, wallpaper, cursor-layer, and every other
    /// window are suppressed regardless of which authority authored them, because
    /// they live outside the allowed lock contexts. The opaque ground is the frame's
    /// black clear (`FrameDriver`). `nil` is the normal, unlocked composition.
    static func buildFramePlan(
        tree: LayerTree, target: RenderTarget, frame: FrameInfo,
        rootContexts: [ContextID] = [compositorContextId],
        lockContexts: Set<ContextID>? = nil
    ) -> FramePlan {
        let plan = FramePlan()
        plan.reset(frame)
        var contextStack: [ContextID] = []
        for rootContext in rootContexts {
            guard !contextStack.contains(rootContext) else { continue }
            contextStack.append(rootContext)
            for rootId in tree.roots(for: rootContext) {
                walk(
                    tree, rootId, .identity, 1.0, .none, [], target, plan,
                    &contextStack, lockContexts
                )
            }
            _ = contextStack.popLast()
        }
        plan.cullOccludedOps()
        return plan
    }

    private static func walk(
        _ tree: LayerTree,
        _ layerId: UInt64,
        _ parentMatrix: M44,
        _ parentOpacity: Float,
        _ parentClip: ClipState,
        _ vibrancyStack: [UInt64],
        _ target: RenderTarget,
        _ plan: FramePlan,
        _ contextStack: inout [ContextID],
        _ lockContexts: Set<ContextID>?
    ) {
        guard let layer = tree.get(layerId) else { return }
        let layerOpacity = layer.effectiveOpacity()
        guard let input = lowerLayerInput(
            layerId: layerId, layer: layer, parentMatrix: parentMatrix,
            parentOpacity: parentOpacity, parentClip: parentClip, layerOpacity: layerOpacity
        ) else { return }

        if case .remoteHost(let targetContextId) = layer.kind {
            expandRemoteHost(
                tree, host: input, targetContextId: targetContextId,
                vibrancyStack: vibrancyStack, target: target, plan: plan,
                contextStack: &contextStack, lockContexts: lockContexts)
            return
        }

        // Session-lock content gate: the current context is the top of the stack (the
        // directly presented root context), so any content
        // authored directly into the root or a non-lock context is suppressed while
        // locked. Content inside an allowed lock context (entered through its host in
        // `expandRemoteHost`) still emits.
        let emitting = lockContexts.map { $0.contains(contextStack.last ?? compositorContextId) } ?? true

        if emitting {
            let footprint = computeLayerFootprint(LayerFootprintInput(
                layer: input.layer, bounds: input.bounds,
                layerRect: input.layerRect, clip: input.clip))
            if let rect = footprint.physicalDamageRect(target) {
                plan.recordLayerSnapshot(layerId, LayerFrameSnapshot(
                    rect: rect,
                    visualSignature: nativeLayerVisualSignature(input.layer, input.combinedOpacity),
                    compositeSignature: nativeLayerCompositeSignature(
                        input.layer,
                        input.combinedOpacity),
                    structural: input.layer.damage.flags.structure,
                    contentDamaged: input.layer.damage.flags.content,
                    localizedContentDamage: projectedContentDamage(
                        input,
                        target)))
            }
        }

        var childStack = vibrancyStack
        // Client blur protocols describe regions in surface-local logical units.
        // Lower them through the same world transform and clip as the surface
        // content so window chrome offsets, fractional scale, and animation cannot
        // leave the sampled background behind the client pixels.
        if emitting && layer.presentation.backgroundEffect {
            emitSurfaceBackgroundEffect(input, target, plan)
        }
        // Backdrop attachment: emit its blur band and become the active vibrancy
        // group for descendant content.
        if let attachment = layer.backdropAttachment {
            let groupId = attachment.groupId != 0 ? attachment.groupId : layerId
            if emitting { emitBackdrop(input, attachment, groupId, target, plan) }
            childStack.append(groupId)
        }

        if emitting {
            // The shadow decoration draws beneath the content.
            emitShadow(input, target, plan)
            // Background and borders draw above the shadow and below content.
            emitVisualStyle(input, target, plan)
            // Resolved content.
            emitContent(input, vibrancyStack, target, plan)
        }

        // Children compose against the scrolled matrix; this layer's own
        // content, drawn above, does not.
        let childMatrix = layerContentMatrix(input.worldMatrix, layer)
        for childId in layer.children {
            walk(tree, childId, childMatrix, input.combinedOpacity, input.clip, childStack, target, plan, &contextStack, lockContexts)
        }
    }

    private static func expandRemoteHost(
        _ tree: LayerTree,
        host input: LayerInput,
        targetContextId: ContextID,
        vibrancyStack: [UInt64],
        target: RenderTarget,
        plan: FramePlan,
        contextStack: inout [ContextID],
        lockContexts: Set<ContextID>?
    ) {
        guard targetContextId.raw != 0, !contextStack.contains(targetContextId) else { return }
        // Session-lock host gate: while locked, only follow hosts into allowed lock
        // contexts. A non-lock window's host is never expanded, so its whole subtree
        // is unreachable — the walk cannot compose it even in principle.
        if let lockContexts, !lockContexts.contains(targetContextId) { return }
        let roots = tree.roots(for: targetContextId)
        guard !roots.isEmpty else { return }

        contextStack.append(targetContextId)
        defer { _ = contextStack.popLast() }

        for rootId in roots {
            walk(
                tree, rootId, input.worldMatrix, input.combinedOpacity,
                input.clip, vibrancyStack, target, plan, &contextStack, lockContexts)
        }
    }

    /// The layer's visible footprint projected to target-physical pixels.
    private static func physicalRect(_ input: LayerInput, _ target: RenderTarget) -> PlanRect? {
        guard let visible = input.visibleRect, visible.width > 0, visible.height > 0 else { return nil }
        let frac = target.fractionalScale
        return PlanRect(
            x: Float(logicalToTargetPhysicalX(target, visible.x)),
            y: Float(logicalToTargetPhysicalY(target, visible.y)),
            w: Float(visible.width * frac),
            h: Float(visible.height * frac))
    }

    /// The rounded-clip mask for a layer's content (nil when no corner is rounded).
    private static func maskRRect(_ input: LayerInput, _ dst: PlanRect, _ target: RenderTarget) -> RRectMask? {
        let radii = input.layer.effectiveCornerRadii()
        if radii.0 == 0 && radii.1 == 0 && radii.2 == 0 && radii.3 == 0 { return nil }
        let s = Float(target.fractionalScale)
        return RRectMask(rect: dst, radii: (radii.0 * s, radii.1 * s, radii.2 * s, radii.3 * s))
    }

    /// Map the layer's content to a (role, texture handle); nil for `.none`.
    private static func contentTexture(_ content: LayerContent) -> (role: TextureQuadRole, handle: TextureHandle)? {
        switch content {
        case .none: return nil
        case .paint(let h): return (.paint, TextureHandle(raw: h.raw))
        case .external(let s): return (.content, TextureHandle(raw: UInt64(s.raw)))
        case .snapshot(let h): return (.snapshot, TextureHandle(raw: h.raw))
        }
    }

    /// The foreground-vibrancy reference for a content draw under `vibrancyStack`,
    /// or nil when the layer opts out or no ancestor backdrop group exists.
    private static func vibrancy(_ layer: Layer, _ vibrancyStack: [UInt64]) -> ForegroundVibrancy? {
        guard let group = vibrancyStack.last else { return nil }
        switch layer.foregroundVibrancy {
        case .none: return nil
        case .light: return ForegroundVibrancy(backdropGroupId: group, variant: .light)
        case .dark: return ForegroundVibrancy(backdropGroupId: group, variant: .dark)
        case .inherit: return ForegroundVibrancy(backdropGroupId: group, variant: .light)
        }
    }

    private static func emitContent(
        _ input: LayerInput, _ vibrancyStack: [UInt64], _ target: RenderTarget, _ plan: FramePlan
    ) {
        guard let content = contentTexture(input.layer.presentedContent()) else { return }
        let sample = input.layer.presentation.contentSample
        if sample.srcSize.0 > 0, sample.srcSize.1 > 0,
           sample.logicalSize.w > 0, sample.logicalSize.h > 0 {
            let kind: TextureContentKind = content.role == .content ? .waylandExternal : .compositorExternal
            var quad = lowerTextureQuad(target, input, TextureContent(
                texture: content.handle, kind: kind, role: content.role,
                srcOriginX: Double(sample.srcOrigin.0), srcOriginY: Double(sample.srcOrigin.1),
                srcWidth: Double(sample.srcSize.0), srcHeight: Double(sample.srcSize.1),
                logicalSize: sample.logicalSize,
                opaqueFullSurface: sample.opaqueFullSurface))
            if content.role == .paint {
                quad?.localPaintDamage = input.layer.damage.localContentRect
            }
            quad?.foregroundVibrancy = vibrancy(input.layer, vibrancyStack)
            if let quad { plan.appendTextureQuad(quad) }
            return
        }

        guard let dst = physicalRect(input, target) else { return }
        plan.appendTextureQuad(TextureQuad(
            layerId: input.layerId, role: content.role, texture: content.handle,
            dst: dst, src: PlanRect(x: 0, y: 0, w: 0, h: 0),
            alpha: input.combinedOpacity,
            maskRRect: maskRRect(input, dst, target),
            foregroundVibrancy: vibrancy(input.layer, vibrancyStack),
            localPaintDamage: content.role == .paint
                ? input.layer.damage.localContentRect
                : nil))
    }

    /// Project safe layer-local paint damage through the exact presentation
    /// transform and accumulated clip used by the content draw.
    private static func projectedContentDamage(
        _ input: LayerInput,
        _ target: RenderTarget
    ) -> PhysicalRect? {
        guard input.layer.damage.flags.content,
              let damage = input.layer.damage.localContentRect,
              damage.w > 0,
              damage.h > 0
        else {
            return nil
        }
        let left = max(0, damage.x)
        let top = max(0, damage.y)
        let right = min(input.bounds.w, damage.x + damage.w)
        let bottom = min(input.bounds.h, damage.y + damage.h)
        guard right > left, bottom > top else { return nil }
        let mapped = input.worldMatrix.mapRect(
            left,
            top,
            right - left,
            bottom - top)
        let logical = LogicalRect(
            x: Double(mapped.x),
            y: Double(mapped.y),
            width: Double(mapped.w),
            height: Double(mapped.h))
        guard let clipped = clipLayerRect(input.clip, logical) else {
            return nil
        }
        return physicalDamageRectFromLogicalRect(target, clipped)
    }

    private static func emitBackdrop(
        _ input: LayerInput, _ attachment: BackdropAttachment, _ groupId: UInt64,
        _ target: RenderTarget, _ plan: FramePlan
    ) {
        guard let region = physicalRect(input, target) else { return }
        let radii = input.layer.effectiveCornerRadii()
        let s = Float(target.fractionalScale)
        let shape: EffectShape = (radii.0 == 0 && radii.1 == 0 && radii.2 == 0 && radii.3 == 0)
            ? .rect((region.x, region.y, region.w, region.h))
            : .rrect(rect: (region.x, region.y, region.w, region.h),
                     radii: (radii.0 * s, radii.1 * s, radii.2 * s, radii.3 * s))
        plan.appendBackdropExecSpec(ExecSpec(
            layerId: input.layerId,
            groupId: groupId,
            blendingMode: attachment.blendingMode,
            region: region,
            shape: shape,
            mask: attachment.mask,
            tintRgba: (attachment.tint.r, attachment.tint.g, attachment.tint.b, attachment.tint.a),
            tintBlend: attachment.tint.a,
            alpha: attachment.opacity * input.combinedOpacity,
            foregroundVariant: attachment.appearance == .dark ? .dark : .light))
    }

    private static func emitSurfaceBackgroundEffect(
        _ input: LayerInput, _ target: RenderTarget, _ plan: FramePlan
    ) {
        let regions = input.layer.presentation.backgroundEffectRegions
        var localRects: [(Float, Float, Float, Float)] = []
        if regions.wholeSurface || regions.count == 0 {
            localRects.append((0, 0, input.bounds.w, input.bounds.h))
        } else {
            let count = min(Int(regions.count), regions.rects.count)
            localRects.reserveCapacity(count)
            for index in 0..<count {
                let rect = regions.rects[index]
                if rect.w > 0 && rect.h > 0 {
                    localRects.append((rect.x, rect.y, rect.w, rect.h))
                }
            }
        }

        let scale = target.fractionalScale
        for (index, local) in localRects.enumerated() {
            let mapped = input.worldMatrix.mapRect(local.0, local.1, local.2, local.3)
            let logical = LogicalRect(
                x: Double(mapped.x), y: Double(mapped.y),
                width: Double(mapped.w), height: Double(mapped.h))
            guard let visible = clipLayerRect(input.clip, logical),
                  visible.width > 0, visible.height > 0 else { continue }
            let physical = PlanRect(
                x: Float(logicalToTargetPhysicalX(target, visible.x)),
                y: Float(logicalToTargetPhysicalY(target, visible.y)),
                w: Float(visible.width * scale), h: Float(visible.height * scale))
            let effectLayerId = surfaceBackdropLayerId(
                input.layerId, .kdeSurface, UInt32(index))
            plan.appendBackdropExecSpec(ExecSpec(
                layerId: effectLayerId,
                groupId: effectLayerId,
                region: physical,
                shape: .rect((physical.x, physical.y, physical.w, physical.h)),
                mask: .none,
                alpha: input.combinedOpacity))
        }
    }

    private static func emitShadow(_ input: LayerInput, _ target: RenderTarget, _ plan: FramePlan) {
        guard let shadow = input.layer.model.visualStyle?.shadow,
              shadow.color.a > 0,
              let dst = physicalRect(input, target) else { return }
        let s = Float(target.fractionalScale)
        let spread = max(0, shadow.spreadRadius * s)
        let sigma = max(0, shadow.blurRadius * 0.5 * s)
        let padding = (3 * sigma).rounded(.up)
        let shapeWidth = max(1, dst.w + 2 * spread)
        let shapeHeight = max(1, dst.h + 2 * spread)
        let rasterWidth = max(1, Int32((shapeWidth + 2 * padding).rounded(.up)))
        let rasterHeight = max(1, Int32((shapeHeight + 2 * padding).rounded(.up)))
        let expanded = PlanRect(
            x: dst.x + shadow.offsetX * s - spread - padding,
            y: dst.y + shadow.offsetY * s - spread - padding,
            w: Float(rasterWidth), h: Float(rasterHeight))
        let styleRadii = input.layer.effectiveCornerRadii()
        let radii: Float4
        if shadow.cornerRadius > 0 {
            let r = max(0, shadow.cornerRadius * s + spread)
            radii = (r, r, r, r)
        } else {
            radii = (
                max(0, styleRadii.0 * s + spread), max(0, styleRadii.1 * s + spread),
                max(0, styleRadii.2 * s + spread), max(0, styleRadii.3 * s + spread))
        }
        plan.appendShadowQuad(ShadowQuad(
            texture: nil,
            material: ShadowMaterial(
                layerId: input.layerId, revision: input.layer.model.visualRevision,
                rasterWidth: rasterWidth, rasterHeight: rasterHeight,
                shapeRect: PlanRect(x: padding, y: padding, w: shapeWidth, h: shapeHeight),
                cornerRadii: radii, blurSigma: sigma, color: shadow.color),
            dst: expanded,
            src: PlanRect(x: 0, y: 0, w: Float(rasterWidth), h: Float(rasterHeight)),
            alpha: input.combinedOpacity))
    }

    private static func emitVisualStyle(
        _ input: LayerInput, _ target: RenderTarget, _ plan: FramePlan
    ) {
        guard let style = input.layer.model.visualStyle,
              let dst = physicalRect(input, target) else { return }
        let visible = style.backgroundColor.a > 0 ||
            (style.borderTop.width > 0 && style.borderTop.color.a > 0) ||
            (style.borderRight.width > 0 && style.borderRight.color.a > 0) ||
            (style.borderBottom.width > 0 && style.borderBottom.color.a > 0) ||
            (style.borderLeft.width > 0 && style.borderLeft.color.a > 0)
        guard visible else { return }
        let scale = Float(target.fractionalScale)
        let radii = input.layer.effectiveCornerRadii()
        plan.appendVisualStyle(VisualStyleQuad(
            dst: dst,
            backgroundColor: style.backgroundColor,
            borderWidths: (
                max(0, style.borderTop.width * scale),
                max(0, style.borderRight.width * scale),
                max(0, style.borderBottom.width * scale),
                max(0, style.borderLeft.width * scale)),
            borderTopColor: style.borderTop.color,
            borderRightColor: style.borderRight.color,
            borderBottomColor: style.borderBottom.color,
            borderLeftColor: style.borderLeft.color,
            cornerRadii: (
                max(0, radii.0 * scale), max(0, radii.1 * scale),
                max(0, radii.2 * scale), max(0, radii.3 * scale)),
            alpha: input.combinedOpacity))
    }
}
