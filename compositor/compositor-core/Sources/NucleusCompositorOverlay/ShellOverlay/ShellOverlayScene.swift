import Glibc
import NucleusUI
import NucleusUIEmbedder
import class NucleusLayers.Layer
import protocol NucleusLayers.CommitSink
import Tracy

@MainActor
public final class ShellOverlayScene: ~Sendable {
    private struct NotificationRecord: Equatable, ~Sendable {
        var info: ShellOverlayNotificationInfo
        var view: ShellOverlayNotificationView
        var createdNs: UInt64
        var closeReason: UInt32?

        static func == (lhs: NotificationRecord, rhs: NotificationRecord) -> Bool {
            lhs.info == rhs.info &&
                lhs.createdNs == rhs.createdNs &&
                lhs.closeReason == rhs.closeReason &&
                lhs.view === rhs.view
        }
    }

    package private(set) var frame: ShellOverlayFrameInfo?
    private var notificationRecords: [NotificationRecord] = []
    package private(set) var hotkeyVisible: Bool = true
    private let publicationContext: WindowScenePublicationContext
    let notificationWindow: Window
    let notificationViewController: ViewController
    let notificationListView: ShellOverlayNotificationListView
    let hotkeyWindow: Window
    let hotkeyViewController: ViewController
    let hotkeyView: ShellOverlayHotkeyView
    private let hostedSurfaceRegistry: HostedSurfaceRegistry<HostedSurfaceID>
    private let notificationClosed: @MainActor (UInt32, UInt32) -> Void
    /// `package` rather than `private` so the package's tests can install a
    /// window and observe what dispatch actually delivers. Consistent with
    /// `menuVisible`, `hotkeyView`, and the rest of this type's test surface.
    package let windowScene: WindowScene
    private let clockNs: @MainActor () -> UInt64

    package var notifications: [ShellOverlayNotificationInfo] {
        notificationRecords.map(\.info)
    }

    var notificationViews: [ShellOverlayNotificationView] {
        notificationRecords.map(\.view)
    }

    package var notificationFrameActive: Bool {
        guard let deadline = notificationPublicationDeadlineNs else {
            return false
        }
        return clockNs() >= deadline
    }

    package var notificationPublicationDeadlineNs: UInt64? {
        nextNotificationPublicationDeadlineNs()
    }

    package var windows: [Window] {
        windowScene.windows
    }

    package func hostedSurface(for id: HostedSurfaceID) throws(UIError) -> HostedSurface {
        hostedSurfaceRegistry.surface(
            for: id,
            frame: frame.map { Self.hostedSurfaceFrame($0) },
            role: .layer,
            level: .shellChrome
        )
    }

    package func attachHostedSurface<Result>(
        for id: HostedSurfaceID,
        using attach: (View, Int, Layer, UInt32) throws -> Result
    ) throws -> Result {
        let surface = try hostedSurface(for: id)
        return try hostedSurfaceRegistry.attach(surface, in: windowScene, using: attach)
    }

    @discardableResult
    package func attachHostedSurfaces(
        where shouldAttach: (HostedSurface) -> Bool,
        using attach: (View, Int, Layer, UInt32) throws -> Void
    ) throws -> Bool {
        try hostedSurfaceRegistry.attachAll(
            hostedSurfaces, in: windowScene, where: shouldAttach, using: attach)
    }

    package func hostedSurfaceID(for id: HostedSurfaceID) -> Int? {
        hostedSurfaceRegistry.surfaceID(for: id)
    }

    package var hostedSurfaces: [HostedSurface] {
        hostedSurfaceRegistry.surfaces
    }

    @discardableResult
    package func detachHostedSurface(_ id: HostedSurfaceID) throws(UIError) -> Bool {
        try hostedSurfaceRegistry.detachSurface(id)
    }

    package convenience init(
        frame: ShellOverlayFrameInfo?,
        notificationClosed: @escaping @MainActor (UInt32, UInt32) -> Void = { _, _ in },
        commitSink: any CommitSink,
        services: UIHostServices,
        environment: UIEnvironment = UIEnvironment()
    ) throws {
        try self.init(
            frame: frame,
            notificationClosed: notificationClosed,
            nowNs: monotonicNs,
            commitSink: commitSink,
            services: services,
            environment: environment
        )
    }

    init(
        frame: ShellOverlayFrameInfo?,
        notificationClosed: @escaping @MainActor (UInt32, UInt32) -> Void = { _, _ in },
        nowNs: @escaping @MainActor () -> UInt64,
        commitSink: any CommitSink,
        services: UIHostServices,
        environment: UIEnvironment = UIEnvironment()
    ) throws {
        self.frame = frame
        self.notificationClosed = notificationClosed
        self.clockNs = nowNs
        let publicationContext = try WindowScenePublicationContext(
            commitSink: commitSink,
            services: services,
            environment: environment)
        self.publicationContext = publicationContext
        self.hostedSurfaceRegistry = HostedSurfaceRegistry(
            context: publicationContext.visualContext,
            uiContext: publicationContext.semanticContext)
        let notificationListView = publicationContext.withSemanticContext {
            ShellOverlayNotificationListView()
        }
        let hotkeyView = publicationContext.withSemanticContext {
            ShellOverlayHotkeyView(textSystem: services.textSystem)
        }
        self.notificationListView = notificationListView
        self.hotkeyView = hotkeyView
        self.notificationViewController = ViewController(view: notificationListView)
        self.hotkeyViewController = ViewController(view: hotkeyView)
        self.notificationWindow = publicationContext.withSemanticContext {
            Window(title: "Notifications", role: .notification, level: .overlay)
        }
        self.hotkeyWindow = publicationContext.withSemanticContext {
            Window(title: "Keyboard Shortcuts", role: .overlay, level: .criticalOverlay)
        }
        self.windowScene = publicationContext.makeWindowScene(
            windows: [notificationWindow, hotkeyWindow])
        try publicationContext.withSemanticContext {
            notificationWindow.setContentViewController(notificationViewController)
            notificationWindow.orderFront()
            hotkeyWindow.setContentViewController(hotkeyViewController)
            hotkeyWindow.orderFront()
            if let frame {
                try updateWindowFrames(frame)
            }
            hotkeyView.update(visible: hotkeyVisible)
        }
        self.notificationListView.setDismissHandler { [weak self] id in
            _ = self?.dismissNotification(id, reason: 2)
        }
    }

    package func submit(event: ShellOverlayEvent) -> Bool {
        switch event {
        case let .frame(frame):
            return beginFrame(frame)
        case let .notification(notification):
            return showNotification(notification)
        case let .dismissNotification(id, reason):
            return dismissNotification(id, reason: reason)
        case let .hotkeyVisibility(visible):
            return setHotkeyVisible(visible)
        }
    }

    package func beginFrame(_ frame: ShellOverlayFrameInfo) -> Bool {
        Trace.zone("overlay.scene.begin_frame", color: Trace.Color.blue) {
            let frameChanged = self.frame != frame
            self.frame = frame
            if frameChanged {
                hostedSurfaceRegistry.updateFrame(Self.hostedSurfaceFrame(frame))
                do {
                    try updateWindowFrames(frame)
                } catch {
                    logShellOverlayError("frame update failed: \(error)")
                }
            }
            return frameChanged || notificationFrameActive
        }
    }

    package func updateEnvironment(_ environment: UIEnvironment) {
        publicationContext.semanticContext.updateEnvironment(environment)
    }

    package var environment: UIEnvironment {
        publicationContext.semanticContext.environment
    }

    package func showNotification(_ notification: ShellOverlayNotificationInfo) -> Bool {
        Trace.zone("overlay.scene.show_notification", color: Trace.Color.green) {
            if let index = notificationRecords.firstIndex(where: { $0.info.id == notification.id }) {
                let changed = notificationRecords[index].info != notification ||
                    notificationRecords[index].closeReason != nil
                notificationRecords[index].info = notification
                notificationRecords[index].closeReason = nil
                notificationRecords[index].view.update(notification)
                return changed
            } else {
                let view = publicationContext.withSemanticContext {
                    ShellOverlayNotificationView(
                        info: notification,
                        metrics: ShellOverlayNotificationMetrics(
                            showsThumbnail: notification.showsThumbnail,
                            hasBody: !notification.body.isEmpty,
                            textSystem: publicationContext.semanticContext
                                .services.textSystem))
                }
                view.setDismissHandler { [weak self] id in
                    _ = self?.dismissNotification(id, reason: 2)
                }
                notificationRecords.append(.init(info: notification, view: view, createdNs: clockNs()))
                notificationListView.setNotifications(notificationViews)
            }
            trimOverflow()
            Trace.plot("swift.overlay.notifications.count", UInt64(notificationRecords.count))
            return true
        }
    }

    package func dismissNotification(_ id: UInt32) -> Bool {
        return dismissNotification(id, reason: nil)
    }

    package func dismissNotification(_ id: UInt32, reason: UInt32?) -> Bool {
        Trace.zone("overlay.scene.dismiss_notification", color: Trace.Color.yellow) {
            guard let index = notificationRecords.firstIndex(where: { $0.info.id == id }) else {
                return false
            }
            let wasQueued = notificationListView.isArrangedSubviewRemovalQueued(notificationRecords[index].view)
            if notificationRecords[index].closeReason == nil {
                notificationRecords[index].closeReason = reason
            }
            let view = notificationRecords[index].view
            do {
                if let frame {
                    try updateNotificationWindowFrame(frame)
                    notificationListView.layoutIfNeeded()
                }
                notificationListView.removeArrangedSubview(
                    view,
                    transition: .slideTrailingFade(duration: 0.24),
                    reflow: .animated(duration: 0.22),
                    didRemove: { [weak self, weak view] in
                        guard let self, let view else { return }
                        self.finishNotificationRemoval(view: view)
                    }
                )
            } catch {
                logShellOverlayError("notification dismissal failed id=\(id): \(error)")
                return false
            }
            return !wasQueued
        }
    }

    package func setHotkeyVisible(_ visible: Bool) -> Bool {
        guard hotkeyVisible != visible else {
            return false
        }
        hotkeyVisible = visible
        do {
            hotkeyView.update(visible: hotkeyVisible)
            if visible {
                if let frame {
                    try updateHotkeyFrame(frame)
                }
                hotkeyWindow.orderFront()
            } else {
                hotkeyWindow.orderOut()
            }
        } catch {
            logShellOverlayError("hotkey visibility update failed: \(error)")
            return false
        }
        return true
    }

    /// Present overlay command data through NucleusUI's single retained menu
    /// controller. The overlay owns no parallel panel stack or input state.
    package func showMenu(
        _ menu: Menu,
        at anchor: Point
    ) -> Bool {
        Trace.zone("overlay.scene.show_menu", color: Trace.Color.green) {
            _ = publicationContext.withSemanticContext {
                windowScene.present(
                    menu,
                    anchor: Rect(
                        x: anchor.x,
                        y: anchor.y,
                        width: 1,
                        height: 1),
                    level: .criticalOverlay,
                    stickyOpeningGesture: true)
            }
            return true
        }
    }

    @discardableResult
    package func dismissMenu() -> Bool {
        guard let presentation = windowScene.menuPresentation else {
            return false
        }
        presentation.dismiss()
        return true
    }

    private var heldKey: HeldKey?

    package var menuVisible: Bool {
        windowScene.menuPresentation != nil
    }

    /// Whether keys should be routed here rather than to the focused Wayland
    /// client. True for an open menu, and for a focused responder in the
    /// overlay's own scene — a text field cannot receive input otherwise.
    package var wantsKeyboard: Bool {
        menuVisible || windowScene.keyWindow?.firstResponder != nil
    }

    // MARK: - Key repeat

    /// The key currently held down, and when its next repeat is due. The
    /// compositor advertises 600 ms then 25/sec to Wayland clients
    /// (`wl_keyboard.repeat_info`); overlay UI has to implement the same thing
    /// itself, since it never receives that event.
    private struct HeldKey {
        var event: Event
        var keycode: UInt32
        var nextRepeatNs: UInt64
    }

    private static let keyRepeatDelayNs: UInt64 = 600_000_000
    private static let keyRepeatIntervalNs: UInt64 = 40_000_000

    /// Whether holding this key should repeat. Navigation and deletion repeat,
    /// as does anything that produced text; Escape and Return do not, because
    /// repeating them would fire an action many times from one press.
    private func isRepeatable(_ event: Event) -> Bool {
        switch event.keyCode {
        case .leftArrow, .rightArrow, .upArrow, .downArrow,
             .delete, .forwardDelete, .pageUp, .pageDown:
            return true
        case .escape, .return, .tab:
            return false
        default:
            return !(event.characters ?? "").isEmpty
        }
    }

    private func noteKeyState(_ event: ShellOverlayInputEvent, nucleon: Event?) {
        switch event.kind {
        case .keyDown:
            guard let nucleon, isRepeatable(nucleon) else {
                heldKey = nil
                return
            }
            heldKey = HeldKey(
                event: nucleon,
                keycode: event.keycode,
                nextRepeatNs: clockNs() &+ Self.keyRepeatDelayNs)
        case .keyUp:
            // Only the held key's own release stops the repeat; releasing some
            // other key while this one is still down must not.
            if heldKey?.keycode == event.keycode { heldKey = nil }
        default:
            break
        }
    }

    private var activePointerButtons: PointerButtonMask = []

    /// Emit any repeats now due. Returns whether anything was dispatched, so the
    /// caller knows a frame is wanted.
    @discardableResult
    package func advanceKeyRepeat(nowNs: UInt64) -> Bool {
        guard var held = heldKey else { return false }
        guard nowNs >= held.nextRepeatNs else { return false }
        var dispatched = false
        // Catch up rather than emitting one per frame, so a stalled frame does
        // not silently swallow repeats. Bounded so a long stall cannot flood.
        var emitted = 0
        while nowNs >= held.nextRepeatNs, emitted < 8 {
            var repeatEvent = held.event
            repeatEvent.isARepeat = true
            repeatEvent.timestampNanoseconds = held.nextRepeatNs
            _ = windowScene.dispatchEvent(repeatEvent)
            held.nextRepeatNs &+= Self.keyRepeatIntervalNs
            emitted += 1
            dispatched = true
        }
        if emitted == 8 {
            // Resynchronize after a stall instead of staying permanently behind.
            held.nextRepeatNs = nowNs &+ Self.keyRepeatIntervalNs
        }
        heldKey = held
        return dispatched
    }

    /// Whether a key is being held, so the host knows to keep scheduling frames.
    package var keyRepeatActive: Bool { heldKey != nil }

    package func dispatchInput(_ event: ShellOverlayInputEvent) -> ShellOverlayInputResult {
        var pointEvent = frame.map {
            event.convertedFromBackingPixels($0.backingScaleFactor)
        } ?? event
        switch pointEvent.kind {
        case .pointerDown:
            activePointerButtons.insert(
                .button(ShellOverlayInputEvent.nucleonButton(pointEvent.button)))
        case .pointerUp:
            activePointerButtons.remove(
                .button(ShellOverlayInputEvent.nucleonButton(pointEvent.button)))
        default:
            break
        }
        pointEvent.activeButtons = activePointerButtons
        noteKeyState(pointEvent, nucleon: pointEvent.nucleonEvent)
        let cursor = cursor(for: pointEvent.location)
        guard let nucleonEvent = pointEvent.nucleonEvent else {
            return .init(consumed: false, wantsFrame: false, cursor: cursor)
        }

        // Scene dispatch holds the pointer capture now, so a press and its
        // release reach the same view without the overlay tracking buttons
        // itself. Right- and middle-clicks reach views for the first time; the
        // old path filtered everything but BTN_LEFT before dispatch.
        let handled = windowScene.dispatchEvent(nucleonEvent) == .handled
        if handled {
            return .init(consumed: true, wantsFrame: true, cursor: cursor)
        }

        if hotkeyVisible, pointEvent.kind == .pointerDown, nucleonEvent.button == .left {
            let changed = setHotkeyVisible(false)
            return .init(consumed: true, wantsFrame: changed, cursor: cursor)
        }

        return .init(consumed: false, wantsFrame: false, cursor: cursor)
    }

    package func publishVisuals() -> ShellOverlayPublication? {
        Trace.zone("overlay.scene.publish_visuals", color: Trace.Color.blue) { () -> ShellOverlayPublication? in
            guard let frame else {
                return nil
            }
            let nowNs = clockNs()
            _ = publicationContext.semanticContext.advanceAnimations(
                predictedPresentationNanoseconds: nowNs
            )
            advanceKeyRepeat(nowNs: nowNs)
            expireNotifications(nowNs: nowNs)
            let publishedScene: PublishedScene
            do {
                publishedScene = try windowScene.publish(
                    placing: hostedSurfaceRegistry.placements()
                ) { window in
                    switch window.role {
                    case .notification, .overlay, .popup:
                        true
                    case .application, .layer, .lock, .hostedContent:
                        false
                    }
                }
            } catch {
                logShellOverlayError("native publication failed: \(error)")
                return nil
            }
            Trace.plot("swift.overlay.notifications.count", UInt64(notificationRecords.count))
            return ShellOverlayPublication(
                frame: frame,
                scene: publishedScene
            )
        }
    }

    private func cursor(for location: Point) -> ShellOverlayCursor {
        guard let target = windowScene.hitTest(at: location)?.view else {
            return .default
        }
        var current: Responder? = target
        while let responder = current {
            if let control = responder as? Control, control.isEnabled {
                return .pointer
            }
            current = responder.nextResponder
        }
        return .default
    }

    private func updateWindowFrames(_ frame: ShellOverlayFrameInfo) throws(UIError) {
        let outputSize = frame.outputSizeInPoints
        windowScene.displayBounds = Rect(
            x: 0,
            y: 0,
            width: outputSize.width,
            height: outputSize.height)
        try updateNotificationWindowFrame(frame)
        if hotkeyVisible {
            try updateHotkeyFrame(frame)
        }
    }

    private func updateNotificationWindowFrame(_ frame: ShellOverlayFrameInfo) throws(UIError) {
        notificationListView.frameInfo = frame
        let outputSize = frame.outputSizeInPoints
        notificationWindow.setFrame(Rect(
            x: 0,
            y: 0,
            width: outputSize.width,
            height: outputSize.height
        ))
    }

    private func updateHotkeyFrame(_ frame: ShellOverlayFrameInfo) throws(UIError) {
        hotkeyView.updateFrame(frame)
        hotkeyWindow.setFrame(hotkeyView.frame, display: false)
    }

    private static func hostedSurfaceFrame(_ frame: ShellOverlayFrameInfo) -> Rect {
        let outputSize = frame.outputSizeInPoints
        return Rect(
            x: 0,
            y: 0,
            width: outputSize.width,
            height: outputSize.height
        )
    }

    private func expireNotifications(nowNs: UInt64) {
        let records = notificationRecords
        for record in records where !notificationListView.isArrangedSubviewRemovalQueued(record.view) {
            let timeoutMs = record.info.expireTimeoutMs <= 0 ? 5_000 : record.info.expireTimeoutMs
            let elapsedNs = nowNs >= record.createdNs ? nowNs - record.createdNs : 0
            if elapsedNs >= UInt64(timeoutMs) * 1_000_000 {
                _ = dismissNotification(record.info.id, reason: 1)
            }
        }
    }

    private func nextNotificationPublicationDeadlineNs() -> UInt64? {
        var deadline: UInt64? = notificationListView.arrangedSubviewTransitionActive
            ? clockNs()
            : nil
        for record in notificationRecords where !notificationListView.isArrangedSubviewRemovalQueued(record.view) {
            let timeoutMs = record.info.expireTimeoutMs <= 0 ? 5_000 : record.info.expireTimeoutMs
            let timeoutNs = record.createdNs + UInt64(timeoutMs) * 1_000_000
            deadline = minDeadline(deadline, timeoutNs)
        }
        return deadline
    }

    private func finishNotificationRemoval(view: ShellOverlayNotificationView) {
        guard let index = notificationRecords.firstIndex(where: { $0.view === view }) else {
            return
        }
        let record = notificationRecords.remove(at: index)
        if let reason = record.closeReason {
            notificationClosed(record.info.id, reason)
        }
    }

    private func trimOverflow() {
        var closed: [UInt32] = []
        while notificationRecords.count > 10 {
            closed.append(notificationRecords.removeFirst().info.id)
        }
        if !closed.isEmpty {
            notificationListView.setNotifications(notificationViews)
            for id in closed {
                notificationClosed(id, 1)
            }
        }
    }

}

private func monotonicNs() -> UInt64 {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec)
}

private func logShellOverlayError(_ message: String) {
    let line = "shell-overlay: \(message)\n"
    line.withCString { pointer in
        _ = write(STDERR_FILENO, pointer, strlen(pointer))
    }
}

private func minDeadline(_ lhs: UInt64?, _ rhs: UInt64) -> UInt64 {
    if let lhs {
        return min(lhs, rhs)
    }
    return rhs
}
