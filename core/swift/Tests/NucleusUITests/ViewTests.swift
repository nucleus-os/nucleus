@_spi(NucleusCompositor) @testable import NucleusUI
import class NucleusLayers.Context
import struct NucleusLayers.ContextID
import struct NucleusLayers.GeometryPoint
import struct NucleusLayers.GeometryRect
import struct NucleusLayers.GeometrySize
import class NucleusLayers.InMemoryCommitSink
import struct NucleusLayers.LayerTransaction
import func NucleusLayers.installStubHost
import Testing

@MainActor
@Suite struct ViewTests {
    init() { installStubHost() }

    final class LayoutProbeView: View {
        var layoutCount = 0

        override func layout() {
            layoutCount += 1
        }
    }

    final class DrawingProbeView: View {
        var drawCount = 0

        override func draw(in context: GraphicsContext) {
            drawCount += 1
        }
    }

    @Test func windowDeinitReleasesRoot() throws {
        weak var weakRoot: View?
        do {
            let window = Window(title: "Root Owner")
            let root = View()
            weakRoot = root

            window.setRootView(root)
            #expect(weakRoot != nil)
        }

        #expect(weakRoot == nil)
    }

    @Test func parentDeinitReleasesAttachedChild() throws {
        weak var weakParent: View?
        weak var weakChild: View?
        do {
            let parent = View()
            let child = View()
            weakParent = parent
            weakChild = child

            parent.addSubview(child)
            #expect(weakParent != nil)
            #expect(weakChild != nil)
        }

        #expect(weakParent == nil)
        #expect(weakChild == nil)
    }

    @Test func removeFromSuperviewDetachesChild() throws {
        let parent = View()
        let child = View()

        parent.addSubview(child)
        child.removeFromSuperview()

        #expect(child.superview == nil)
        #expect(parent.subviews.isEmpty)
    }

    @Test func attachedViewTransferMovesSwiftOwnership() throws {
        let window = Window(title: "Owner")
        let root = View()
        let child = View()

        window.setRootView(root)
        root.addSubview(child)

        #expect(root.subviews.contains { $0 === child })
        #expect(window.root === root)
    }

    @Test func setFrameInvalidatesLayout() throws {
        let view = LayoutProbeView()
        #expect(!view.needsLayout)

        view.frame = (Rect(x: 10, y: 20, width: 30, height: 40))
        #expect(view.needsLayout)

        view.layoutIfNeeded()
        #expect(view.layoutCount == 1)
        #expect(!view.needsLayout)
    }

    @Test func displayInvalidationIsSeparateFromLayout() throws {
        let view = DrawingProbeView()
        #expect(view.needsDisplay)
        #expect(!view.needsLayout)

        view.displayIfNeeded()
        #expect(view.drawCount == 1)
        #expect(!view.needsDisplay)

        view.setNeedsDisplay(Rect(x: 2, y: 3, width: 4, height: 5))
        #expect(view.needsDisplay)
        #expect(!view.needsLayout)

        view.displayIfNeeded()
        #expect(view.drawCount == 2)
    }

    @Test func semanticViewStyleFeedsLayerContentWithoutPublicDrawCommands() throws {
        let view = DrawingProbeView()
        view.frame = Rect(x: 0, y: 0, width: 40, height: 20)
        view.backgroundColor = Color(0.1, 0.2, 0.3, 0.4)
        view.cornerRadius = 6
        view.border = Border(width: 2, color: Color(1, 1, 1, 0.5))

        view.displayIfNeeded()

        // The subclass draws nothing, so everything here comes from the style:
        // a rounded background and a stroked border. The border must request a
        // stroke — carrying only a strokeWidth made Skia fill it.
        let commands = view.layerContent.recording.commands
        #expect(commands.count == 2)
        #expect(commands[0].kind == .roundedRect)
        #expect(commands[0].w == 40)
        #expect(commands[0].h == 20)
        #expect(!commands[0].flags.contains(.stroke), "background fills")
        #expect(commands[1].strokeWidth == 2)
        #expect(commands[1].flags.contains(.stroke), "border strokes")
    }

    @Test func viewLayerPublicationMetadataFeedsRenderContent() throws {
        let view = View()
        let creation = Rect(x: 10, y: 20, width: 30, height: 40)
        view.layerPresentation = ViewLayerPresentation(
            role: .notification,
            backdropGroup: .notifications,
            actionPolicy: .default,
            creationFrame: creation,
            creationOpacity: 0.25
        )
        view.shadow = Shadow(opacity: 1)

        let content = view.layerContent
        #expect(content.presentation.role == .notification)
        #expect(content.presentation.backdropGroup == .notifications)
        #expect(content.presentation.actionPolicy == .default)
        #expect(content.presentation.creationFrame == creation)
        #expect(content.presentation.creationOpacity == 0.25)
        #expect(content.shadow == Shadow(opacity: 1))
    }

    @Test func viewLayerPublisherMaterializesBackingLayerIDsOutsideShellOverlay() throws {
        let semanticContext = try Context(id: ContextID(rawValue: 710), commitSink: InMemoryCommitSink())
        let visualSink = InMemoryCommitSink()
        let visualContext = try Context(id: ContextID(rawValue: 711), commitSink: visualSink)
        let root = Application.withContext(semanticContext) {
            let root = View()
            root.frame = Rect(x: 0, y: 0, width: 200, height: 100)

            let label = Label("Reusable publisher")
            label.frame = Rect(x: 12, y: 16, width: 120, height: 24)
            root.addSubview(label)
            return root
        }
        let label = try #require(root.subviews.first as? Label)
        let publisher = ViewLayerPublisher(context: visualContext)

        let published = try publisher.publish(roots: [root])
        #expect(published.map(\.rootLayerID) == [root.backingLayer.id.rawValue])

        let transaction = try #require(visualSink.transactions.first)
        let createdLayerIDs = Set(transaction.created.map(\.0))
        #expect(createdLayerIDs.contains(root.backingLayer.id))
        #expect(createdLayerIDs.contains(label.backingLayer.id))
        #expect(transaction.propertyUpdates.contains {
            $0.layer == label.backingLayer.id && $0.properties.content?.kind == .paint
        })
    }

    @Test func viewLayerPublisherConvertsBackdropGroupOnlyAtLayerBoundary() throws {
        let semanticContext = try Context(id: ContextID(rawValue: 726), commitSink: InMemoryCommitSink())
        let visualSink = InMemoryCommitSink()
        let visualContext = try Context(id: ContextID(rawValue: 727), commitSink: visualSink)
        let root = Application.withContext(semanticContext) {
            let root = View()
            root.frame = Rect(x: 0, y: 0, width: 160, height: 64)
            root.layerPresentation = ViewLayerPresentation(
                role: .notification,
                backdropGroup: .notifications,
                actionPolicy: .default
            )
            return root
        }
        let publisher = ViewLayerPublisher(context: visualContext)

        _ = try publisher.publish(roots: [root])

        let createTransaction = try #require(visualSink.transactions.first)
        let created = try #require(createTransaction.created.first { $0.0 == root.backingLayer.id }?.1)
        #expect(created.role == .notification)
        #expect(created.backdropGroupID == BackdropGroup.notifications.rawValue)

        root.layerPresentation = ViewLayerPresentation(backdropGroup: .hotkeyOverlay, actionPolicy: .explicit)
        _ = try publisher.publish(roots: [root])

        let update = try #require(visualSink.transactions.last?.propertyUpdates.first {
            $0.layer == root.backingLayer.id && $0.properties.backdropGroupID != nil
        }?.properties)
        #expect(update.backdropGroupID == BackdropGroup.hotkeyOverlay.rawValue)
        #expect(update.actionPolicy == .explicit)
    }

    @Test func windowLayerPublisherUsesCallerWindowSelectionPolicy() throws {
        let semanticContext = try Context(id: ContextID(rawValue: 712), commitSink: InMemoryCommitSink())
        let visualSink = InMemoryCommitSink()
        let visualContext = try Context(id: ContextID(rawValue: 713), commitSink: visualSink)
        let windows = Application.withContext(semanticContext) {
            let visible = Window(title: "Visible")
            let visibleRoot = Label("Visible root")
            visibleRoot.frame = Rect(x: 0, y: 0, width: 100, height: 20)
            visible.setContentView(visibleRoot)
            visible.orderFront()

            let filtered = Window(title: "Filtered")
            let filteredRoot = Label("Filtered root")
            filteredRoot.frame = Rect(x: 0, y: 24, width: 100, height: 20)
            filtered.setContentView(filteredRoot)
            filtered.orderFront()

            let hidden = Window(title: "Hidden")
            let hiddenRoot = Label("Hidden root")
            hiddenRoot.frame = Rect(x: 0, y: 48, width: 100, height: 20)
            hidden.setContentView(hiddenRoot)

            return (visible: visible, filtered: filtered, hidden: hidden)
        }
        let publisher = WindowLayerPublisher(context: visualContext)

        let published = try publisher.publish(
            windows: [windows.visible, windows.filtered, windows.hidden]
        ) { window in
            window.title == "Visible"
        }

        #expect(published.map(\.rootLayerID) == [try #require(windows.visible.root).backingLayer.id.rawValue])
        let transaction = try #require(visualSink.transactions.first)
        let createdLayerIDs = Set(transaction.created.map(\.0))
        #expect(createdLayerIDs.contains(try #require(windows.visible.root).backingLayer.id))
        #expect(!createdLayerIDs.contains(try #require(windows.filtered.root).backingLayer.id))
        #expect(!createdLayerIDs.contains(try #require(windows.hidden.root).backingLayer.id))
    }

    @Test func windowScenePublishesAndHitTestsOrderedWindows() throws {
        let semanticContext = try Context(id: ContextID(rawValue: 714), commitSink: InMemoryCommitSink())
        let visualSink = InMemoryCommitSink()
        let visualContext = try Context(id: ContextID(rawValue: 715), commitSink: visualSink)
        let windows = Application.withContext(semanticContext) {
            let back = Window(title: "Back")
            let backRoot = Label("Back")
            backRoot.frame = Rect(x: 0, y: 0, width: 100, height: 40)
            back.setContentView(backRoot)
            back.orderFront()

            let front = Window(title: "Front")
            let frontRoot = Label("Front")
            frontRoot.frame = Rect(x: 0, y: 0, width: 100, height: 40)
            front.setContentView(frontRoot)
            front.orderFront()

            return (back: back, front: front)
        }
        let scene = WindowScene(windows: [windows.back, windows.front], visualContext: visualContext)

        let hit = try #require(scene.hitTest(at: Point(x: 10, y: 10)))
        #expect(hit.window === windows.front)

        windows.front.orderOut()
        let revealedHit = try #require(scene.hitTest(at: Point(x: 10, y: 10)))
        #expect(revealedHit.window === windows.back)

        let published = try scene.publish { $0.title == "Back" }
        #expect(published.visualContent.map(\.rootLayerID) == [try #require(windows.back.root).backingLayer.id.rawValue])
    }

    @Test func windowSceneInterleavesEmbedderPlacementsByWindowLevel() throws {
        let semanticContext = try Context(id: ContextID(rawValue: 716), commitSink: InMemoryCommitSink())
        let visualSink = InMemoryCommitSink()
        let visualContext = try Context(id: ContextID(rawValue: 717), commitSink: visualSink)
        let windows = Application.withContext(semanticContext) {
            let window = Window(title: "Native")
            let root = Label("Native root")
            root.frame = Rect(x: 0, y: 0, width: 100, height: 20)
            window.setContentView(root)
            window.orderFront()

            let notification = Window(title: "Notification", role: .notification, level: .overlay)
            let notificationRoot = Label("Notification root")
            notificationRoot.frame = Rect(x: 0, y: 24, width: 100, height: 20)
            notification.setContentView(notificationRoot)
            notification.orderFront()
            return (window, notification)
        }
        let scene = WindowScene(windows: [windows.0, windows.1], visualContext: visualContext)

        let published = try scene.publishPlacing([
                ScenePlacement(id: 40, rootLayerID: 400, level: .shellChrome),
                ScenePlacement(id: 41, rootLayerID: 401, visible: false),
            ])

        // The id sequence states the interleaving directly: the placement sorts
        // between the two windows by level, and the invisible one is dropped.
        // A content-kind discriminant would say the same thing less precisely.
        #expect(published.visualContent.map(\.orderIndex) == [0, 1, 2])
        #expect(published.visualContent.map(\.id) == [
            try #require(windows.0.root).backingLayer.id.rawValue,
            40,
            try #require(windows.1.root).backingLayer.id.rawValue,
        ])
    }

    @Test func visualEffectViewStoresAppKitConfiguration() throws {
        let effect = VisualEffectView(
            material: .hudWindow,
            blendingMode: .withinWindow,
            state: .inactive,
            cornerRadius: -4,
            materialOpacity: 1.25
        )

        #expect(effect.material == .hudWindow)
        #expect(effect.blendingMode == .withinWindow)
        #expect(effect.state == .inactive)
        #expect(effect.cornerRadius == 0)
        #expect(effect.materialOpacity == 1)
        #expect(!effect.isAccessibilityElement)
        #expect(effect.properties.backdropMaterial?.material == .hudWindow)
        #expect(effect.properties.backdropMaterial?.state == .inactive)
        #expect(effect.properties.backdropMaterial?.blendingMode == .withinWindow)
        #expect(effect.backingLayer.descriptor.kind == .backdrop)

        effect.cornerRadius = 12
        effect.materialOpacity = 0.5
        #expect(effect.cornerRadius == 12)
        #expect(effect.materialOpacity == 0.5)
        #expect(effect.properties.backdropMaterial?.cornerRadius == 12)
        #expect(effect.properties.backdropMaterial?.opacity == 0.5)
        #expect(effect.needsLayout)
    }

    @Test func viewLayerPublisherPublishesVisualEffectAsSemanticBackdropLayer() throws {
        let semanticContext = try Context(id: ContextID(rawValue: 720), commitSink: InMemoryCommitSink())
        let visualSink = InMemoryCommitSink()
        let visualContext = try Context(id: ContextID(rawValue: 721), commitSink: visualSink)
        let root = Application.withContext(semanticContext) {
            let root = View()
            root.frame = Rect(x: 0, y: 0, width: 200, height: 100)

            let effect = VisualEffectView(material: .popover, cornerRadius: 18)
            effect.frame = Rect(x: 8, y: 10, width: 120, height: 44)
            root.addSubview(effect)
            return root
        }
        let effect = try #require(root.subviews.first as? VisualEffectView)
        let publisher = ViewLayerPublisher(context: visualContext)

        _ = try publisher.publish(roots: [root])

        let transaction = try #require(visualSink.transactions.first)
        let createdBackdrops = transaction.created.filter { $0.1.kind == .backdrop }
        #expect(createdBackdrops.map(\.0) == [effect.backingLayer.id])
        #expect(transaction.inserted.contains {
            $0.layer == effect.backingLayer.id && $0.parent == root.backingLayer.id
        })
        #expect(!transaction.created.contains {
            $0.0 != effect.backingLayer.id && $0.1.kind == .backdrop
        })
    }

    @Test func backingScaleFactorConvertsOnlyAtHostBoundaries() {
        let backingScaleFactor = BackingScaleFactor(1.5)
        let backingRect = Rect(x: 15, y: 30, width: 300, height: 150)
        let pointRect = backingScaleFactor.points(fromBackingPixels: backingRect)

        #expect(backingScaleFactor.backingPixelsPerPoint == 1.5)
        #expect(backingScaleFactor.singlePixelLength == 1.0 / 1.5)
        #expect(pointRect == Rect(x: 10, y: 20, width: 200, height: 100))
        #expect(backingScaleFactor.backingPixels(fromPoints: pointRect) == backingRect)
    }

    @Test func viewLayerPublisherKeepsPublicationMetricsInPointSpace() throws {
        let semanticContext = try Context(id: ContextID(rawValue: 722), commitSink: InMemoryCommitSink())
        let visualSink = InMemoryCommitSink()
        let visualContext = try Context(id: ContextID(rawValue: 723), commitSink: visualSink)
        let root = Application.withContext(semanticContext) {
            let root = View()
            root.frame = Rect(x: 10, y: 20, width: 200, height: 100)
            root.backgroundColor = Color(0.1, 0.2, 0.3, 0.4)
            root.cornerRadius = 12
            root.border = Border(width: 2, color: Color(1, 1, 1, 0.5))
            root.shadow = Shadow(offsetY: 6, blurRadius: 20, cornerRadius: 12, opacity: 0.35)

            let effect = VisualEffectView(material: .popover, cornerRadius: 18)
            effect.frame = Rect(x: 8, y: 10, width: 120, height: 44)
            effect.cornerRadius = 18
            root.addSubview(effect)

            let label = Label("Point space")
            label.frame = Rect(x: 12, y: 16, width: 140, height: 24)
            root.addSubview(label)
            return root
        }
        let effect = try #require(root.subviews.first as? VisualEffectView)
        let label = try #require(root.subviews.last as? Label)
        let publisher = ViewLayerPublisher(context: visualContext)

        _ = try publisher.publish(roots: [root])

        let transaction = try #require(visualSink.transactions.first)
        let rootDescriptor = try #require(transaction.created.first { $0.0 == root.backingLayer.id }?.1)
        let effectDescriptor = try #require(transaction.created.first { $0.0 == effect.backingLayer.id }?.1)
        let labelDescriptor = try #require(transaction.created.first { $0.0 == label.backingLayer.id }?.1)
        #expect(rootDescriptor.frame == GeometryRect(x: 10, y: 20, width: 200, height: 100))
        #expect(effectDescriptor.frame == GeometryRect(x: 8, y: 10, width: 120, height: 44))
        #expect(effectDescriptor.backdropMaterial.cornerRadius == 18)
        #expect(labelDescriptor.frame == GeometryRect(x: 12, y: 16, width: 140, height: 24))

        let rootUpdate = try #require(transaction.propertyUpdates.first { $0.layer == root.backingLayer.id }?.properties)
        let rootShadow = try #require(rootUpdate.shadow)
        #expect(rootUpdate.position == GeometryPoint(x: 10, y: 20))
        #expect(rootUpdate.bounds == GeometrySize(width: 200, height: 100))
        #expect(rootShadow.offsetY == 6)
        #expect(rootShadow.blurRadius == 20)
        #expect(rootShadow.cornerRadius == 12)

        #expect(!transaction.propertyUpdates.contains {
            $0.layer == effect.backingLayer.id && $0.properties.backdropMaterial != nil
        })
    }

    @Test func viewLayerPublisherPublishesShadowOnlyChangesAndClears() throws {
        let semanticContext = try Context(id: ContextID(rawValue: 724), commitSink: InMemoryCommitSink())
        let visualSink = InMemoryCommitSink()
        let visualContext = try Context(id: ContextID(rawValue: 725), commitSink: visualSink)
        let root = Application.withContext(semanticContext) {
            let root = View()
            root.frame = Rect(x: 0, y: 0, width: 120, height: 40)
            root.backgroundColor = Color(0.1, 0.2, 0.3, 1)
            root.shadow = Shadow(offsetY: 4, blurRadius: 10, cornerRadius: 6, opacity: 0.4)
            return root
        }
        let publisher = ViewLayerPublisher(context: visualContext)

        _ = try publisher.publish(roots: [root])
        let initialTransactionCount = visualSink.transactions.count

        root.shadow = Shadow(offsetY: 8, blurRadius: 18, cornerRadius: 6, opacity: 0.5)
        _ = try publisher.publish(roots: [root])

        #expect(visualSink.transactions.count == initialTransactionCount + 1)
        let shadowUpdate = try #require(visualSink.transactions.last?.propertyUpdates.first {
            $0.layer == root.backingLayer.id && $0.properties.shadow != nil
        }?.properties.shadow)
        #expect(shadowUpdate.offsetY == 8)
        #expect(shadowUpdate.blurRadius == 18)
        #expect(shadowUpdate.opacity == 0.5)

        root.shadow = .none
        _ = try publisher.publish(roots: [root])

        let clearUpdate = try #require(visualSink.transactions.last?.propertyUpdates.first {
            $0.layer == root.backingLayer.id && $0.properties.shadow != nil
        }?.properties.shadow)
        #expect(clearUpdate.opacity == 0)
    }
}
