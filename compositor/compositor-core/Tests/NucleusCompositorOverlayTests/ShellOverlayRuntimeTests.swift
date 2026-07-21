@_spi(NucleusCompositor) import NucleusLayers
import NucleusCompositorOverlayTypes
import NucleusUI
import NucleusUIEmbedder
import NucleusTextBackend
@testable import NucleusCompositorOverlay
import Synchronization
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
@Suite(.uiContext) struct ShellOverlayRuntimeTests {
    init() {
    }

    final class ManualClock: Sendable {
        private let storage: Mutex<UInt64>

        var now: UInt64 {
            get { storage.withLock { $0 } }
            set { storage.withLock { $0 = newValue } }
        }

        init(_ now: UInt64) {
            storage = Mutex(now)
        }
    }

    @Test func initialAndRuntimeEnvironmentAreSceneScoped() throws {
        let first = try ShellOverlayScene(
            frame: nil,
            commitSink: InMemoryCommitSink(),
            services: testHostServices(),
            environment: UIEnvironment(
                reducesMotion: true,
                appearance: .light,
                textScale: 1.5))
        let second = try ShellOverlayScene(
            frame: nil,
            commitSink: InMemoryCommitSink(),
            services: testHostServices())

        #expect(first.environment.appearance == .light)
        #expect(first.environment.reducesMotion)
        #expect(first.environment.textScale == 1.5)
        #expect(second.environment == UIEnvironment())

        first.updateEnvironment(UIEnvironment(
            reducesTransparency: true,
            appearance: .dark,
            textScale: 2))

        #expect(first.environment.reducesTransparency)
        #expect(first.environment.textScale == 2)
        #expect(second.environment == UIEnvironment())
    }

    @Test func controllerReflectsFrameNotificationAndOverlayState() throws {
        let sink = InMemoryCommitSink()
        let scene = try ShellOverlayScene(
            frame: nil,
            commitSink: sink,
            services: testHostServices())
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
        #expect(scene.hotkeyWindow.role == .overlay)
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
        let scene = try ShellOverlayScene(
            frame: nil,
            commitSink: InMemoryCommitSink(),
            services: testHostServices())
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

    private static func hotkeyFrame(backingScale: Float) -> (x: Double, y: Double, width: Double, height: Double) {
        let hotkeyView = ShellOverlayHotkeyView(
            textSystem: testTextSystem())
        hotkeyView.updateFrame(Self.frame(backingScale: backingScale))
        let frame = hotkeyView.frame
        return (frame.origin.x, frame.origin.y, frame.size.width, frame.size.height)
    }

    private static func notificationFrame(backingScale: Float) -> (x: Double, y: Double, width: Double, height: Double) {
        let notification = ShellOverlayNotificationView(info: .init(
            id: 12,
            appName: "Nucleus",
            summary: "Build complete",
            body: "nucleus-compositor finished",
            thumbnailHandle: 0,
            showsThumbnail: false,
            expireTimeoutMs: 5000
        ), metrics: ShellOverlayNotificationMetrics(
            textSystem: testTextSystem()))
        let list = ShellOverlayNotificationListView()
        list.frameInfo = Self.frame(backingScale: backingScale)
        list.setNotifications([notification])
        list.layoutIfNeeded()
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
        ),
        commitSink: sink,
        services: testHostServices())

        scene.hotkeyView.layoutIfNeeded()
        scene.hotkeyView.displayIfNeeded()

        let row = try #require(scene.hotkeyView.rowViews.first)
        // Rows size their labels to the laid-out text height (taller than the raw
        // font size) and place them on a baseline inside the label frame.
        #expect(row.keyLabel.frame.size.height > Double(row.keyLabel.fontSize))
        #expect(row.descriptionLabel.frame.size.height > Double(row.descriptionLabel.fontSize))

        let keyBaseline = row.keyLabel.frame.origin.y + row.keyLabel.firstBaselineOffsetFromTop
        #expect(keyBaseline > row.keyLabel.frame.origin.y)
        #expect(keyBaseline < row.keyLabel.frame.origin.y + row.keyLabel.frame.size.height)

        // The container itself paints no content; its separator is a filled rect.
        #expect(scene.hotkeyView.recordedDrawing.isEmptyDrawing)
        #expect(scene.hotkeyView.separatorView.recordedDrawing.paintCommands.first?.kind == .rect)
    }

    @Test func notificationLabelsUseTextLayoutHeights() {
        let notification = ShellOverlayNotificationView(info: .init(
            id: 12,
            appName: "Nucleus",
            summary: "Build complete",
            body: "nucleus-compositor finished",
            thumbnailHandle: 0,
            showsThumbnail: false,
            expireTimeoutMs: 5000
        ), metrics: ShellOverlayNotificationMetrics(
            textSystem: testTextSystem()))
        notification.frame = Rect(
            x: 0,
            y: 0,
            width: Double(notification.metrics.cardW),
            height: Double(notification.metrics.cardH)
        )

        notification.layoutIfNeeded()
        notification.summaryLabel.displayIfNeeded()
        notification.bodyLabel.displayIfNeeded()

        #expect(notification.summaryLabel.frame.size.height > Double(notification.summaryLabel.fontSize))
        #expect(notification.bodyLabel.frame.size.height > Double(notification.bodyLabel.fontSize))
        #expect(notification.metrics.cardH >= notification.metrics.cardPad * 2 + notification.metrics.textHeight(hasBody: true))
        #expect(notification.summaryLabel.recordedDrawing.paintCommands.first?.kind == .textLayout)
        #expect(notification.summaryLabel.recordedDrawing.paintCommands.first?.h == Float(notification.summaryLabel.frame.size.height))
        #expect(notification.bodyLabel.recordedDrawing.paintCommands.first?.h == Float(notification.bodyLabel.frame.size.height))
    }

    @Test func notificationBackdropRadiusMatchesShadowAcrossBackingScale() {
        let metrics = ShellOverlayNotificationMetrics(
            showsThumbnail: true,
            hasBody: true,
            textSystem: testTextSystem())
        let notification = ShellOverlayNotificationView(info: .init(
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

        notification.layoutIfNeeded()

        #expect(notification.backgroundEffectView.cornerRadius == ShellShadow.popoverCornerRadius)
        #expect(notification.shadow.cornerRadius == notification.backgroundEffectView.cornerRadius)
        #expect(notification.thumbnailView.cornerRadius == 10)
    }

    @Test func hotkeyBackdropRadiusMatchesShadowAcrossBackingScale() {
        let hotkeyView = ShellOverlayHotkeyView(entries: [
            .init(key: "Super + V", description: "Toggle Vignette"),
        ], textSystem: testTextSystem())

        hotkeyView.updateFrame(.init(
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

    @Test func shellOverlayLayoutsStayPointStableAcrossFractionalBackingScales() {
        let baselineHotkeyFrame = Self.hotkeyFrame(backingScale: 1)
        let baselineNotificationFrame = Self.notificationFrame(backingScale: 1)

        for scale in [Float(1.25), Float(1.5), Float(2)] {
            let hotkeyFrame = Self.hotkeyFrame(backingScale: scale)
            let notificationFrame = Self.notificationFrame(backingScale: scale)

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
        let scene = try ShellOverlayScene(
            frame: nil,
            commitSink: sink,
            services: testHostServices())
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

    @Test func hotkeyOverlayLayoutsInstanceEntries() {
        let hotkeyView = ShellOverlayHotkeyView(entries: [
            .init(key: "Super + X", description: "Custom action"),
            .init(key: "Super + Y", description: "Custom effect"),
            .init(key: "", description: ""),
        ], textSystem: testTextSystem())

        hotkeyView.updateFrame(.init(
            outputWidth: 800,
            outputHeight: 600,
            devicePixelRatio: 1,
            overlayRegionX: 0,
            overlayRegionY: 0,
            overlayRegionW: 800,
            overlayRegionH: 600
        ))
        hotkeyView.displayIfNeeded()

        // One row per non-empty entry (the blank spacer entry adds no row).
        #expect(hotkeyView.rowViews.count == 2)
    }

    @Test func controllerPublishesFromWindows() throws {
        let sink = InMemoryCommitSink()
        let scene = try ShellOverlayScene(
            frame: nil,
            commitSink: sink,
            services: testHostServices())
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
        let scene = try ShellOverlayScene(
            frame: nil,
            commitSink: sink,
            services: testHostServices())
        var publications: [ShellOverlayPublication] = []
        var semanticPublicationCount = 0
        let controller = ShellOverlayController(
            scene: scene,
            semanticPublisher: {
                semanticPublicationCount += 1
            }
        ) { publication in
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
        #expect(semanticPublicationCount == 1)
        let transactionCount = sink.transactions.count

        controller.beginFrame(frame)
        _ = controller.dispatchInput(ShellOverlayInputEvent(Self.input(
            .pointerMove,
            x: 2,
            y: 2
        )))
        controller.setHotkeyVisible(true)
        controller.publishScene()

        #expect(publications.count == 1)
        #expect(semanticPublicationCount == 2)
        #expect(sink.transactions.count == transactionCount)
    }

    @Test func unchangedFramesWaitForNotificationDeadline() throws {
        let clock = ManualClock(1_000_000)
        let sink = InMemoryCommitSink()
        let scene = try ShellOverlayScene(
            frame: nil,
            nowNs: { clock.now },
            commitSink: sink,
            services: testHostServices()
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

    @Test func exitingNotificationReservesStackSlotUntilRemoved() {
        let list = ShellOverlayNotificationListView()
        list.frameInfo = .init(
            outputWidth: 800,
            outputHeight: 600,
            devicePixelRatio: 1,
            overlayRegionX: 0,
            overlayRegionY: 0,
            overlayRegionW: 800,
            overlayRegionH: 600
        )
        let top = ShellOverlayNotificationView(info: .init(
            id: 1,
            appName: "Nucleus",
            summary: "Top",
            body: "",
            thumbnailHandle: 0,
            showsThumbnail: false,
            expireTimeoutMs: 5000
        ), metrics: ShellOverlayNotificationMetrics(
            textSystem: testTextSystem()))
        let lower = ShellOverlayNotificationView(info: .init(
            id: 2,
            appName: "Nucleus",
            summary: "Lower",
            body: "",
            thumbnailHandle: 0,
            showsThumbnail: false,
            expireTimeoutMs: 5000
        ), metrics: ShellOverlayNotificationMetrics(
            textSystem: testTextSystem()))
        list.setNotifications([top, lower])

        list.layoutIfNeeded()
        let initialTopY = Float(top.frame.origin.y)
        let initialTopX = Float(top.frame.origin.x)
        let initialLowerY = Float(lower.frame.origin.y)
        #expect(initialLowerY > initialTopY)

        list.removeArrangedSubview(
            top,
            transition: .slideTrailingFade(duration: 0.24),
            reflow: .animated(duration: 0.22)
        )
        list.layoutIfNeeded()
        #expect(Float(top.frame.origin.y) == initialTopY)
        #expect(Float(top.frame.origin.x) == initialTopX)
        #expect(top.alphaValue == 1)
        #expect(Float(lower.frame.origin.y) == initialLowerY)

        _ = list.embedderUIContext.advanceAnimations(
            predictedPresentationNanoseconds: 1_000_000
        )
        _ = list.embedderUIContext.advanceAnimations(
            predictedPresentationNanoseconds: 241_000_000
        )
        _ = list.embedderUIContext.advanceAnimations(
            predictedPresentationNanoseconds: 461_000_000
        )
        list.layoutIfNeeded()
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
            commitSink: sink,
            services: testHostServices()
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
        #expect(scene.notificationPublicationDeadlineNs == clock.now)
        let duringExit = try #require(scene.publishVisuals())
        #expect(!duringExit.scene.visualContent.isEmpty)
        #expect(scene.notifications.map(\.id) == [1, 2])

        clock.now += 240_000_000
        #expect(scene.notificationFrameActive)
        let afterExit = try #require(scene.publishVisuals())
        #expect(!afterExit.scene.visualContent.isEmpty)
        #expect(scene.notifications.map(\.id) == [2])
        #expect(scene.notificationPublicationDeadlineNs == clock.now)
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
            commitSink: sink,
            services: testHostServices()
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

    @Test func semanticOverlayViewsDoNotMutateTheVisualContextBeforePublication() throws {
        let visualSink = InMemoryCommitSink()
        let scene = try ShellOverlayScene(frame: .init(
            outputWidth: 800,
            outputHeight: 600,
            devicePixelRatio: 1,
            overlayRegionX: 0,
            overlayRegionY: 0,
            overlayRegionW: 800,
            overlayRegionH: 600
        ),
        commitSink: visualSink,
        services: testHostServices())

        // Semantic views share a pure UI context. They own no fallback render
        // context and cannot enqueue layer mutations.
        #expect(
            scene.notificationListView.embedderUIContext ===
                scene.hotkeyView.embedderUIContext
        )
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

        #expect(
            scene.notificationViews.first?.embedderUIContext ===
                scene.notificationListView.embedderUIContext
        )
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
        #expect(firstVisualTransaction.propertyUpdates.contains {
            $0.properties.content?.kind == .paint
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
        ),
        commitSink: visualSink,
        services: testHostServices())
        try scene.attachHostedSurface(for: "dock") {
            _, _, _, _ in
        }
        let tracked = try #require(scene.hostedSurfaces.first)
        #expect(tracked.hasCommittedContent)
        #expect(scene.hostedSurfaces.contains { $0.surfaceID == tracked.surfaceID })
        let removalMark = visualSink.transactions.count

        #expect(try scene.detachHostedSurface("dock"))
        #expect(!scene.hostedSurfaces.contains { $0.surfaceID == tracked.surfaceID })
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
        ),
        commitSink: visualSink,
        services: testHostServices())
        let dock = try scene.hostedSurface(for: "dock")
        let menuBar = try scene.hostedSurface(for: "menubar")

        // Tracked in attach order.
        #expect(scene.hostedSurfaces.map(\.surfaceID) == [dock.surfaceID, menuBar.surfaceID])

        #expect(try scene.detachHostedSurface("dock"))
        // dock detached independently; menubar remains.
        #expect(scene.hostedSurfaces.map(\.surfaceID) == [menuBar.surfaceID])
    }
}
