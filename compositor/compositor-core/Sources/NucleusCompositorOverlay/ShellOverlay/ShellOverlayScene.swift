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
    let menuWindow: Window
    /// One open menu panel in the cascade: its view, its output-space frame, and the
    /// `actionID` of the parent-menu row that spawned it (a sentinel for the root).
    /// `menuLevels` is the open stack — index 0 is the root menu, each later entry a
    /// submenu opened to the side of a row in the entry before it. All panels live in
    /// `menuContainer`, a full-output transparent view in `menuWindow`.
    private struct MenuLevel {
        let view: ShellOverlayMenuView
        let frame: Rect
        let parentActionID: Int
    }
    private var menuContainer: View?
    private var menuLevels: [MenuLevel] = []
    private var menuSelectHandler: (@MainActor (Int) -> Void)?
    /// True while the open menu is "sticky": the release of the click that opened it
    /// (or any release in empty space right after) keeps it open instead of dismissing,
    /// so a plain click opens a menu that stays up. Cleared by the first pointer-up the
    /// cascade sees. Press-drag-release onto a row still selects, because that release
    /// lands over a panel and never reaches the sticky branch.
    private var menuStickyArmed: Bool = false
    private let hostedSurfaceRegistry: HostedSurfaceRegistry<HostedSurfaceID>
    private let notificationClosed: @MainActor (UInt32, UInt32) -> Void
    private let windowScene: WindowScene
    private let clockNs: @MainActor () -> UInt64
    private var capturedPointerButtons: Set<UInt32> = []

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
            role: .shellChrome,
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
        commitSink: any CommitSink
    ) throws {
        try self.init(
            frame: frame,
            notificationClosed: notificationClosed,
            nowNs: monotonicNs,
            commitSink: commitSink
        )
    }

    init(
        frame: ShellOverlayFrameInfo?,
        notificationClosed: @escaping @MainActor (UInt32, UInt32) -> Void = { _, _ in },
        nowNs: @escaping @MainActor () -> UInt64,
        commitSink: any CommitSink
    ) throws {
        self.frame = frame
        self.notificationClosed = notificationClosed
        self.clockNs = nowNs
        let publicationContext = try WindowScenePublicationContext(commitSink: commitSink)
        self.publicationContext = publicationContext
        self.hostedSurfaceRegistry = HostedSurfaceRegistry(context: publicationContext.visualContext)
        let notificationListView = publicationContext.withSemanticContext {
            ShellOverlayNotificationListView()
        }
        let hotkeyView = publicationContext.withSemanticContext {
            ShellOverlayHotkeyView()
        }
        self.notificationListView = notificationListView
        self.hotkeyView = hotkeyView
        self.notificationViewController = ViewController(view: notificationListView)
        self.hotkeyViewController = ViewController(view: hotkeyView)
        self.notificationWindow = publicationContext.withSemanticContext {
            Window(title: "Notifications", role: .notification, level: .overlay)
        }
        self.hotkeyWindow = publicationContext.withSemanticContext {
            Window(title: "Keyboard Shortcuts", role: .statusOverlay, level: .criticalOverlay)
        }
        self.menuWindow = publicationContext.withSemanticContext {
            Window(title: "Menu", role: .statusOverlay, level: .criticalOverlay)
        }
        self.windowScene = publicationContext.makeWindowScene(windows: [notificationWindow, hotkeyWindow, menuWindow])
        try publicationContext.withSemanticContext {
            notificationWindow.setContentViewController(notificationViewController)
            notificationWindow.orderFront()
            hotkeyWindow.setContentViewController(hotkeyViewController)
            hotkeyWindow.orderFront()
            menuWindow.setContentViewController(ViewController(view: View()))
            menuWindow.orderOut()
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
                    ShellOverlayNotificationView(info: notification)
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
            let nowNs = clockNs()
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
                try notificationListView.removeArrangedSubview(
                    view,
                    transition: .slideTrailingFade(duration: 0.24),
                    reflow: .animated(duration: 0.22),
                    nowNs: nowNs,
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

    /// A root-level menu's `parentActionID` — never matches a real dbusmenu id.
    private static let menuRootSentinel = Int.min
    /// How far a submenu panel overlaps its parent's right edge, so the cascade reads
    /// as connected.
    private static let menuSubmenuOverlap: Double = 4

    /// Open a fresh menu (root level), replacing any open cascade, through a
    /// full-output transparent container in `menuWindow`. Every submenu opened from
    /// it later stacks into the same container. `onSelect` reports the chosen row's
    /// token at any depth.
    package func showMenu(
        _ menu: Menu,
        at anchor: Point,
        onSelect: @escaping @MainActor (Int) -> Void
    ) -> Bool {
        Trace.zone("overlay.scene.show_menu", color: Trace.Color.green) {
            _ = dismissMenu()
            let container = View()
            let controller = ViewController(view: container)
            let outputSize = menuOutputSize()
            publicationContext.withSemanticContext {
                menuWindow.setContentViewController(controller)
                menuWindow.setFrame(Rect(x: 0, y: 0, width: outputSize.width, height: outputSize.height), display: false)
                menuWindow.orderFront()
            }
            menuContainer = container
            menuSelectHandler = onSelect
            guard pushMenuLevel(items: menu.items, anchor: anchor, parentActionID: Self.menuRootSentinel) else {
                _ = dismissMenu()
                return false
            }
            // Stay open after the opening gesture: swallow the release of the click
            // that brought the menu up rather than treating it as a dismiss.
            menuStickyArmed = true
            return true
        }
    }

    @discardableResult
    package func dismissMenu() -> Bool {
        guard menuContainer != nil else { return false }
        popMenuLevels(toDepth: 0)
        menuContainer = nil
        menuSelectHandler = nil
        menuStickyArmed = false
        menuWindow.orderOut()
        return true
    }

    /// Push a menu panel into the cascade: a `MenuView` over `items`, clamped on the
    /// output at `anchor`, added to the container and recorded as the new top level.
    @discardableResult
    private func pushMenuLevel(items: [MenuItem], anchor: Point, parentActionID: Int) -> Bool {
        guard let container = menuContainer else { return false }
        let view = publicationContext.withSemanticContext {
            ShellOverlayMenuView(menu: Menu(items: items))
        }
        let frameRect = clampedMenuFrame(anchor: anchor, size: view.preferredSize)
        view.frame = frameRect
        container.addSubview(view)
        view.layoutIfNeeded()
        menuLevels.append(MenuLevel(view: view, frame: frameRect, parentActionID: parentActionID))
        return true
    }

    /// Close every panel deeper than `depth`, removing each from the container.
    private func popMenuLevels(toDepth depth: Int) {
        while menuLevels.count > depth {
            let level = menuLevels.removeLast()
            level.view.removeFromSuperview()
        }
    }

    /// The screen anchor for a submenu opened from `rowFrame` in `parent`: just past
    /// the parent's right edge, raised so the submenu's first row aligns with the row.
    private func submenuAnchor(parent: MenuLevel, rowFrame: Rect) -> Point {
        Point(
            x: parent.frame.origin.x + parent.frame.size.width - Self.menuSubmenuOverlap,
            y: parent.frame.origin.y + rowFrame.origin.y - ShellOverlayMenuView.topPadding
        )
    }

    /// Reconcile the submenu for the hovered row of level `li`: open the row's
    /// submenu if it has one and is not already the open child, or close any child
    /// when the row has none. Idempotent so hovering within a row does not churn.
    private func updateSubmenu(forLevel li: Int, hoveredRow idx: Int?) {
        guard li < menuLevels.count else { return }
        let level = menuLevels[li]
        if let idx, let item = level.view.item(at: idx), let submenu = item.submenu, !submenu.isEmpty {
            if menuLevels.count > li + 1, menuLevels[li + 1].parentActionID == item.actionID {
                return
            }
            popMenuLevels(toDepth: li + 1)
            guard let rowFrame = level.view.rowFrame(at: idx) else { return }
            _ = pushMenuLevel(items: submenu, anchor: submenuAnchor(parent: level, rowFrame: rowFrame), parentActionID: item.actionID)
        } else {
            popMenuLevels(toDepth: li + 1)
        }
    }

    /// Open (via keyboard) the submenu of level `li`'s highlighted row and select its
    /// first row. No-op when the row has no submenu.
    private func openHighlightedSubmenu(atLevel li: Int) {
        guard li < menuLevels.count else { return }
        let level = menuLevels[li]
        guard let idx = level.view.highlightedRowIndex, let item = level.view.item(at: idx),
              let submenu = item.submenu, !submenu.isEmpty, let rowFrame = level.view.rowFrame(at: idx)
        else { return }
        popMenuLevels(toDepth: li + 1)
        if pushMenuLevel(items: submenu, anchor: submenuAnchor(parent: level, rowFrame: rowFrame), parentActionID: item.actionID) {
            menuLevels.last?.view.moveHighlight(by: 1)
        }
    }

    private func menuOutputSize() -> Size {
        frame?.outputSizeInPoints ?? Size(width: 4096, height: 4096)
    }

    /// Keyboard handling for the open cascade (the menu grabs the keyboard). The top
    /// panel owns the selection: Up/Down move it, Right/Enter open a submenu or
    /// activate a leaf, Left/Escape close the top panel (Escape at the root
    /// dismisses). Other keys are swallowed so the client beneath stays frozen.
    /// Keycodes are evdev, the value the seat delivers.
    private func handleMenuKey(_ keycode: UInt32) -> ShellOverlayInputResult {
        guard let topIndex = menuLevels.indices.last else {
            return .init(consumed: true, wantsFrame: false, cursor: .default)
        }
        let top = menuLevels[topIndex]
        switch keycode {
        case 1: // KEY_ESC
            if topIndex > 0 {
                popMenuLevels(toDepth: topIndex)
                return .init(consumed: true, wantsFrame: true, cursor: .default)
            }
            let changed = dismissMenu()
            return .init(consumed: true, wantsFrame: changed, cursor: .default)
        case 103: // KEY_UP
            top.view.moveHighlight(by: -1)
            return .init(consumed: true, wantsFrame: true, cursor: .default)
        case 108: // KEY_DOWN
            top.view.moveHighlight(by: 1)
            return .init(consumed: true, wantsFrame: true, cursor: .default)
        case 106: // KEY_RIGHT — descend into the highlighted row's submenu
            openHighlightedSubmenu(atLevel: topIndex)
            return .init(consumed: true, wantsFrame: true, cursor: .default)
        case 105: // KEY_LEFT — close the top submenu (back to its parent)
            if topIndex > 0 { popMenuLevels(toDepth: topIndex) }
            return .init(consumed: true, wantsFrame: true, cursor: .default)
        case 28, 96, 57: // KEY_ENTER, KEY_KPENTER, KEY_SPACE
            if let idx = top.view.highlightedRowIndex, let item = top.view.item(at: idx) {
                if let submenu = item.submenu, !submenu.isEmpty {
                    openHighlightedSubmenu(atLevel: topIndex)
                    return .init(consumed: true, wantsFrame: true, cursor: .default)
                }
                let handler = menuSelectHandler
                let actionID = item.actionID
                _ = dismissMenu()
                handler?(actionID)
                return .init(consumed: true, wantsFrame: true, cursor: .default)
            }
            return .init(consumed: true, wantsFrame: false, cursor: .default)
        default:
            return .init(consumed: true, wantsFrame: false, cursor: .default)
        }
    }

    package var menuVisible: Bool { !menuLevels.isEmpty }

    /// Place a panel so it stays on the output: anchored at `anchor`, shifted up or
    /// left as needed to keep it fully visible (a submenu clamped left lands over its
    /// parent, the on-screen fallback when there is no room to the right).
    private func clampedMenuFrame(anchor: Point, size: Size) -> Rect {
        let output = menuOutputSize()
        let x = max(0, min(anchor.x, output.width - size.width))
        let y = max(0, min(anchor.y, output.height - size.height))
        return Rect(x: x, y: y, width: size.width, height: size.height)
    }

    package func dispatchInput(_ event: ShellOverlayInputEvent) -> ShellOverlayInputResult {
        let pointEvent = frame.map { event.convertedFromBackingPixels($0.backingScaleFactor) } ?? event
        let cursor = cursor(for: pointEvent.location)
        if !menuLevels.isEmpty {
            let location = pointEvent.location
            // The deepest open panel under the pointer; nil when over none of them.
            let hit = menuLevels.lastIndex { $0.frame.contains(location) }
            switch pointEvent.kind {
            case .pointerMove:
                guard let li = hit else {
                    // Over a gap between panels: keep the cascade, change nothing.
                    return .init(consumed: true, wantsFrame: false, cursor: .default)
                }
                let level = menuLevels[li]
                let local = Point(x: location.x - level.frame.origin.x, y: location.y - level.frame.origin.y)
                let idx = level.view.rowIndex(at: local)
                level.view.setHighlightedIndex(idx)
                updateSubmenu(forLevel: li, hoveredRow: idx)
                return .init(consumed: true, wantsFrame: true, cursor: .pointer)
            case .pointerDown where pointEvent.button == 272:
                if hit != nil {
                    return .init(consumed: true, wantsFrame: false, cursor: .pointer)
                }
                let changed = dismissMenu()
                return .init(consumed: true, wantsFrame: changed, cursor: .default)
            case .pointerUp where pointEvent.button == 272:
                let sticky = menuStickyArmed
                menuStickyArmed = false
                guard let li = hit else {
                    // The release of the opening click (over the bar title or empty
                    // space) leaves a freshly opened menu up; a later click outside
                    // dismisses on its own pointer-down before reaching here.
                    if sticky {
                        return .init(consumed: true, wantsFrame: false, cursor: .default)
                    }
                    let changed = dismissMenu()
                    return .init(consumed: true, wantsFrame: changed, cursor: .default)
                }
                let level = menuLevels[li]
                let local = Point(x: location.x - level.frame.origin.x, y: location.y - level.frame.origin.y)
                if let idx = level.view.rowIndex(at: local), let item = level.view.item(at: idx) {
                    if let submenu = item.submenu, !submenu.isEmpty {
                        // A submenu parent opens (or keeps) its child; it never activates.
                        updateSubmenu(forLevel: li, hoveredRow: idx)
                        return .init(consumed: true, wantsFrame: true, cursor: .pointer)
                    }
                    let handler = menuSelectHandler
                    let actionID = item.actionID
                    _ = dismissMenu()
                    handler?(actionID)
                    return .init(consumed: true, wantsFrame: true, cursor: .default)
                }
                return .init(consumed: true, wantsFrame: false, cursor: .pointer)
            case .keyDown:
                return handleMenuKey(pointEvent.keycode)
            default:
                return .init(consumed: true, wantsFrame: false, cursor: hit != nil ? .pointer : .default)
            }
        }

        if pointEvent.kind == .pointerMove {
            return .init(consumed: false, wantsFrame: false, cursor: cursor)
        }

        if (pointEvent.kind == .pointerDown || pointEvent.kind == .pointerUp) && pointEvent.button != 272 {
            return .init(consumed: false, wantsFrame: false, cursor: cursor)
        }

        guard let nucleonEvent = pointEvent.nucleonEvent else {
            return .init(consumed: false, wantsFrame: false, cursor: cursor)
        }

        let targetWindow = windowScene.hitTestWindow(at: pointEvent.location)
        let handled = targetWindow.map { $0.dispatchEvent(nucleonEvent) } == .handled
        if handled {
            if pointEvent.kind == .pointerDown {
                capturedPointerButtons.insert(pointEvent.button)
            } else if pointEvent.kind == .pointerUp {
                capturedPointerButtons.remove(pointEvent.button)
            }
            return .init(
                consumed: true,
                wantsFrame: true,
                cursor: cursor
            )
        }

        if pointEvent.kind == .pointerUp && capturedPointerButtons.remove(pointEvent.button) != nil {
            return .init(consumed: true, wantsFrame: false, cursor: cursor)
        }

        if hotkeyVisible && pointEvent.kind == .pointerDown && pointEvent.button == 272 {
            capturedPointerButtons.insert(pointEvent.button)
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
            expireNotifications(nowNs: nowNs)
            do {
                try notificationListView.advanceArrangedSubviewTransitions(nowNs: nowNs)
            } catch {
                logShellOverlayError("notification transition advance failed: \(error)")
            }
            let publishedScene: PublishedScene
            do {
                publishedScene = try windowScene.publish(
                    placing: hostedSurfaceRegistry.placements()
                ) { window in
                    switch window.role {
                    case .notification, .statusOverlay:
                        true
                    case .application, .shellChrome, .hostedSurface:
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
        var deadline = notificationListView.nextArrangedSubviewTransitionDeadlineNs
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
