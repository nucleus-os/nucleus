// producer feed. Drives the real layers API with a RenderCommitSink
// installed and asserts the RetainedTreeStore tree + the lowered transaction the
// sink captures. Hardware-independent. One ordered @Test: the invariants share a
// Context/sink and assert a monotonic store revision, so they cannot be split
// (swift-testing runs @Test funcs in arbitrary order / in parallel).

import NucleusLayers
import NucleusRenderModel
import NucleusTypes
import Testing

@testable import NucleusRenderHost

@Suite struct RenderHostFeedTests {
    @MainActor
    private func makeSink(
        resourceHost: SwiftResourceHost = SwiftResourceHost(),
        requestFrame: @escaping @MainActor () -> Void = {}
    ) -> RenderCommitSink {
        RenderCommitSink(
            store: RetainedTreeStore(resourceHost: resourceHost),
            resourceHost: resourceHost,
            runtimeHost: .inMemory(),
            requestFrame: requestFrame)
    }

    @Test @MainActor func acceptedSceneCommitRequestsAFrame() throws {
        var requests = 0
        let sink = makeSink(requestFrame: { requests += 1 })
        let context = try NucleusLayers.Context(id: ContextID(rawValue: 901), commitSink: sink)
        var transaction = NucleusLayers.LayerTransaction(context: context)
        let layer = transaction.createLayer()
        try transaction.insert(layer)
        try transaction.commit()
        #expect(requests == 1)
        #expect(sink.store.hasPendingDamage)
    }

    @Test @MainActor func animationCompletionWaitsForTerminalPresentation() throws {
        let sink = makeSink()
        let store = sink.store
        let context = try NucleusLayers.Context(
            id: ContextID(rawValue: 902),
            commitSink: sink
        )
        var creation = NucleusLayers.LayerTransaction(context: context)
        let layer = creation.createLayer(.init(opacity: 1))
        try creation.insert(layer)
        try creation.commit()
        store.markPresented()

        var outcomes: [PresentationCompletionResult] = []
        let token = sink.runtimeHost.presentationCompletions.register {
            outcomes.append($0)
        }
        var transaction = NucleusLayers.LayerTransaction(
            context: context,
            predictedPresentationNanoseconds: 1_000_000_000,
            targetPresentationNanoseconds: 1_000_000_000
        )
        try transaction.setProperties(
            .init(opacity: 0),
            for: layer
        )
        try transaction.add(
            .scalar(
                keyPath: .opacity,
                from: 1,
                to: 0,
                duration: 1,
                curve: .linear,
                id: 55,
                completionToken: token.rawValue
            ),
            to: layer
        )
        try transaction.commit()

        #expect(store.hasActiveAnimations)
        #expect(store.snapshot().get(layer.id.rawValue)?.effectiveOpacity() == 1)
        #expect(outcomes.isEmpty)
        _ = store.tick(presentTimeNs: 1_500_000_000)
        let midpoint =
            store.snapshot().get(layer.id.rawValue)?.effectiveOpacity() ?? -1
        #expect(abs(midpoint - 0.5) < 0.001)
        store.markPresented()
        #expect(outcomes.isEmpty, "an in-flight sample is not terminal")

        _ = store.tick(presentTimeNs: 2_000_000_000)
        #expect(outcomes.isEmpty, "terminal evaluation still awaits presentation")
        store.markPresented()
        #expect(outcomes == [.completed])
        store.markPresented()
        #expect(outcomes == [.completed], "completion is exactly once")
    }

    @Test @MainActor func replacementAndRemovalReportDistinctOutcomes() throws {
        let sink = makeSink()
        let store = sink.store
        let context = try NucleusLayers.Context(
            id: ContextID(rawValue: 903),
            commitSink: sink
        )
        var creation = NucleusLayers.LayerTransaction(context: context)
        let layer = creation.createLayer()
        try creation.insert(layer)
        try creation.commit()
        store.markPresented()

        var firstOutcome: PresentationCompletionResult?
        let firstToken = sink.runtimeHost.presentationCompletions.register {
            firstOutcome = $0
        }
        var first = NucleusLayers.LayerTransaction(
            context: context,
            targetPresentationNanoseconds: 1_000_000_000
        )
        try first.add(
            .scalar(
                keyPath: .opacity,
                from: 0,
                to: 1,
                duration: 1,
                id: 1,
                completionToken: firstToken.rawValue
            ), to: layer)
        try first.commit()

        var secondOutcome: PresentationCompletionResult?
        let secondToken = sink.runtimeHost.presentationCompletions.register {
            secondOutcome = $0
        }
        var replacement = NucleusLayers.LayerTransaction(
            context: context,
            targetPresentationNanoseconds: 1_100_000_000
        )
        try replacement.add(
            .scalar(
                keyPath: .opacity,
                from: 0,
                to: 0.5,
                duration: 1,
                id: 2,
                completionToken: secondToken.rawValue
            ), to: layer)
        try replacement.commit()
        #expect(firstOutcome == nil)
        store.markPresented()
        #expect(firstOutcome == .superseded)

        var removal = NucleusLayers.LayerTransaction(context: context)
        try removal.removeAnimation(for: .opacity, from: layer)
        try removal.commit()
        #expect(secondOutcome == nil)
        store.markPresented()
        #expect(secondOutcome == .cancelled)
    }

    @Test @MainActor func everyProducerAnimationPathLowersOrIsExplicitlyRejected() throws {
        let sink = NucleusLayers.InMemoryCommitSink()
        let context = try NucleusLayers.Context(id: ContextID(rawValue: 905), commitSink: sink)
        var transaction = NucleusLayers.LayerTransaction(context: context)
        let layer = transaction.createLayer()

        for keyPath in NucleusTypes.LayerAnimationKeyPath.allCases {
            let animation: NucleusLayers.Animation
            if keyPath == .transform {
                animation = .transform(
                    from: .identity,
                    to: .translation(x: 10, y: 20),
                    duration: 1)
            } else {
                animation = .scalar(keyPath: keyPath, from: 0, to: 1, duration: 1)
            }
            try transaction.add(
                animation,
                to: layer
            )
            try transaction.removeAnimation(for: keyPath, from: layer)
        }
        try transaction.commit()

        let batch = try #require(sink.transactions.last)
        let lowered = RenderTransactionLowering.lower(batch)
        let expected = NucleusTypes.LayerAnimationKeyPath.allCases.compactMap {
            keyPath -> NucleusRenderModel.RenderAnimationKeyPath? in
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
            case .transform: .transform
            case .scrollOffsetX: .scrollOffsetX
            case .scrollOffsetY: .scrollOffsetY
            case .borderTopWidth, .borderRightWidth, .borderBottomWidth, .borderLeftWidth: nil
            }
        }

        #expect(lowered.animationsAdded.map(\.keyPath) == expected)
        #expect(lowered.animationsRemoved.map(\.keyPath) == expected)
    }

    @Test @MainActor func mismatchedAnimationEndpointsAreExplicitlyRejected() throws {
        let sink = NucleusLayers.InMemoryCommitSink()
        let context = try NucleusLayers.Context(id: ContextID(rawValue: 909), commitSink: sink)
        var transaction = NucleusLayers.LayerTransaction(context: context)
        let layer = transaction.createLayer()

        try transaction.add(
            NucleusLayers.Animation(
                keyPath: .opacity,
                duration: 1,
                from: .transform(.identity),
                to: .transform(.identity)),
            to: layer)
        try transaction.add(
            NucleusLayers.Animation(
                keyPath: .transform,
                duration: 1,
                from: .scalar(0),
                to: .scalar(1)),
            to: layer)
        try transaction.commit()

        let batch = try #require(sink.transactions.last)
        #expect(batch.animationsAdded.count == 2)
        #expect(RenderTransactionLowering.lower(batch).animationsAdded.isEmpty)
    }

    @Test @MainActor func geometryNarrowingPreservesTheAcceptedFloatBoundary() throws {
        let sink = NucleusLayers.InMemoryCommitSink()
        let context = try NucleusLayers.Context(id: ContextID(rawValue: 906), commitSink: sink)
        var transaction = NucleusLayers.LayerTransaction(context: context)
        let boundary = Double(Float.greatestFiniteMagnitude)
        _ = transaction.createLayer(
            NucleusLayers.LayerDescriptor(
                frame: NucleusLayers.GeometryRect(x: boundary, y: -boundary, width: 1, height: 2)
            )
        )
        try transaction.commit()

        let batch = try #require(sink.transactions.last)
        let created = try #require(RenderTransactionLowering.lower(batch).created.first)
        #expect(
            created.position == Point2D(x: .greatestFiniteMagnitude, y: -.greatestFiniteMagnitude))
        #expect(created.bounds == Bounds(w: 1, h: 2))
    }

    @Test @MainActor func backdropAttachmentIsRemovedByTheAbsentMaterial() throws {
        let sink = makeSink()
        let context = try NucleusLayers.Context(id: ContextID(rawValue: 907), commitSink: sink)
        var creation = NucleusLayers.LayerTransaction(context: context)
        let layer = creation.createLayer(
            NucleusLayers.LayerDescriptor(
                backdropMaterial: .popover,
                backdropGroupID: 42,
                shadow: NucleusLayers.Shadow(blurRadius: 5, opacity: 1))
        )
        try creation.insert(layer)
        try creation.commit()
        #expect(sink.store.snapshot().get(layer.id.rawValue)?.backdropAttachment != nil)
        #expect(sink.store.snapshot().get(layer.id.rawValue)?.backdropAttachment?.groupId == 42)

        let border = NucleusLayers.BorderEdge(
            width: 3,
            color: NucleusTypes.Color(1, 0, 0, 1))
        var borderUpdate = NucleusLayers.LayerTransaction(context: context)
        try borderUpdate.setProperties(
            NucleusLayers.LayerPropertyUpdate(borderTop: border),
            for: layer)
        try borderUpdate.commit()

        var materialUpdate = NucleusLayers.LayerTransaction(context: context)
        try materialUpdate.setProperties(
            NucleusLayers.LayerPropertyUpdate(backdropMaterial: .hudWindow),
            for: layer)
        try materialUpdate.commit()
        #expect(
            sink.store.snapshot().get(layer.id.rawValue)?.backdropAttachment?.materialRole
                == .hudWindow)
        #expect(sink.store.snapshot().get(layer.id.rawValue)?.backdropAttachment?.groupId == 42)
        #expect(
            sink.store.snapshot().get(layer.id.rawValue)?.model.visualStyle?.borderTop == border)
        #expect(sink.store.snapshot().get(layer.id.rawValue)?.model.visualStyle?.shadow != nil)

        var groupUpdate = NucleusLayers.LayerTransaction(context: context)
        try groupUpdate.setProperties(
            NucleusLayers.LayerPropertyUpdate(backdropGroupID: 99),
            for: layer)
        try groupUpdate.commit()
        #expect(sink.store.snapshot().get(layer.id.rawValue)?.backdropAttachment?.groupId == 99)

        var removal = NucleusLayers.LayerTransaction(context: context)
        try removal.setProperties(
            NucleusLayers.LayerPropertyUpdate(
                backdropMaterial: NucleusLayers.BackdropMaterial.none),
            for: layer
        )
        try removal.commit()
        #expect(sink.store.snapshot().get(layer.id.rawValue)?.backdropAttachment == nil)
    }

    @Test @MainActor func defaultBackdropMaterialIsNotAnAbsenceSentinel() throws {
        let sink = makeSink()
        let context = try NucleusLayers.Context(id: ContextID(rawValue: 910), commitSink: sink)
        var transaction = NucleusLayers.LayerTransaction(context: context)
        let layer = transaction.createLayer(
            NucleusLayers.LayerDescriptor(
                backdropMaterial: NucleusLayers.BackdropMaterial(
                    material: .default,
                    opacity: 1)))
        try transaction.insert(layer)
        try transaction.commit()

        let attachment = try #require(
            sink.store.snapshot().get(layer.id.rawValue)?.backdropAttachment)
        #expect(attachment.materialRole == .default)
    }

    @Test @MainActor func visibilityMutationsCarryTheirEffectiveOpacity() throws {
        let sink = makeSink()
        let context = try NucleusLayers.Context(id: ContextID(rawValue: 911), commitSink: sink)
        var creation = NucleusLayers.LayerTransaction(context: context)
        let layer = creation.createLayer(NucleusLayers.LayerDescriptor(opacity: 0.6))
        try creation.insert(layer)
        try creation.commit()

        var hide = NucleusLayers.LayerTransaction(context: context)
        try hide.setProperties(.init(isHidden: true, opacity: 0.9), for: layer)
        try hide.commit()
        #expect(layer.opacity == 0.9)
        #expect(layer.isHidden)
        #expect(sink.store.snapshot().get(layer.id.rawValue)?.model.properties.opacity == 0)

        var unhide = NucleusLayers.LayerTransaction(context: context)
        try unhide.setProperties(.init(isHidden: false), for: layer)
        try unhide.commit()
        #expect(!layer.isHidden)
        #expect(sink.store.snapshot().get(layer.id.rawValue)?.model.properties.opacity == 0.9)
    }

    @Test @MainActor func rendererAppliesItsBackgroundRegionLimitDuringLowering() throws {
        let sink = NucleusLayers.InMemoryCommitSink()
        let context = try NucleusLayers.Context(id: ContextID(rawValue: 908), commitSink: sink)
        var transaction = NucleusLayers.LayerTransaction(context: context)
        let layer = transaction.createLayer()
        let authored = (0..<10).map {
            NucleusLayers.BackgroundEffectRect(x: Float($0), width: 1, height: 1)
        }
        try transaction.setProperties(
            NucleusLayers.LayerPropertyUpdate(
                backgroundEffect: true,
                backgroundEffectRegions: NucleusLayers.BackgroundEffectRegions(rects: authored)
            ),
            for: layer
        )
        try transaction.commit()

        let batch = try #require(sink.transactions.last)
        #expect(batch.propertyUpdates[0].properties.backgroundEffectRegions?.rects.count == 10)
        let regions = try #require(
            RenderTransactionLowering.lower(batch).propertyUpdates.first?.backgroundEffectRegions
        )
        #expect(regions.count == 8)
        #expect(regions.rects[7].x == 7)

        var regionsOnly = NucleusLayers.LayerTransaction(context: context)
        try regionsOnly.setProperties(
            NucleusLayers.LayerPropertyUpdate(
                backgroundEffectRegions: NucleusLayers.BackgroundEffectRegions(
                    rects: [NucleusLayers.BackgroundEffectRect(x: 20, width: 2, height: 2)])),
            for: layer)
        try regionsOnly.commit()
        let regionsOnlyBatch = try #require(sink.transactions.last)
        let regionsOnlyUpdate = try #require(
            RenderTransactionLowering.lower(regionsOnlyBatch).propertyUpdates.first)
        #expect(regionsOnlyUpdate.backgroundEffect == nil)
        #expect(regionsOnlyUpdate.backgroundEffectRegions?.count == 1)
        #expect(regionsOnlyUpdate.backgroundEffectRegions?.rects[0].x == 20)
    }

    @Test @MainActor func defaultActionExpandsAtTheAuthoredMutation() throws {
        var table = ImplicitActionTable()
        table.replace([
            ImplicitActionRow(
                role: .notification,
                keyPath: .opacity,
                kind: .scalar,
                duration: 1,
                c1x: 0,
                c1y: 0,
                c2x: 1,
                c2y: 1
            )
        ])
        let resourceHost = SwiftResourceHost()
        resourceHost.replaceImplicitActions(table)
        let sink = makeSink(resourceHost: resourceHost)
        let store = sink.store
        let context = try NucleusLayers.Context(
            id: ContextID(rawValue: 904),
            commitSink: sink
        )
        var creation = NucleusLayers.LayerTransaction(context: context)
        let layer = creation.createLayer(
            .init(
                role: .notification,
                opacity: 1
            ))
        try creation.insert(layer)
        try creation.commit()
        store.markPresented()

        var animated = NucleusLayers.LayerTransaction(
            context: context,
            targetPresentationNanoseconds: 1_000_000_000
        )
        try animated.setProperties(
            .init(opacity: 0, actionPolicy: .default),
            for: layer
        )
        try animated.commit()

        #expect(store.hasActiveAnimations)
        #expect(store.snapshot().get(layer.id.rawValue)?.model.properties.opacity == 0)
        #expect(store.snapshot().get(layer.id.rawValue)?.effectiveOpacity() == 1)

        _ = store.tick(presentTimeNs: 1_500_000_000)
        let midpoint =
            store.snapshot().get(layer.id.rawValue)?.effectiveOpacity() ?? -1
        #expect(abs(midpoint - 0.5) < 0.001)
    }

    @Test @MainActor func layersToRenderFeed() throws {
        // The shell-overlay context so the .none/.default material role derives
        // .shellOverlay (matching the host's context-derived path).
        let sink = makeSink()
        let ctx = try NucleusLayers.Context(id: .shellOverlay, commitSink: sink)

        var nextIndex: UInt32 = 0
        func freshIndex() -> UInt32 {
            defer { nextIndex += 1 }
            return nextIndex
        }

        // Invariant 1 + 6: a container with a non-.none backdrop material →
        // populated backdropAttachment; the store revision + present-dirty advance.
        let popover = NucleusLayers.BackdropMaterial(
            material: .popover, blendingMode: .behindWindow, state: .active,
            appearance: .dark, cornerRadius: 18, opacity: 0.9,
            tint: NucleusTypes.Color(r: 0.1, g: 0.2, b: 0.3, a: 0.8))
        do {
            var t = NucleusLayers.LayerTransaction(context: ctx)
            let root = t.createLayer(
                NucleusLayers.LayerDescriptor(
                    kind: .container,
                    frame: NucleusLayers.GeometryRect(x: 0, y: 0, width: 200, height: 100),
                    opacity: 1, backdropMaterial: popover, backdropGroupID: 42,
                    shadow: NucleusLayers.Shadow(
                        blurRadius: 8, opacity: 0.5,
                        color: NucleusTypes.Color(0, 0, 0, 1))))
            try t.insert(root, into: nil, at: freshIndex())
            try t.commit()

            #expect(sink.store.revision == 1, "first-revision")
            #expect(sink.store.presentDirty, "first-dirty")
            #expect(sink.store.hasPendingDamage, "first-damage")
            #expect(
                sink.store.snapshot().roots(for: NucleusRenderModel.shellOverlayContextId) == [
                    root.id.rawValue
                ], "first-root")

            let node = sink.store.snapshot().get(root.id.rawValue)
            #expect(node != nil, "first-node-present")
            let attachment = node?.backdropAttachment
            #expect(attachment != nil, "backdrop-attachment-present")
            #expect(attachment?.materialRole == .popover, "backdrop-role")
            #expect(attachment?.blendingMode == .behindWindow, "backdrop-blend")
            #expect(attachment?.appearance == .dark, "backdrop-appearance")
            #expect(attachment?.groupId == 42, "backdrop-group")
            #expect(node?.model.visualStyle?.backgroundColor == NucleusTypes.Color(0, 0, 0, 0.9))
            let initialRadii = node?.model.visualStyle?.cornerRadii
            #expect(
                initialRadii?.0 == 18 && initialRadii?.1 == 18
                    && initialRadii?.2 == 18 && initialRadii?.3 == 18)
            #expect(node?.model.visualStyle?.shadow?.blurRadius == 8)
            #expect(node?.model.visualStyle?.shadow?.color.a == 0.5)
            if case .rrect(_, let radii)? = attachment?.shape {
                #expect(
                    radii.0 == 18 && radii.1 == 18 && radii.2 == 18 && radii.3 == 18,
                    "backdrop-rounded-shape")
            } else {
                #expect(Bool(false), "backdrop-rounded-shape")
            }
        }

        // Invariant 2: a created layer with .none material has nil attachment.
        var plainID: NucleusLayers.LayerID? = nil
        do {
            var t = NucleusLayers.LayerTransaction(context: ctx)
            let plain = t.createLayer(
                NucleusLayers.LayerDescriptor(
                    kind: .container,
                    frame: NucleusLayers.GeometryRect(x: 0, y: 0, width: 50, height: 50),
                    opacity: 1, backdropMaterial: .none))
            plainID = plain.id
            try t.insert(plain, into: nil, at: freshIndex())
            try t.commit()
            #expect(
                sink.store.snapshot().get(plain.id.rawValue)?.backdropAttachment == nil,
                "none-material-nil-attachment")
            #expect(sink.store.revision == 2, "second-revision")
        }

        // Invariant 3a: default-action position+bounds → compound frame write.
        do {
            var t = NucleusLayers.LayerTransaction(context: ctx)
            let layer = t.createLayer(NucleusLayers.LayerDescriptor(kind: .container))
            try t.insert(layer, into: nil, at: freshIndex())
            var update = NucleusLayers.LayerPropertyUpdate(actionPolicy: .default)
            update.position = NucleusLayers.GeometryPoint(x: 10.25, y: 20.5)
            update.bounds = NucleusLayers.GeometrySize(width: 300.75, height: 120.125)
            try t.setProperties(update, for: layer)
            try t.commit()

            let pu = sink.lastLowered?.propertyUpdates.first { $0.nodeId == layer.id.rawValue }
            #expect(
                pu?.frame
                    == NucleusRenderModel.Frame(
                        left: 10.25, top: 20.5, right: 311.0, bottom: 140.625),
                "default-action-compound-frame")
            #expect(pu?.position == nil, "default-action-no-position")
            #expect(pu?.bounds == nil, "default-action-no-bounds")

            let node = sink.store.snapshot().get(layer.id.rawValue)
            #expect(
                node?.model.properties.position == NucleusRenderModel.Point2D(x: 10.25, y: 20.5),
                "default-action-frame-position")
            #expect(
                node?.model.properties.bounds == NucleusRenderModel.Bounds(w: 300.75, h: 120.125),
                "default-action-frame-bounds")
        }

        // Invariant 3b: no-animation policy keeps separate position + bounds.
        do {
            var t = NucleusLayers.LayerTransaction(context: ctx)
            let layer = t.createLayer(NucleusLayers.LayerDescriptor(kind: .container))
            try t.insert(layer, into: nil, at: freshIndex())
            var update = NucleusLayers.LayerPropertyUpdate(actionPolicy: .none)
            update.position = NucleusLayers.GeometryPoint(x: 10.25, y: 20.5)
            update.bounds = NucleusLayers.GeometrySize(width: 300.75, height: 120.125)
            try t.setProperties(update, for: layer)
            try t.commit()

            let pu = sink.lastLowered?.propertyUpdates.first { $0.nodeId == layer.id.rawValue }
            #expect(pu?.frame == nil, "no-animation-no-frame")
            #expect(
                pu?.position == NucleusRenderModel.Point2D(x: 10.25, y: 20.5),
                "no-animation-position")
            #expect(
                pu?.bounds == NucleusRenderModel.Bounds(w: 300.75, h: 120.125),
                "no-animation-bounds")
        }

        // Shared style values and semantic enums survive lowering unchanged.
        do {
            var transaction = NucleusLayers.LayerTransaction(context: ctx)
            let layer = transaction.createLayer(
                NucleusLayers.LayerDescriptor(kind: .container))
            try transaction.insert(layer, into: nil, at: freshIndex())
            let border = NucleusLayers.BorderEdge(
                width: 2,
                color: NucleusTypes.Color(0.2, 0.4, 0.6, 0.8))
            try transaction.setProperties(
                NucleusLayers.LayerPropertyUpdate(
                    foregroundVibrancy: .dark,
                    clip: .set(
                        NucleusLayers.ClipOp(
                            rectX: 0, rectY: 0, rectW: 20, rectH: 10,
                            radiusTL: 1, radiusTR: 2, radiusBR: 3, radiusBL: 4,
                            antiAlias: true)),
                    cornerRadii: NucleusLayers.CornerRadii(tl: 1, tr: 2, br: 3, bl: 4),
                    borderTop: border),
                for: layer)
            try transaction.commit()

            let lowered = sink.lastLowered?.propertyUpdates.first {
                $0.nodeId == layer.id.rawValue
            }
            #expect(lowered?.foregroundVibrancy == .dark)
            #expect(
                lowered?.cornerRadii?.0 == 1 && lowered?.cornerRadii?.1 == 2
                    && lowered?.cornerRadii?.2 == 3 && lowered?.cornerRadii?.3 == 4)
            #expect(lowered?.borderTop == border)

            let retained = sink.store.snapshot().get(layer.id.rawValue)
            #expect(retained?.foregroundVibrancy == .dark)
            #expect(retained?.model.properties.clip != nil)
            let retainedRadii = retained?.model.visualStyle?.cornerRadii
            #expect(
                retainedRadii?.0 == 1 && retainedRadii?.1 == 2
                    && retainedRadii?.2 == 3 && retainedRadii?.3 == 4)
            #expect(retained?.model.visualStyle?.borderTop == border)

            var clear = NucleusLayers.LayerTransaction(context: ctx)
            try clear.setProperties(
                NucleusLayers.LayerPropertyUpdate(clip: .clear),
                for: layer)
            try clear.commit()
            #expect(
                sink.lastLowered?.propertyUpdates.first { $0.nodeId == layer.id.rawValue }?.clip
                    == .some(nil))
            #expect(sink.store.snapshot().get(layer.id.rawValue)?.model.properties.clip == nil)
        }

        // Invariant 4: content mapping (paint / external / snapshot / zero).
        func loweredContent(_ content: NucleusLayers.LayerContent) -> NucleusRenderModel
            .ContentDelta?
        {
            do {
                var t = NucleusLayers.LayerTransaction(context: ctx)
                let layer = t.createLayer(NucleusLayers.LayerDescriptor(kind: .container))
                try t.insert(layer, into: nil, at: freshIndex())
                try t.setProperties(NucleusLayers.LayerPropertyUpdate(content: content), for: layer)
                try t.commit()
                return sink.lastLowered?.propertyUpdates.first { $0.nodeId == layer.id.rawValue }?
                    .content
            } catch { return nil }
        }
        #expect(
            loweredContent(
                .paint(NucleusLayers.PaintContent(handle: 7, resourceHostHandle: 0)))
                == .paint(NucleusRenderModel.PaintContentHandle(raw: 7)), "content-paint")
        #expect(
            loweredContent(.external(NucleusLayers.IOSurfaceContent(handle: 5)))
                == .external(NucleusRenderModel.IOSurfaceID(raw: 5)), "content-external")
        #expect(
            loweredContent(
                .snapshot(NucleusLayers.SnapshotContent(handle: 9, resourceHostHandle: 0)))
                == .snapshot(NucleusRenderModel.SnapshotHandle(raw: 9)), "content-snapshot")
        #expect(
            loweredContent(
                .paint(NucleusLayers.PaintContent(handle: 0, resourceHostHandle: 0)))
                == ContentDelta.none, "content-zero-handle-none")

        // Invariant 5: a shadow with effective alpha <= 0 → CLEAR; otherwise SET.
        func loweredShadow(_ shadow: NucleusLayers.Shadow) -> NucleusRenderModel.ShadowDelta? {
            do {
                var t = NucleusLayers.LayerTransaction(context: ctx)
                let layer = t.createLayer(NucleusLayers.LayerDescriptor(kind: .container))
                try t.insert(layer, into: nil, at: freshIndex())
                try t.setProperties(NucleusLayers.LayerPropertyUpdate(shadow: shadow), for: layer)
                try t.commit()
                return sink.lastLowered?.propertyUpdates.first { $0.nodeId == layer.id.rawValue }?
                    .shadow
            } catch { return nil }
        }
        #expect(
            loweredShadow(
                NucleusLayers.Shadow(opacity: 0, color: NucleusTypes.Color(r: 0, g: 0, b: 0, a: 1)))
                == .clear, "shadow-zero-alpha-clear")
        if case .set(let s)? = loweredShadow(
            NucleusLayers.Shadow(
                blurRadius: 4, opacity: 0.5, color: NucleusTypes.Color(r: 0, g: 0, b: 0, a: 1)))
        {
            #expect(s.blurRadius == 4 && s.color.a == 0.5, "shadow-set")
        } else {
            #expect(Bool(false), "shadow-set")
        }

        // Invariant 6: removal folds through; revision + present-dirty advance.
        let revBefore = sink.store.revision
        let plain = try #require(plainID)
        let plainLayer = try #require(ctx.layers[plain])
        do {
            var t = NucleusLayers.LayerTransaction(context: ctx)
            try t.remove(plainLayer)
            try t.commit()
            #expect(sink.store.snapshot().get(plain.rawValue) == nil, "removed-gone")
            #expect(sink.store.revision == revBefore + 1, "remove-revision-advance")
            #expect(sink.store.presentDirty, "remove-dirty")
        }
    }
}
