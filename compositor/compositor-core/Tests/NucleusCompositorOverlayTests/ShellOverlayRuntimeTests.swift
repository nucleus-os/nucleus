@_spi(NucleusCompositor) import NucleusLayers
import NucleusCompositorOverlayTypes
@_spi(NucleusCompositor) import NucleusUI
@testable import NucleusCompositorOverlay
import Testing

// Behavioral coverage for the shell overlay runtime (ShellOverlayScene /
// ShellOverlayController and their hotkey + notification views). The suite runs
// headless: each scene is driven through an injected `InMemoryCommitSink`, so
// assertions read the real encoded transactions with no C round-trip. Views live
// in the in-memory root context; publishing flushes them into the shellOverlay
// wire context.
//
// The overlay's published visual-content *shape* (`PublishedVisualContent`
// fields) is core publish behavior owned by the render/UI core and tested there;
// here we assert what the compositor observably owns — scene/window structure,
// the hotkey + notification view trees, notification lifecycle + publish pacing,
// hosted-surface tracking, and input hit-testing — through the public/@_spi
// contract plus this package's own `@testable` internals.
@MainActor
@Suite struct ShellOverlayRuntimeTests {
    init() { installStubHost() }

    final class ManualClock: @unchecked Sendable {
        var now: UInt64

        init(_ now: UInt64) {
            self.now = now
        }
    }

    @Test func controllerReflectsFrameNotificationAndOverlayState() throws {
        let sink = InMemoryCommitSink()
        let scene = try ShellOverlayScene(frame: nil, commitSink: sink)
        let controller = ShellOverlayController(scene: scene) { _ in }

        controller.beginFrame(.init(
            outputWidth: 1920,
            outputHeight: 1080,
            devicePixelRatio: 2,
            overlayRegionX: 10,
            overlayRegionY: 20,
            overlayRegionW: 900,
            overlayRegionH: 700
        ))
        #expect(scene.hotkeyVisible)
        #expect(scene.frame?.outputWidth == 1920)
        #expect(scene.frame?.overlayRegionX == 10)

        // Re-showing a notification with the same id updates it in place (latest
        // thumbnail wins) rather than stacking a duplicate.
        controller.showNotification(.init(
            id: 42,
            appName: "Terminal",
            summary: "Build complete",
            body: "nucleus-compositor finished",
            thumbnailHandle: 77,
            showsThumbnail: true,
            expireTimeoutMs: 5000
        ))
        controller.showNotification(.init(
            id: 42,
            appName: "Terminal",
            summary: "Build complete",
            body: "nucleus-compositor finished",
            thumbnailHandle: 99,
            showsThumbnail: true,
            expireTimeoutMs: 5000
        ))

        #expect(scene.notifications.count == 1)
        #expect(scene.notifications[0].appName == "Terminal")
        #expect(scene.notifications[0].summary == "Build complete")
        #expect(scene.notifications[0].thumbnailHandle == 99)
        #expect(scene.notifications[0].showsThumbnail)
        #expect(scene.notificationViews.count == 1)
        #expect(scene.notificationViews[0].summaryLabel.text == "Build complete")
        #expect(scene.notificationViews[0].bodyLabel.text == "nucleus-compositor finished")
        #expect(scene.notificationViews[0].thumbnailView.image?.id == 99)
        #expect(scene.notificationViews[0].backgroundEffectView.material == .popover)
        #expect(scene.notificationViews[0].accessibilityRole == .window)
        #expect(scene.notificationViews[0].closeButton.accessibilityRole == .button)

        // Window structure: the notification and hotkey overlays are hosted in
        // their own windows at the expected roles/levels, each showing its view.
        #expect(scene.notificationWindow.role == .notification)
        #expect(scene.notificationWindow.level == .overlay)
        #expect(scene.notificationWindow.contentView === scene.notificationListView)
        #expect(scene.notificationWindow.isVisible)
        #expect(scene.notificationListView.nextResponder === scene.notificationViewController)
        #expect(scene.hotkeyWindow.role == .statusOverlay)
        #expect(scene.hotkeyWindow.level == .criticalOverlay)
        #expect(scene.hotkeyWindow.contentView === scene.hotkeyView)
        #expect(scene.hotkeyWindow.isVisible)
        #expect(scene.hotkeyView.nextResponder === scene.hotkeyViewController)

        // Hotkey overlay: visible by default, one row per non-empty keybinding.
        #expect(scene.hotkeyVisible)
        #expect(scene.hotkeyView.visible)
        #expect(scene.hotkeyView.backgroundEffectView.material == .hudWindow)
        #expect(scene.hotkeyView.isHidden == false)
        #expect(scene.hotkeyView.rowViews.count == 11)
        #expect(scene.hotkeyView.rowViews.first?.keyLabel.text == "Super + T")
        #expect(scene.hotkeyView.rowViews.first?.descriptionLabel.text == "Launch Kitty")

        let publication = scene.publishVisuals()
        #expect(!(publication?.scene.visualContent.isEmpty ?? true))

        // Hiding the hotkey overlay still leaves visible content (the notification).
        controller.setHotkeyVisible(false)
        let hiddenPublication = scene.publishVisuals()
        #expect(!scene.hotkeyVisible)
        #expect(!scene.hotkeyView.visible)
        #expect(scene.hotkeyView.isHidden == true)
        #expect(!(hiddenPublication?.scene.visualContent.isEmpty ?? true))
        #expect(scene.notificationPublicationDeadlineNs != nil)

        #expect(!sink.transactions.isEmpty)
        #expect(sink.transactions.allSatisfy { $0.contextID == .shellOverlay })
    }

    @Test func hostedShellSurfacesUseShellChromeLevelBelowNativeOverlays() throws {
        let scene = try ShellOverlayScene(frame: nil, commitSink: InMemoryCommitSink())
        let surface = try scene.hostedSurface(for: "topbar")
        var insertionIndex: UInt32?
        try scene.attachHostedSurface(for: "topbar") { _, _, _, observedIndex in
            insertionIndex = observedIndex
        }

        // The shell-chrome level places hosted shell surfaces below native overlays;
        // its observable manifestation is insertion at the back-most index (0).
        #expect(scene.hostedSurfaces.contains { $0.surfaceID == surface.surfaceID })
        #expect(insertionIndex == 0)
    }

    private static func input(
        _ kind: ShellOverlayInputKind,
        x: Float,
        y: Float,
        button: UInt32 = 272
    ) -> NucleusCompositorOverlayTypes.InputEvent {
        .init(
            kind: NucleusCompositorOverlayTypes.InputKind(rawValue: kind.rawValue) ?? .pointerMove,
            button: button,
            x: x,
            y: y,
            scrollX: 0,
            scrollY: 0,
            keycode: 0,
            modifiers: 0,
            timestampNs: 0
        )
    }

    private static func frame(
        pointWidth: Float = 800,
        pointHeight: Float = 600,
        backingScale: Float
    ) -> ShellOverlayFrameInfo {
        ShellOverlayFrameInfo(
            outputWidth: UInt32((pointWidth * backingScale).rounded(.up)),
            outputHeight: UInt32((pointHeight * backingScale).rounded(.up)),
            devicePixelRatio: backingScale,
            overlayRegionX: 0,
            overlayRegionY: 0,
            overlayRegionW: pointWidth * backingScale,
            overlayRegionH: pointHeight * backingScale
        )
    }

    private static func hotkeyFrame(backingScale: Float) throws -> (x: Double, y: Double, width: Double, height: Double) {
        let hotkeyView = try ShellOverlayHotkeyView()
        try hotkeyView.updateFrame(Self.frame(backingScale: backingScale))
        let frame = hotkeyView.frame
        return (frame.origin.x, frame.origin.y, frame.size.width, frame.size.height)
    }

    private static func notificationFrame(backingScale: Float) throws -> (x: Double, y: Double, width: Double, height: Double) {
        let notification = try ShellOverlayNotificationView(info: .init(
            id: 12,
            appName: "Nucleus",
            summary: "Build complete",
            body: "nucleus-compositor finished",
            thumbnailHandle: 0,
            showsThumbnail: false,
            expireTimeoutMs: 5000
        ))
        let list = try ShellOverlayNotificationListView()
        list.frameInfo = Self.frame(backingScale: backingScale)
        try list.setNotifications([notification])
        try list.layoutIfNeeded()
        let frame = notification.frame
        return (frame.origin.x, frame.origin.y, frame.size.width, frame.size.height)
    }

    private static func nearlyEqual(_ lhs: Double, _ rhs: Double, tolerance: Double = 0.001) -> Bool {
        abs(lhs - rhs) <= tolerance
    }

    @Test func hotkeyOverlayUsesTextLayoutBaselinesAndSemanticStyleViews() throws {
        let sink = InMemoryCommitSink()
        let scene = try ShellOverlayScene(frame: .init(
            outputWidth: 1920,
            outputHeight: 1080,
            devicePixelRatio: 1,
            overlayRegionX: 0,
            overlayRegionY: 0,
            overlayRegionW: 1920,
            overlayRegionH: 1080
        ), commitSink: sink)

        try scene.hotkeyView.layoutIfNeeded()
        try scene.hotkeyView.displayIfNeeded()

        let row = try #require(scene.hotkeyView.rowViews.first)
        // Rows size their labels to the laid-out text height (taller than the raw
        // font size) and place them on a baseline inside the label frame.
        #expect(row.keyLabel.frame.size.height > Double(row.keyLabel.fontSize))
        #expect(row.descriptionLabel.frame.size.height > Double(row.descriptionLabel.fontSize))

        let keyBaseline = row.keyLabel.frame.origin.y + row.keyLabel.firstBaselineOffsetFromTop
        #expect(keyBaseline > row.keyLabel.frame.origin.y)
        #expect(keyBaseline < row.keyLabel.frame.origin.y + row.keyLabel.frame.size.height)

        // The container itself paints no content; its separator is a filled rect.
        #expect(scene.hotkeyView.layerContent.recording.isEmpty)
        #expect(scene.hotkeyView.separatorView.layerContent.recording.commands.first?.kind == .rect)
    }

    @Test func notificationLabelsUseTextLayoutHeights() throws {
        let notification = try ShellOverlayNotificationView(info: .init(
            id: 12,
            appName: "Nucleus",
            summary: "Build complete",
            body: "nucleus-compositor finished",
            thumbnailHandle: 0,
            showsThumbnail: false,
            expireTimeoutMs: 5000
        ))
        notification.frame = Rect(
            x: 0,
            y: 0,
            width: Double(notification.metrics.cardW),
            height: Double(notification.metrics.cardH)
        )

        try notification.layoutIfNeeded()
        try notification.summaryLabel.displayIfNeeded()
        try notification.bodyLabel.displayIfNeeded()

        #expect(notification.summaryLabel.frame.size.height > Double(notification.summaryLabel.fontSize))
        #expect(notification.bodyLabel.frame.size.height > Double(notification.bodyLabel.fontSize))
        #expect(notification.metrics.cardH >= notification.metrics.cardPad * 2 + notification.metrics.textHeight(hasBody: true))
        #expect(notification.summaryLabel.layerContent.recording.commands.first?.kind == .textLayout)
        #expect(notification.summaryLabel.layerContent.recording.commands.first?.h == Float(notification.summaryLabel.frame.size.height))
        #expect(notification.bodyLabel.layerContent.recording.commands.first?.h == Float(notification.bodyLabel.frame.size.height))
    }

    @Test func notificationBackdropRadiusMatchesShadowAcrossBackingScale() throws {
        let metrics = ShellOverlayNotificationMetrics(showsThumbnail: true, hasBody: true)
        let notification = try ShellOverlayNotificationView(info: .init(
            id: 12,
            appName: "Nucleus",
            summary: "Screenshot saved",
            body: "nucleus-1779055142-371-6.png",
            thumbnailHandle: 7,
            showsThumbnail: true,
            expireTimeoutMs: 5000
        ), metrics: metrics)
        notification.frame = Rect(
            x: 0,
            y: 0,
            width: Double(metrics.cardW),
            height: Double(metrics.cardH)
        )

        try notification.layoutIfNeeded()

        #expect(notification.backgroundEffectView.cornerRadius == ShellShadow.popoverCornerRadius)
        #expect(notification.shadow.cornerRadius == notification.backgroundEffectView.cornerRadius)
        #expect(notification.thumbnailView.cornerRadius == 10)
    }

    @Test func hotkeyBackdropRadiusMatchesShadowAcrossBackingScale() throws {
        let hotkeyView = try ShellOverlayHotkeyView(entries: [
            .init(key: "Super + V", description: "Toggle Vignette"),
        ])

        try hotkeyView.updateFrame(.init(
            outputWidth: 1600,
            outputHeight: 1200,
            devicePixelRatio: 2,
            overlayRegionX: 0,
            overlayRegionY: 0,
            overlayRegionW: 1600,
            overlayRegionH: 1200
        ))

        #expect(hotkeyView.backgroundEffectView.cornerRadius == ShellShadow.popoverCornerRadius)
        #expect(hotkeyView.shadow.cornerRadius == hotkeyView.backgroundEffectView.cornerRadius)
        #expect(hotkeyView.metrics.hairlineWidth == 0.5)
    }

    @Test func shellOverlayLayoutsStayPointStableAcrossFractionalBackingScales() throws {
        let baselineHotkeyFrame = try Self.hotkeyFrame(backingScale: 1)
        let baselineNotificationFrame = try Self.notificationFrame(backingScale: 1)

        for scale in [Float(1.25), Float(1.5), Float(2)] {
            let hotkeyFrame = try Self.hotkeyFrame(backingScale: scale)
            let notificationFrame = try Self.notificationFrame(backingScale: scale)

            #expect(Self.nearlyEqual(hotkeyFrame.x, baselineHotkeyFrame.x))
            #expect(Self.nearlyEqual(hotkeyFrame.y, baselineHotkeyFrame.y))
            #expect(Self.nearlyEqual(hotkeyFrame.width, baselineHotkeyFrame.width))
            #expect(Self.nearlyEqual(hotkeyFrame.height, baselineHotkeyFrame.height))
            #expect(Self.nearlyEqual(notificationFrame.x, baselineNotificationFrame.x))
            #expect(Self.nearlyEqual(notificationFrame.y, baselineNotificationFrame.y))
            #expect(Self.nearlyEqual(notificationFrame.width, baselineNotificationFrame.width))
            #expect(Self.nearlyEqual(notificationFrame.height, baselineNotificationFrame.height))
        }
    }

    @Test func backingPixelInputConvertsToPointHitTesting() throws {
        let sink = InMemoryCommitSink()
        let scene = try ShellOverlayScene(frame: nil, commitSink: sink)
        let controller = ShellOverlayController(scene: scene) { _ in }
        controller.beginFrame(Self.frame(backingScale: 1.5))

        // A backing-pixel pointer sample over a hotkey row converts to points and
        // hit-tests the overlay. Rows are non-interactive (disabled controls), so
        // the resolved cursor is the default and the move is not consumed.
        let row = try #require(scene.hotkeyView.rowViews.first)
        let point = Point(
            x: scene.hotkeyView.frame.origin.x + row.frame.origin.x + row.frame.size.width * 0.5,
            y: scene.hotkeyView.frame.origin.y + row.frame.origin.y + row.frame.size.height * 0.5
        )
        let backingPoint = try #require(scene.frame).backingScaleFactor.backingPixels(fromPoints: point)

        let result = controller.dispatchInput(ShellOverlayInputEvent(Self.input(
            .pointerMove,
            x: Float(backingPoint.x),
            y: Float(backingPoint.y)
        )))

        #expect(!result.consumed)
        #expect(result.cursor == .default)
    }

    @Test func hotkeyOverlayLayoutsInstanceEntries() throws {
        let hotkeyView = try ShellOverlayHotkeyView(entries: [
            .init(key: "Super + X", description: "Custom action"),
            .init(key: "Super + Y", description: "Custom effect"),
            .init(key: "", description: ""),
        ])

        try hotkeyView.updateFrame(.init(
            outputWidth: 800,
            outputHeight: 600,
            devicePixelRatio: 1,
            overlayRegionX: 0,
            overlayRegionY: 0,
            overlayRegionW: 800,
            overlayRegionH: 600
        ))
        try hotkeyView.displayIfNeeded()

        // One row per non-empty entry (the blank spacer entry adds no row).
        #expect(hotkeyView.rowViews.count == 2)
    }

    @Test func controllerPublishesFromWindows() throws {
        let sink = InMemoryCommitSink()
        let scene = try ShellOverlayScene(frame: nil, commitSink: sink)
        var publications: [ShellOverlayPublication] = []
        let controller = ShellOverlayController(scene: scene) { publication in
            publications.append(publication)
        }

        controller.beginFrame(.init(
            outputWidth: 800,
            outputHeight: 600,
            devicePixelRatio: 1,
            overlayRegionX: 0,
            overlayRegionY: 0,
            overlayRegionW: 800,
            overlayRegionH: 600
        ))
        controller.setHotkeyVisible(false)
        controller.showNotification(.init(
            id: 7,
            appName: "Nucleus",
            summary: "Screenshot saved",
            body: "capture.png",
            thumbnailHandle: 0,
            showsThumbnail: true,
            expireTimeoutMs: 5000
        ))
        controller.showNotification(.init(
            id: 7,
            appName: "Nucleus",
            summary: "Screenshot saved",
            body: "capture.png",
            thumbnailHandle: 123,
            showsThumbnail: true,
            expireTimeoutMs: 5000
        ))

        #expect(publications.last?.frame.outputWidth == 800)
        #expect(!(publications.last?.scene.visualContent.isEmpty ?? true))
        let paintContentWrites = sink.transactions.flatMap { transaction in
            transaction.propertyUpdates.compactMap(\.properties.content)
        }
        #expect(paintContentWrites.contains { $0.kind == .paint && $0.handle != 0 })
        #expect(controller.scene.notifications.first?.thumbnailHandle == 123)
    }

    @Test func controllerDoesNotRepublishUnchangedStableOverlayFrames() throws {
        let sink = InMemoryCommitSink()
        let scene = try ShellOverlayScene(frame: nil, commitSink: sink)
        var publications: [ShellOverlayPublication] = []
        let controller = ShellOverlayController(scene: scene) { publication in
            publications.append(publication)
        }
        let frame = ShellOverlayFrameInfo(
            outputWidth: 800,
            outputHeight: 600,
            devicePixelRatio: 1,
            overlayRegionX: 0,
            overlayRegionY: 0,
            overlayRegionW: 800,
            overlayRegionH: 600
        )

        controller.beginFrame(frame)
        #expect(publications.count == 1)
        let transactionCount = sink.transactions.count

        controller.beginFrame(frame)
        _ = controller.dispatchInput(ShellOverlayInputEvent(Self.input(
            .pointerMove,
            x: 2,
            y: 2
        )))
        controller.setHotkeyVisible(true)

        #expect(publications.count == 1)
        #expect(sink.transactions.count == transactionCount)
    }

    @Test func unchangedFramesWaitForNotificationDeadline() throws {
        let clock = ManualClock(1_000_000)
        let sink = InMemoryCommitSink()
        let scene = try ShellOverlayScene(
            frame: nil,
            nowNs: { clock.now },
            commitSink: sink
        )
        let frame = ShellOverlayFrameInfo(
            outputWidth: 800,
            outputHeight: 600,
            devicePixelRatio: 1,
            overlayRegionX: 0,
            overlayRegionY: 0,
            overlayRegionW: 800,
            overlayRegionH: 600
        )

        #expect(scene.beginFrame(frame))
        #expect(!scene.beginFrame(frame))
        #expect(scene.showNotification(.init(
            id: 9,
            appName: "Nucleus",
            summary: "Overlay ready",
            body: "",
            thumbnailHandle: 0,
            showsThumbnail: false,
            expireTimeoutMs: 10
        )))
        #expect(scene.notificationPublicationDeadlineNs == clock.now + 10_000_000)
        #expect(!scene.beginFrame(frame))

        clock.now += 10_000_000
        #expect(scene.notificationFrameActive)
        #expect(scene.beginFrame(frame))
    }

    @Test func exitingNotificationReservesStackSlotUntilRemoved() throws {
        let list = try ShellOverlayNotificationListView()
        list.frameInfo = .init(
            outputWidth: 800,
            outputHeight: 600,
            devicePixelRatio: 1,
            overlayRegionX: 0,
            overlayRegionY: 0,
            overlayRegionW: 800,
            overlayRegionH: 600
        )
        let top = try ShellOverlayNotificationView(info: .init(
            id: 1,
            appName: "Nucleus",
            summary: "Top",
            body: "",
            thumbnailHandle: 0,
            showsThumbnail: false,
            expireTimeoutMs: 5000
        ))
        let lower = try ShellOverlayNotificationView(info: .init(
            id: 2,
            appName: "Nucleus",
            summary: "Lower",
            body: "",
            thumbnailHandle: 0,
            showsThumbnail: false,
            expireTimeoutMs: 5000
        ))
        try list.setNotifications([top, lower])

        try list.layoutIfNeeded()
        let initialTopY = Float(top.frame.origin.y)
        let initialTopX = Float(top.frame.origin.x)
        let initialLowerY = Float(lower.frame.origin.y)
        #expect(initialLowerY > initialTopY)

        try list.removeArrangedSubview(
            top,
            transition: .slideTrailingFade(duration: 0.24),
            reflow: .animated(duration: 0.22),
            nowNs: 1_000_000
        )
        try list.layoutIfNeeded()
        #expect(Float(top.frame.origin.y) == initialTopY)
        #expect(Float(top.frame.origin.x) > initialTopX)
        #expect(top.alphaValue == 0)
        #expect(Float(lower.frame.origin.y) == initialLowerY)

        try list.advanceArrangedSubviewTransitions(nowNs: 241_000_000)
        try list.layoutIfNeeded()
        #expect(!list.arrangedSubviews.contains { $0 === top })
        #expect(Float(lower.frame.origin.y) == initialTopY)
    }

    @Test func completedExitIsRemovedBeforePublishingReflowFrame() throws {
        let clock = ManualClock(1_000_000)
        let sink = InMemoryCommitSink()
        let scene = try ShellOverlayScene(
            frame: .init(
                outputWidth: 800,
                outputHeight: 600,
                devicePixelRatio: 1,
                overlayRegionX: 0,
                overlayRegionY: 0,
                overlayRegionW: 800,
                overlayRegionH: 600
            ),
            nowNs: { clock.now },
            commitSink: sink
        )
        #expect(scene.showNotification(.init(
            id: 1,
            appName: "Nucleus",
            summary: "Top",
            body: "",
            thumbnailHandle: 0,
            showsThumbnail: false,
            expireTimeoutMs: 5000
        )))
        #expect(scene.showNotification(.init(
            id: 2,
            appName: "Nucleus",
            summary: "Lower",
            body: "",
            thumbnailHandle: 0,
            showsThumbnail: false,
            expireTimeoutMs: 5000
        )))
        _ = scene.publishVisuals()

        #expect(scene.dismissNotification(1, reason: 2))
        #expect(scene.notificationPublicationDeadlineNs == clock.now + 240_000_000)
        let duringExit = try #require(scene.publishVisuals())
        #expect(!duringExit.scene.visualContent.isEmpty)
        #expect(scene.notifications.map(\.id) == [1, 2])

        clock.now += 240_000_000
        #expect(scene.notificationFrameActive)
        let afterExit = try #require(scene.publishVisuals())
        #expect(!afterExit.scene.visualContent.isEmpty)
        #expect(scene.notifications.map(\.id) == [2])
        #expect(scene.notificationPublicationDeadlineNs == clock.now + 220_000_000)
    }

    @Test func burstDismissalsExitOneAtATimeWithReflowBetweenEachExit() throws {
        let clock = ManualClock(1_000_000)
        let sink = InMemoryCommitSink()
        let scene = try ShellOverlayScene(
            frame: .init(
                outputWidth: 800,
                outputHeight: 600,
                devicePixelRatio: 1,
                overlayRegionX: 0,
                overlayRegionY: 0,
                overlayRegionW: 800,
                overlayRegionH: 600
            ),
            nowNs: { clock.now },
            commitSink: sink
        )
        for id in UInt32(1)...3 {
            #expect(scene.showNotification(.init(
                id: id,
                appName: "Nucleus",
                summary: "Notification \(id)",
                body: "",
                thumbnailHandle: 0,
                showsThumbnail: false,
                expireTimeoutMs: 5000
            )))
        }
        _ = scene.publishVisuals()

        #expect(scene.dismissNotification(1, reason: 2))
        #expect(scene.dismissNotification(2, reason: 2))
        #expect(scene.dismissNotification(3, reason: 2))
        _ = scene.publishVisuals()
        #expect(scene.notifications.map(\.id) == [1, 2, 3])

        clock.now += 240_000_000
        _ = scene.publishVisuals()
        #expect(scene.notifications.map(\.id) == [2, 3])

        clock.now += 100_000_000
        _ = scene.publishVisuals()
        #expect(scene.notifications.map(\.id) == [2, 3])

        clock.now += 120_000_000
        _ = scene.publishVisuals()
        #expect(scene.notifications.map(\.id) == [2, 3])

        clock.now += 240_000_000
        _ = scene.publishVisuals()
        #expect(scene.notifications.map(\.id) == [3])
    }

    @Test func semanticOverlayViewsStayInInMemoryRootContext() throws {
        let visualSink = InMemoryCommitSink()
        let scene = try ShellOverlayScene(frame: .init(
            outputWidth: 800,
            outputHeight: 600,
            devicePixelRatio: 1,
            overlayRegionX: 0,
            overlayRegionY: 0,
            overlayRegionW: 800,
            overlayRegionH: 600
        ), commitSink: visualSink)

        // Overlay semantic views live in the in-memory root context (which uses the
        // InMemoryCommitSink), not the shellOverlay wire context — so nothing is
        // committed to the visual sink until publish. (`Context.id` itself is a
        // core-internal detail; the sink type + shared-context identity are the
        // observable contract.)
        #expect(scene.notificationListView.backingLayer.context.commitSink is InMemoryCommitSink)
        #expect(scene.hotkeyView.backingLayer.context === scene.notificationListView.backingLayer.context)
        #expect(visualSink.transactions.isEmpty)

        #expect(scene.showNotification(.init(
            id: 9,
            appName: "Nucleus",
            summary: "Overlay ready",
            body: "semantic tree",
            thumbnailHandle: 0,
            showsThumbnail: false,
            expireTimeoutMs: 5000
        )))

        #expect(scene.notificationViews.first?.backingLayer.context.commitSink is InMemoryCommitSink)
        #expect(visualSink.transactions.isEmpty)

        let publication = scene.publishVisuals()
        #expect(!(publication?.scene.visualContent.isEmpty ?? true))
        // Publishing flushes the semantic tree into the shellOverlay wire context.
        // (The per-item `PublishedVisualContent` shape — kind/rootLayerID/orderIndex —
        // is core publish behavior, verified in the core layer's own tests; here we
        // assert the compositor-observable transaction structure it produces.)
        #expect(!visualSink.transactions.isEmpty)
        #expect(visualSink.transactions.allSatisfy { $0.contextID == .shellOverlay })
        #expect(!visualSink.transactions.contains { $0.contextID == .root })
        let firstVisualTransaction = try #require(visualSink.transactions.first)
        let createdLayerIDs = Set(firstVisualTransaction.created.map(\.0))
        #expect(!createdLayerIDs.isEmpty)
        let summaryLayerID = try #require(scene.notificationViews.first).summaryLabel.backingLayer.id
        #expect(firstVisualTransaction.propertyUpdates.contains {
            $0.layer == summaryLayerID && $0.properties.content?.kind == .paint
        })
        #expect(firstVisualTransaction.inserted.allSatisfy { inserted in
            createdLayerIDs.contains(inserted.layer) &&
                (inserted.parent == nil || createdLayerIDs.contains(inserted.parent!))
        })
        #expect(firstVisualTransaction.propertyUpdates.allSatisfy {
            createdLayerIDs.contains($0.layer)
        })
    }

    // Hosted-surface publication content (the per-item `PublishedVisualContent`
    // shape and the committed-content → visible mapping) is core publish behavior
    // and is verified in the core layer's own tests. At the compositor contract we
    // verify what ShellOverlayScene observably owns: the tracked hosted-surface set,
    // its ordering, and that detach removes exactly one surface, commits a removal,
    // and is idempotent.
    @Test func hostedSurfaceDetachRemovesTrackedSurfaceAndCommitsRemoval() throws {
        let visualSink = InMemoryCommitSink()
        let scene = try ShellOverlayScene(frame: .init(
            outputWidth: 800,
            outputHeight: 600,
            devicePixelRatio: 1,
            overlayRegionX: 0,
            overlayRegionY: 0,
            overlayRegionW: 800,
            overlayRegionH: 600
        ), commitSink: visualSink)
        let hosted = try scene.hostedSurface(for: "dock")
        #expect(scene.hostedSurfaces.contains { $0.surfaceID == hosted.surfaceID })
        let removalMark = visualSink.transactions.count

        #expect(try scene.detachHostedSurface("dock"))
        #expect(!scene.hostedSurfaces.contains { $0.surfaceID == hosted.surfaceID })
        // Detach commits a transaction that removes the surface's backing layer.
        #expect(visualSink.transactions[removalMark...].contains { !$0.removed.isEmpty })
        // Idempotent: detaching an already-absent surface reports no-op.
        #expect(!(try scene.detachHostedSurface("dock")))
    }

    @Test func multipleHostedSurfacesTrackAndDetachIndependently() throws {
        let visualSink = InMemoryCommitSink()
        let scene = try ShellOverlayScene(frame: .init(
            outputWidth: 800,
            outputHeight: 600,
            devicePixelRatio: 1,
            overlayRegionX: 0,
            overlayRegionY: 0,
            overlayRegionW: 800,
            overlayRegionH: 600
        ), commitSink: visualSink)
        let dock = try scene.hostedSurface(for: "dock")
        let menuBar = try scene.hostedSurface(for: "menubar")

        // Tracked in attach order.
        #expect(scene.hostedSurfaces.map(\.surfaceID) == [dock.surfaceID, menuBar.surfaceID])

        #expect(try scene.detachHostedSurface("dock"))
        // dock detached independently; menubar remains.
        #expect(scene.hostedSurfaces.map(\.surfaceID) == [menuBar.surfaceID])
    }
}
