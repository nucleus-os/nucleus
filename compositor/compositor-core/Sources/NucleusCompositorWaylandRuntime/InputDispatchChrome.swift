internal import NucleusCompositorServer
import NucleusCompositorServerTypes
internal import NucleusCompositorWindowManager
import Glibc
@MainActor
extension InputDispatch {
    package func chromeHitUnderCursor() -> (windowID: UInt64, surfaceID: UInt64, region: ChromeRegion, edges: UInt32)? {
        let hit = routerHitTest(host: host, sx: cursorX, sy: cursorY)
        let region = ChromeRegion(rawValue: hit.chromeRegion) ?? .content
        if region == .content || hit.windowId == 0 { return nil }
        let surfaceID = windowDriver?.rootSurface(forWindowId: hit.windowId) ?? 0
        return (hit.windowId, surfaceID, region, hit.chromeEdges)
    }

    /// Route a press on server-drawn chrome: focus + raise, then begin a move
    /// (titlebar) / resize (edge) grab, arm a control button, double-click-maximize,
    /// or open the window menu (right-click titlebar). Returns true when the press
    /// was chrome and must not reach the client.
    package func handleChromePress(button: UInt32, timeMsec: UInt32) -> Bool {
        guard let chrome = chromeHitUnderCursor() else { return false }
        armedChromeButton = nil
        raiseWindow(chrome.windowID)
        if chrome.surfaceID != 0,
            windowDriver?.focusSurfaceForPress(surfaceId: UInt32(truncatingIfNeeded: chrome.surfaceID)) == true {
            setKeyboardFocusSurface(chrome.surfaceID)
        }
        switch chrome.region {
        case .titlebar:
            if button == btnRight {
                showWindowMenuForWindow(chrome.windowID)
                return true
            }
            if button != btnLeft { return true }
            if isTitlebarDoubleClick(windowID: chrome.windowID, timeMsec: timeMsec) {
                lastTitlebarPress = nil
                if chrome.surfaceID != 0 {
                    windowDriver?.toggleMaximize(surfaceId: UInt32(truncatingIfNeeded: chrome.surfaceID))
                }
                return true
            }
            lastTitlebarPress = (chrome.windowID, timeMsec)
            beginInteractiveMoveFromChrome(windowID: chrome.windowID)
        case .resize:
            if button == btnLeft {
                beginInteractiveResizeFromChrome(windowID: chrome.windowID, edges: chrome.edges)
            }
        case .closeButton, .minimizeButton, .maximizeButton:
            if button == btnLeft {
                armedChromeButton = (chrome.windowID, chrome.region)
                updateChromeButtonVisual(windowID: chrome.windowID, region: chrome.region)
            }
        default:
            return false
        }
        return true
    }

    /// On release of an armed control button, fire its verb iff the cursor is still
    /// over the same button; a drifted release cancels.
    package func handleChromeButtonRelease() {
        guard let armed = armedChromeButton else { return }
        armedChromeButton = nil
        let chrome = chromeHitUnderCursor()
        if let chrome, chrome.windowID == armed.windowID, chrome.region == armed.region {
            switch armed.region {
            case .closeButton:
                if chrome.surfaceID != 0 { windowDriver?.close(surfaceId: UInt32(truncatingIfNeeded: chrome.surfaceID)) }
            case .maximizeButton:
                if chrome.surfaceID != 0 { windowDriver?.toggleMaximize(surfaceId: UInt32(truncatingIfNeeded: chrome.surfaceID)) }
            case .minimizeButton:
                _ = windowDriver?.minimize(windowId: armed.windowID)
            default:
                break
            }
        }
        if let chrome {
            updateChromeButtonVisual(windowID: chrome.windowID, region: chrome.region)
        } else {
            updateChromeButtonVisual(windowID: 0, region: .content)
        }
    }

    /// Reconcile the traffic-light highlight with the cursor: light the hovered
    /// button, darken it while armed, and clear the prior window when the highlight
    /// moves off. Pushes only on change, keyed by the root surface id.
    package func updateChromeButtonVisual(windowID: UInt64, region: ChromeRegion) {
        var targetID: UInt64 = 0
        var targetRoot: UInt64 = 0
        var hovered: UInt32 = 0
        var pressed: UInt32 = 0
        if windowID != 0 {
            let code = chromeButtonCode(region)
            if code != 0, let root = windowDriver?.rootSurface(forWindowId: windowID), root != 0 {
                targetID = windowID
                targetRoot = root
                hovered = code
                if let armed = armedChromeButton, armed.windowID == windowID,
                    chromeButtonCode(armed.region) == code {
                    pressed = code
                }
            }
        }
        if let prev = chromeButtonVisual {
            if prev.windowID == targetID && prev.hovered == hovered && prev.pressed == pressed { return }
            if prev.windowID != targetID && (prev.hovered != 0 || prev.pressed != 0) {
                host.feeder?.setChromeButtonState(rootSurfaceID: prev.rootSurface, hovered: 0, pressed: 0)
            }
        }
        if targetID == 0 {
            chromeButtonVisual = nil
            return
        }
        host.feeder?.setChromeButtonState(rootSurfaceID: targetRoot, hovered: hovered, pressed: pressed)
        chromeButtonVisual = (targetID, targetRoot, hovered, pressed)
    }

    /// Open the per-window menu at the cursor (right-click titlebar / menu keybind).
    package func showWindowMenuForWindow(_ windowID: UInt64) {
        guard windowID != 0 else { return }
        host.server.shellPolicy?.overlaySceneShowWindowMenu(
            windowID: windowID,
            x: cursorX,
            y: cursorY,
            capabilities: host.server.windowCapabilities(id: windowID))
    }

    package func isTitlebarDoubleClick(windowID: UInt64, timeMsec: UInt32) -> Bool {
        guard let prev = lastTitlebarPress, prev.windowID == windowID else { return false }
        // The wrapping evdev millisecond clock; the interval is tiny next to the wrap.
        return (timeMsec &- prev.timeMsec) <= doubleClickIntervalMsec
    }

    /// 1-based control-button code for the scene author (1 close, 2 minimize, 3 maximize).
    package func chromeButtonCode(_ region: ChromeRegion) -> UInt32 {
        switch region {
        case .closeButton: return 1
        case .minimizeButton: return 2
        case .maximizeButton: return 3
        default: return 0
        }
    }

    package func resizeCursorName(edges: UInt32) -> String {
        let left = edges & 1 != 0, right = edges & 2 != 0, top = edges & 4 != 0, bottom = edges & 8 != 0
        if (top && left) || (bottom && right) { return "nwse-resize" }
        if (top && right) || (bottom && left) { return "nesw-resize" }
        if left || right { return "ew-resize" }
        if top || bottom { return "ns-resize" }
        return "default"
    }

    package func applyNamedCursor(_ name: String) {
        host.server.shellPolicy?.cursorApplyNamed(name)
        requestCursorFrame()
    }

    package func applyCursorIntent(_ intent: CursorIntent) {
        guard intent != appliedCursorIntent else { return }
        switch intent {
        case .named(let name):
            applyNamedCursor(name)
        case .client:
            if cursorFromXwayland {
                _ = host.xwaylandHost?.xwm?.applyCurrentCursor()
            } else if let compositor = host.runtime?.compositor {
                _ = host.pointerCursorSurface.reapplyCurrent(from: compositor)
            }
            requestCursorFrame()
        }
        appliedCursorIntent = intent
    }

    package func requestCursorFrame(
        previousX: Double? = nil,
        previousY: Double? = nil
    ) {
        RenderBridge.requestCursorFrame(
            server: host.server,
            previousX: previousX,
            previousY: previousY)
    }

    // MARK: - interactive move/resize grab

    package func startRect(from r: (x: Double, y: Double, w: Double, h: Double)) -> WireWindowRect {
        var rect = WireWindowRect()
        rect.x = r.x
        rect.y = r.y
        rect.width = UInt32(max(1, r.w))
        rect.height = UInt32(max(1, r.h))
        return rect
    }

    package func beginInteractiveMoveFromChrome(windowID: UInt64) {
        guard windowID != 0, let wd = windowDriver, wd.canInteract(windowId: windowID) else { return }
        raiseWindow(windowID)
        let tile = host.server.window(id: windowID)?.tileEdges
        let hadTile = tile.map { $0.left || $0.right || $0.top || $0.bottom } ?? false
        guard let presented = host.feeder?.presentedWindow(windowID: windowID)?.frame,
              let r = wd.beginDirectManipulation(windowId: windowID, presented: presented)
        else { return }
        // Drag start un-tiles so the client redraws full decorations.
        if hadTile { wd.configureInteractive(windowId: windowID, resizing: false) }
        host.windowManager.seedInteractiveStartContext(
            windowID: windowID, cursorX: cursorX, cursorY: cursorY, startRect: startRect(from: r))
        host.windowManager.beginInteractiveMove(windowID: windowID, serial: 0)
        clearPointerFocusSurface()
        applyNamedCursor("grabbing")
    }

    package func beginInteractiveResizeFromChrome(windowID: UInt64, edges: UInt32) {
        guard edges != 0, windowID != 0, let wd = windowDriver, wd.canInteract(windowId: windowID) else { return }
        raiseWindow(windowID)
        guard let presented = host.feeder?.presentedWindow(windowID: windowID)?.frame,
              let r = wd.beginDirectManipulation(windowId: windowID, presented: presented)
        else { return }
        var re = WireResizeEdges()
        re.left = edges & 1 != 0
        re.right = edges & 2 != 0
        re.top = edges & 4 != 0
        re.bottom = edges & 8 != 0
        host.windowManager.seedInteractiveStartContext(
            windowID: windowID, cursorX: cursorX, cursorY: cursorY, startRect: startRect(from: r))
        host.windowManager.beginInteractiveResize(windowID: windowID, serial: 0, edges: re)
        wd.configureInteractive(windowId: windowID, resizing: true)
        clearPointerFocusSurface()
    }

    package func updateInteractiveGrab() {
        guard let update = host.windowManager.updateInteractiveGrab(
            cursorX: cursorX,
            cursorY: cursorY)
        else { return }
        let windowID = update.windowId
        let previousRect = host.server
            .window(id: windowID)?.currentRect()
        if update.needsResizeConfigure {
            // Keep presenting the last client-committed buffer at its native
            // logical size. The new frame lands atomically with the client's
            // acked configure instead of stretching stale pixels under the drag.
            windowDriver?.configureInteractive(
                windowId: windowID, resizing: true, targetRect: update.rect)
        } else {
            windowDriver?.previewInteractiveRect(
                windowId: windowID, x: update.rect.x, y: update.rect.y,
                w: Double(update.rect.width), h: Double(update.rect.height))
        }
        RenderBridge.requestFrame(
            server: host.server,
            forWindowID: windowID,
            includingPreviousRect: previousRect)
    }

    package func finishInteractiveGrab(timeMsec: UInt32) {
        let finalResize = host.windowManager.updateInteractiveGrab(
            cursorX: cursorX, cursorY: cursorY)
        host.windowManager.endInteractiveGrab()
        if let finalResize, finalResize.needsResizeConfigure {
            // Clear xdg_toplevel.state.resizing and carry the final requested
            // geometry in the same configure cycle.
            windowDriver?.configureInteractive(
                windowId: finalResize.windowId,
                resizing: false,
                targetRect: finalResize.rect)
        }
        // Re-run targeting at the current cursor so focus/cursor settle post-grab.
        var motion = WireEventRecord()
        motion.kind = .mouseMoved
        motion.flags = streamFlags
        motion.timestampNs = UInt64(timeMsec) &* 1_000_000
        motion.x = cursorX
        motion.y = cursorY
        processCursorMotion(motion)
    }

    // MARK: - state cache + helpers

}
