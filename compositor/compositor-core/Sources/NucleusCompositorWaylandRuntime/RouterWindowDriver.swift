// Drives the authoritative Swift window model from the libwayland router's shell /
// scene / decoration / activation / foreign delegates. This is the protocol→model
// adapter wired to every shell global by the live router host.
//
// It owns the toplevel→WindowID identity table and turns xdg-shell events into
// NucleusCompositorServer / WindowManager operations, reusing the live ConfigurePolicy serial
// machine end to end:
//   configure(initial:false) → WindowManager.planConfigure  (size + states)
//   toplevelConfigureSent     → WindowManager.recordConfigureSent (queue the serial)
//   toplevelDidCommit         → Window.consumeAckedConfigure   (latch the ack)
// The configure-serial handshake is split across configure()/configureSent because
// the router mints and sends the serial between those two calls.
//
// Isolation discipline: the router calls these delegates from libwayland's C dispatch
// (a nonisolated context); the model is @MainActor. Each nonisolated thunk extracts
// only Sendable tokens from the router objects — the toplevel's pointer (a stable
// per-lifetime identity key) and surface/parent wire ids — and crosses those into a
// `MainActor.assumeIsolated` block (sound because the runtime drives dispatch on the
// main actor). The @MainActor side re-resolves any router object it needs by id
// through the compositor/seat. No non-Sendable router object ever crosses or is
// stored in main-actor state; the identity table is keyed and valued by Sendables.

import WaylandServerC
@_spi(NucleusCompositor) import NucleusLayers
import NucleusCompositorServer
import NucleusCompositorServerTypes
import NucleusCompositorWindowManager

@MainActor
final class RouterWindowDriver {
    private let seatDriver: RouterSeatDriver
    /// Re-resolves surfaces by wire id (the Sendable token crossed from the
    /// nonisolated scene-delegate thunks) so no non-Sendable WlSurface is stored.
    private let compositor: WlCompositor
    /// Feeds the authoritative window model into the scene author (window map/unmap
    /// + per-commit content publish). Protocol-only fixtures pass nil, so their
    /// protocol→model assertions do not require a render scene.
    private let feeder: SceneFeeder?

    /// Per-toplevel record, keyed by the toplevel's pointer token. `pendingPlan` is
    /// stashed between `configure(for:)` and the matching `toplevelConfigureSent`
    /// (the router mints the serial between them); `replanReason` carries the reason
    /// from a state request into the re-plan configure it triggers. All Sendable.
    private struct ToplevelEntry {
        let windowID: WindowID
        var pendingPlan: ConfigurePlan?
        var replanReason: ConfigureReason = .focusState
    }
    private var byToplevel: [UInt: ToplevelEntry] = [:]

    /// The surface-import / scene-publish half (owned): the SurfaceSceneDelegate thunks
    /// forward to it, and it shares this driver's `compositor` + `feeder`. Keeping it a
    /// composed helper (rather than reassigning `compositor.sceneDelegate`) lets the
    /// coupled `surfaceDestroyed` (scene teardown + seat unmap) stay coherent here.
    private let sceneDriver: RouterSurfaceSceneDriver

    init(seatDriver: RouterSeatDriver, compositor: WlCompositor, feeder: SceneFeeder? = nil) {
        self.seatDriver = seatDriver
        self.compositor = compositor
        self.feeder = feeder
        self.sceneDriver = RouterSurfaceSceneDriver(compositor: compositor, feeder: feeder)
    }

    // MARK: - configure helpers (main-actor, Sendable-only inputs)

    /// Ensure a Window + XdgRole exist for the toplevel token, creating them on first
    /// sight and seeding the surface link + server-side-decoration style.
    @discardableResult
    private func ensureWindow(token: UInt, surfaceId: UInt32) -> WindowID? {
        if let entry = byToplevel[token] { return entry.windowID }
        let wm = WindowManager.shared
        let windowID = wm.xdgCreated(xdgToplevelID: UInt64(token))
        if let window = wm.server.window(id: windowID) {
            window.surfaceObjectId = surfaceId
            // Managed xdg toplevels are server-side decorated (see Window.styleMask).
            window.styleMask = .titledResizable
        }
        byToplevel[token] = ToplevelEntry(windowID: windowID)
        return windowID
    }

    private func windowID(forSurfaceId id: UInt32) -> WindowID? {
        guard id != 0 else { return nil }
        // Route through the O(1) surfaceObjectId index rather than an O(n) scan: this
        // resolves the surface's window on every commit/configure/parent path.
        return WindowManager.shared.server.windows.window(bySurfaceObjectId: id)?.id
    }

    /// The tiled-edge states a server-side-decorated window carries so the client
    /// renders rectangular (no client-side rounding). Mirrors the legacy
    /// `rectangularStateMask`; empty for a borderless window.
    private func rectangularStateMask(_ window: Window) -> XdgStateMask {
        window.styleMask == .titledResizable ? [.tiledLeft, .tiledRight, .tiledTop, .tiledBottom] : []
    }

    /// Serialize an XdgStateMask into the wire xdg_toplevel.state values in canonical
    /// order (mirrors the legacy `stateBytes`): 1=maximized 2=fullscreen 3=resizing
    /// 4=activated 5..8=tiled left/right/top/bottom. Fullscreen suppresses the tiled
    /// and maximized states.
    private func wireStates(_ mask: XdgStateMask) -> [UInt32] {
        var states: [UInt32] = []
        if mask.contains(.activated) { states.append(4) }
        if mask.contains(.fullscreen) {
            states.append(2)
        } else {
            if mask.contains(.maximized) { states.append(1) }
            if mask.contains(.tiledLeft) { states.append(5) }
            if mask.contains(.tiledRight) { states.append(6) }
            if mask.contains(.tiledTop) { states.append(7) }
            if mask.contains(.tiledBottom) { states.append(8) }
        }
        if mask.contains(.resizing) { states.append(3) }
        return states
    }

    private func isFocused(_ windowID: WindowID) -> Bool {
        WindowManager.shared.server.windows.focusedWindow?.id == windowID
    }

    func configureImpl(token: UInt, surfaceId: UInt32, initial: Bool) -> XdgToplevelConfigure {
        let wm = WindowManager.shared
        guard let windowID = ensureWindow(token: token, surfaceId: surfaceId),
            let window = wm.server.window(id: windowID)
        else { return XdgToplevelConfigure() }
        if initial {
            // First configure: 0×0 (the client self-sizes) carrying the rectangular
            // states. The empty pending configure is queued in toplevelConfigureSent.
            return XdgToplevelConfigure(width: 0, height: 0, states: wireStates(rectangularStateMask(window)))
        }
        if let plan = byToplevel[token]?.pendingPlan {
            let content = window.contentRect(forFrameRect: plan.targetRect)
            var mask = plan.stateMask
            mask.formUnion(rectangularStateMask(window))
            return XdgToplevelConfigure(
                width: Int32(content.width), height: Int32(content.height), states: wireStates(mask))
        }
        let reason = byToplevel[token]?.replanReason ?? .focusState
        let request = ConfigureRequest(
            windowID: windowID, reason: reason, targetRect: nil, targetOutputID: nil,
            activated: isFocused(windowID), resizing: false, tileEdges: window.tileEdges)
        guard let plan = wm.planConfigure(request) else {
            return XdgToplevelConfigure(width: 0, height: 0, states: wireStates(rectangularStateMask(window)))
        }
        byToplevel[token]?.pendingPlan = plan
        // The client owns only its content: configure to the content rect (the frame
        // minus the chrome insets); the compositor draws the chrome band.
        let content = window.contentRect(forFrameRect: plan.targetRect)
        var mask = plan.stateMask
        mask.formUnion(rectangularStateMask(window))
        return XdgToplevelConfigure(
            width: Int32(content.width), height: Int32(content.height), states: wireStates(mask))
    }

    func configureSentImpl(token: UInt, serial: UInt32, initial: Bool) {
        let wm = WindowManager.shared
        guard let entry = byToplevel[token], let window = wm.server.window(id: entry.windowID) else { return }
        if initial {
            _ = window.protocolState.queueConfigure(
                rect: WindowRect(), activeMaximized: false, activeFullscreen: false,
                specialOutputID: nil, layoutTransitionID: 0, serial: serial)
        } else if let plan = entry.pendingPlan {
            let pending = wm.recordConfigureSent(windowID: entry.windowID, serial: serial, plan: plan)
            // The compositor has committed to a new slot: begin a tiling spring toward
            // the configured frame. The presented frame eases there at the display rate
            // while the client renders its new-size buffer (scaled onto the eased frame),
            // settling once that buffer commits. A redundant configure toward the current
            // presented frame leaves the curve untouched (no stutter / no 1-frame no-op).
            if plan.shouldPresent, plan.layoutTransitionID != 0,
               let slot = pending?.slotGeneration {
                let finalRect = PresentationRect(
                    x: plan.targetRect.x, y: plan.targetRect.y,
                    w: Double(plan.targetRect.width), h: Double(plan.targetRect.height))
                if !window.presentationActor.targetMatches(finalRect) {
                    window.beginPresentationTileAnimation(finalRect: finalRect, slotGeneration: slot)
                }
            }
            byToplevel[token]?.pendingPlan = nil
        }
    }

    func didCommitImpl(
        token: UInt, surfaceId: UInt32, ackedSerial: UInt32,
        geom: WlRect?, hasBuffer: Bool
    ) {
        let wm = WindowManager.shared
        guard let entry = byToplevel[token], let window = wm.server.window(id: entry.windowID) else { return }
        guard hasBuffer else {
            if window.mapped {
                window.mapped = false
                feeder?.windowUnmapped(surfaceID: surfaceId)
                seatDriver.surfaceUnmapped(surfaceId: surfaceId)
            }
            return
        }
        // Latch the configure the client acked (active maximize/fullscreen + the
        // layout position from the configured rect).
        let acceptedConfigure = window.consumeAckedConfigure(serial: ackedSerial)
        // Visible content is the declared window geometry (a sub-rect of the buffer);
        // absent a geometry, the last committed logical size stands.
        let contentW = geom.map { UInt32(max(1, $0.width)) } ?? UInt32(max(1, window.committedLogicalSize.w))
        let contentH = geom.map { UInt32(max(1, $0.height)) } ?? UInt32(max(1, window.committedLogicalSize.h))
        window.committedLogicalSize = RenderSize(w: Double(contentW), h: Double(contentH))

        let firstMap = !window.mapped
        var x = window.policyState.x
        var y = window.policyState.y
        if firstMap {
            window.mapped = true
            // Floating first-map centering (over a mapped parent, else on the output);
            // nil for special modes, which keep their configured origin.
            if let rect = wm.centeredFirstMapRect(
                windowID: entry.windowID, contentWidth: contentW, contentHeight: contentH)
            {
                x = rect.x
                y = rect.y
            }
            // A freshly-mapped toplevel takes keyboard focus.
            wm.server.windows.focus(id: entry.windowID)
            seatDriver.setKeyboardFocus(toSurfaceId: surfaceId)
        }
        // The visible content sits at the negated xdg window-geometry origin within
        // the buffer (clients wrap the window in invisible margins); the scene feeder
        // shifts the backing by this so the geometry sub-rect aligns with the content
        // viewport. Absent a geometry the whole buffer is the content.
        window.contentOffsetInSlot = geom.map { WindowContentOffset(x: -Double($0.x), y: -Double($0.y)) } ?? .init()
        // The frame rect is the outer rectangle: visible content expanded by the
        // chrome insets, positioned at the latched / first-map origin.
        let insets = window.chromeInsets
        let frameW = UInt32(max(1, Double(contentW) + insets.horizontal))
        let frameH = UInt32(max(1, Double(contentH) + insets.vertical))
        let committedFrame = WindowRect(x: x, y: y, width: frameW, height: frameH)
        window.acceptCommittedFrame(committedFrame)
        // Do not let an older acknowledged commit erase a newer configure request.
        // Requested and committed geometry converge only once the configure queue
        // has drained; presentation remains a third, independently sampled state.
        if !window.protocolState.hasPending {
            window.setRequestedFrame(committedFrame)
        }
        if firstMap {
            // Snap the presentation actor to the first presented frame — no animation
            // on first appearance (the open fade covers that); subsequent re-tiles ease
            // from here. Hand the freshly-mapped window to the scene author: it self-
            // allocates the window's scene tree (root/content/popup/backing) and hosts
            // it beneath the compositor root at the window's outer frame.
            window.seedPresentationActorToRect(
                PresentationRect(x: x, y: y, w: Double(frameW), h: Double(frameH)),
                slotGeneration: window.presentationActor.currentSlotGeneration)
            feeder?.windowMapped(
                surfaceID: surfaceId, x: x, y: y, width: Double(frameW), height: Double(frameH))
        } else if acceptedConfigure?.layoutTransitionID == 0 {
            window.seedPresentationActorToRect(
                PresentationRect(x: x, y: y, w: Double(frameW), h: Double(frameH)),
                slotGeneration: acceptedConfigure?.slotGeneration
                    ?? window.presentationActor.currentSlotGeneration)
        }
    }

    func setTitleImpl(token: UInt, _ title: String) {
        WindowManager.shared.server.window(id: byToplevel[token]?.windowID ?? 0)?.title = title
    }

    func setAppIdImpl(token: UInt, _ appId: String) {
        WindowManager.shared.server.window(id: byToplevel[token]?.windowID ?? 0)?.appId = appId
    }

    func setParentImpl(token: UInt, parentToken: UInt?) {
        guard let windowID = byToplevel[token]?.windowID else { return }
        let parentID = parentToken.flatMap { byToplevel[$0]?.windowID }
        WindowManager.shared.xdgSetParent(windowID: windowID, parentWindowID: parentID)
    }

    func setMaximizedImpl(token: UInt, _ on: Bool) {
        let wm = WindowManager.shared
        guard let windowID = byToplevel[token]?.windowID else { return }
        if on { wm.server.window(id: windowID)?.requestedFullscreen = false }
        wm.xdgRequestMaximize(windowID: windowID, requested: on)
        byToplevel[token]?.replanReason = on ? .maximize : .restore
    }

    func setFullscreenImpl(
        token: UInt, _ on: Bool, outputID: UInt64?
    ) {
        let wm = WindowManager.shared
        guard let windowID = byToplevel[token]?.windowID else { return }
        if on {
            wm.xdgRequestFullscreen(windowID: windowID, target: outputID)
        } else {
            wm.xdgUnsetFullscreen(windowID: windowID)
        }
        byToplevel[token]?.replanReason = on ? .fullscreen : .restore
    }

    func willDestroyImpl(token: UInt, surfaceId: UInt32) {
        let wm = WindowManager.shared
        guard let entry = byToplevel.removeValue(forKey: token) else { return }
        // Tear the window's scene down (unhost from the compositor root + remove its
        // layer tree) before the model window goes away.
        feeder?.windowUnmapped(surfaceID: surfaceId)
        seatDriver.surfaceUnmapped(surfaceId: surfaceId)
        wm.xdgDestroyed(windowID: entry.windowID)
        wm.server.destroyWindow(id: entry.windowID)
    }

    func activateSurfaceImpl(surfaceId: UInt32) {
        guard let windowID = windowID(forSurfaceId: surfaceId) else { return }
        WindowManager.shared.server.windows.raise(id: windowID)
        WindowManager.shared.server.windows.focus(id: windowID)
        seatDriver.setKeyboardFocus(toSurfaceId: surfaceId)
    }

    /// Pointer press activation from the hit-test path. The
    /// router-owned model raises/focuses the window family; the input path remains the sole
    /// wl_keyboard enter/leave sender until the seat focus resolver moves fully
    /// into the router, so this returns whether the caller should move keyboard focus.
    func focusSurfaceForPress(surfaceId: UInt32) -> Bool {
        guard let windowID = windowID(forSurfaceId: surfaceId),
            let window = WindowManager.shared.server.window(id: windowID)
        else { return false }
        WindowManager.shared.server.windows.raise(id: windowID)
        WindowManager.shared.server.windows.focus(id: windowID)
        return window.wantsKeyboardFocus
    }

    func setForeignParentImpl(childSurfaceId: UInt32, parentSurfaceId: UInt32?) {
        guard let childID = windowID(forSurfaceId: childSurfaceId) else { return }
        WindowManager.shared.xdgSetParent(
            windowID: childID, parentWindowID: parentSurfaceId.flatMap { windowID(forSurfaceId: $0) })
    }

    func surfaceDestroyedImpl(surfaceId: UInt32) {
        seatDriver.surfaceUnmapped(surfaceId: surfaceId)
    }

    func defaultLayerOutputRectImpl() -> WlRect? {
        let layout = NucleusCompositorServer.shared.layout
        guard let id = layout.primaryDisplayID() ?? layout.displays.first?.id,
            let display = layout.display(id: id)
        else { return nil }
        let r = display.logicalRect
        return WlRect(
            x: Int32(r.x), y: Int32(r.y),
            width: Int32(max(1, r.width)), height: Int32(max(1, r.height)))
    }

    // MARK: - imperative window commands (driven from the input feed by surface id)
    //
    // The input/shortcut path resolves the acted-on surface (the
    // focused surface, the hit-tested surface) and crosses its wire id here. These
    // replace the deleted `roleX-for-Window` dispatch bridge: they resolve the
    // surface to its xdg-toplevel (the surface's assigned role) and the model window,
    // apply the state change, and re-drive the live configure cycle.

    /// The xdg-toplevel role bound to a surface wire id, or nil if the surface is not
    /// a mapped toplevel (a layer/lock/popup surface, or no surface).
    private func toplevel(forSurfaceId id: UInt32) -> XdgToplevel? {
        guard id != 0, let surface = compositor.surface(id: id) else { return nil }
        return (surface.role as? XdgSurface)?.toplevel
    }

    /// The window-source kind owning a surface (the wire `WindowSource` rawValue:
    /// 1=xdg 2=xwayland 3=layerShell 4=lock), or 0 if no window owns it. The
    /// session-lock + input gates read this in place of the deleted `findWindowForSurface`.
    func windowSource(forSurfaceId id: UInt32) -> UInt32 {
        WindowManager.shared.server.windows.window(bySurfaceObjectId: id)?.source.rawValue ?? 0
    }

    func windowId(forSurfaceId id: UInt32) -> UInt64 {
        windowID(forSurfaceId: id) ?? 0
    }

    func windowOutput(forSurfaceId id: UInt32) -> UInt64 {
        guard let windowID = windowID(forSurfaceId: id),
            let window = WindowManager.shared.server.window(id: windowID)
        else { return 0 }
        return window.currentOutputID ?? 0
    }

    func currentAnimatedRect(forSurfaceId id: UInt32) -> (x: Double, y: Double, w: Double, h: Double)? {
        guard let windowID = windowID(forSurfaceId: id),
            let window = WindowManager.shared.server.window(id: windowID)
        else { return nil }
        let rect = window.currentAnimatedRect()
        return (rect.x, rect.y, rect.w, rect.h)
    }

    /// Focus + raise the window owning `surfaceId` (click-to-focus / activation).
    func activate(surfaceId: UInt32) {
        activateSurfaceImpl(surfaceId: surfaceId)
    }

    /// Publish keyboard-focus activation state after the focus
    /// resolver has already sent wl_keyboard enter/leave. This intentionally avoids
    /// `seatDriver.setKeyboardFocus` so the wire seat events are not duplicated.
    func publishKeyboardFocus(oldSurfaceId: UInt32, newSurfaceId: UInt32) {
        let oldToplevel = toplevel(forSurfaceId: oldSurfaceId)
        let newToplevel = toplevel(forSurfaceId: newSurfaceId)
        if let windowID = windowID(forSurfaceId: newSurfaceId) {
            WindowManager.shared.server.windows.focus(id: windowID)
        }
        if oldSurfaceId != newSurfaceId {
            oldToplevel?.xdgSurface?.configureToplevel(initial: false)
        }
        newToplevel?.xdgSurface?.configureToplevel(initial: false)
    }

    /// Toggle the maximized state of the toplevel owning `surfaceId`, mutating the
    /// model and re-driving a configure (the imperative analog of a client
    /// set/unset_maximized, for a window-management shortcut).
    func toggleMaximize(surfaceId: UInt32) {
        guard let toplevel = toplevel(forSurfaceId: surfaceId),
            let windowID = windowID(forSurfaceId: surfaceId),
            let window = WindowManager.shared.server.window(id: windowID)
        else { return }
        setMaximizedImpl(token: token(toplevel), !window.requestedMaximized)
        toplevel.xdgSurface?.configureToplevel(initial: false)
    }

    /// Toggle the fullscreen state of the toplevel owning `surfaceId`.
    func toggleFullscreen(surfaceId: UInt32) {
        guard let toplevel = toplevel(forSurfaceId: surfaceId),
            let windowID = windowID(forSurfaceId: surfaceId),
            let window = WindowManager.shared.server.window(id: windowID)
        else { return }
        setFullscreenImpl(
            token: token(toplevel), !window.requestedFullscreen, outputID: nil)
        toplevel.xdgSurface?.configureToplevel(initial: false)
    }

    /// Ask the toplevel owning `surfaceId` to close (xdg_toplevel.close).
    func close(surfaceId: UInt32) {
        toplevel(forSurfaceId: surfaceId)?.sendClose()
    }

    /// Keybind-driven tile/maximize for a router-owned xdg toplevel.
    func tile(surfaceId: UInt32, command: UInt32) -> Bool {
        let wm = WindowManager.shared
        guard let toplevel = toplevel(forSurfaceId: surfaceId),
            let windowID = windowID(forSurfaceId: surfaceId),
            let window = wm.server.window(id: windowID),
            let cmd = TileCommand(rawValue: command)
        else { return false }

        let layout = NucleusCompositorServer.shared.layout
        let outputID = window.currentOutputID ?? layout.primaryDisplayID() ?? layout.displays.first?.id ?? 0
        guard outputID != 0, let output = layout.display(id: outputID) else { return false }
        let r = output.logicalRect
        let zones = wm.layerShellPolicy.recalcZones(outputID: outputID) ?? LayerExclusiveZones()
        let usable = LogicalRect(
            x: r.x + Double(zones.left),
            y: r.y + Double(zones.top),
            width: max(1, r.width - Double(zones.left) - Double(zones.right)),
            height: max(1, r.height - Double(zones.top) - Double(zones.bottom)))
        let tilePlan = wm.tileRegion(command: cmd, output: usable)

        switch tilePlan.action {
        case .none:
            return false
        case .maximize:
            setMaximizedImpl(token: token(toplevel), true)
            toplevel.xdgSurface?.configureToplevel(initial: false)
            return true
        case .tile:
            let request = ConfigureRequest(
                windowID: windowID,
                reason: .tile,
                targetRect: tilePlan.rect,
                targetOutputID: outputID,
                activated: isFocused(windowID),
                resizing: false,
                tileEdges: tilePlan.edges)
            guard let plan = wm.planConfigure(request), plan.shouldConfigure else { return false }
            byToplevel[token(toplevel)]?.pendingPlan = plan
            byToplevel[token(toplevel)]?.replanReason = .tile
            toplevel.xdgSurface?.configureToplevel(initial: false)
            return true
        }
    }

    // MARK: - chrome / interaction crossings (driven from the input feed by window id)
    //
    // The chrome-press + interactive-move/resize path keys on the
    // model window id. These resolve
    // the model window and its xdg-toplevel and apply the presentation/configure
    // effects.

    /// The xdg-toplevel role bound to a model window id, via its root surface.
    private func toplevel(forWindowId id: UInt64) -> XdgToplevel? {
        guard let window = WindowManager.shared.server.window(id: id), window.surfaceObjectId != 0
        else { return nil }
        return toplevel(forSurfaceId: window.surfaceObjectId)
    }

    /// The root (xdg) surface wire id of a model window, or 0. Backs the chrome
    /// path's surface-keyed verb crossings (close / maximize) and the traffic-light
    /// visual (router scenes are keyed by the root surface object id).
    func rootSurface(forWindowId id: UInt64) -> UInt64 {
        UInt64(WindowManager.shared.server.window(id: id)?.surfaceObjectId ?? 0)
    }

    /// Minimize the model window: hide it from the scene (`visibleInScene` → false)
    /// and from input. Returns whether the state changed (so the caller clears
    /// seat focus + requests a frame only when it did). xdg has no minimized
    /// configure, so the client is not told.
    func minimize(windowId id: UInt64) -> Bool {
        guard let window = WindowManager.shared.server.window(id: id),
            window.mapped, !window.minimized
        else { return false }
        window.minimized = true
        return true
    }

    /// Un-minimize the model window: restore it to the scene and to input. Returns
    /// whether the state changed, so the caller re-renders only when it did. The
    /// symmetric counterpart to `minimize`; without it a foreign-toplevel
    /// `unset_minimized`/`activate` on a minimized window would be a permanent
    /// dead-end (the window stays `visibleInScene()==false` forever).
    @discardableResult
    func unminimize(windowId id: UInt64) -> Bool {
        guard let window = WindowManager.shared.server.window(id: id), window.minimized
        else { return false }
        window.minimized = false
        return true
    }

    /// Whether `windowId` can begin a compositor-driven interactive move/resize:
    /// mapped and not in a requested/active maximized or fullscreen mode.
    func canInteract(windowId id: UInt64) -> Bool {
        guard let window = WindowManager.shared.server.window(id: id) else { return false }
        return window.mapped
            && !window.requestedFullscreen && !window.requestedMaximized
            && !window.activeFullscreen && !window.activeMaximized
    }

    /// Begin direct manipulation of `windowId`: snap the presentation actor to the
    /// live animated rect (clearing any in-flight tile spring) and adopt it as the
    /// layout rect, returning that start rect. Returns nil if no such window.
    func beginDirectManipulation(
        windowId id: UInt64, presented: PresentationRect
    ) -> (x: Double, y: Double, w: Double, h: Double)? {
        guard let window = WindowManager.shared.server.window(id: id) else { return nil }
        let w = max(1.0, presented.w.rounded(.up)).rounded(.towardZero)
        let h = max(1.0, presented.h.rounded(.up)).rounded(.towardZero)
        let rect = WindowRect(x: presented.x, y: presented.y, width: UInt32(w), height: UInt32(h))
        window.moveRequestedAndCommittedFrame(to: rect)
        window.seedPresentationActorToRect(
            PresentationRect(x: rect.x, y: rect.y, w: Double(rect.width), h: Double(rect.height)),
            slotGeneration: window.presentationActor.currentSlotGeneration)
        return (rect.x, rect.y, Double(rect.width), Double(rect.height))
    }

    /// Apply the live grab preview rect to `windowId`: adopt it as the layout rect
    /// and snap the presented frame to it (no animation), so the SceneFeeder authors
    /// the window at the dragged position. Mirrors `InteractionRuntime.previewInteractiveRect`.
    func previewInteractiveRect(windowId id: UInt64, x: Double, y: Double, w: Double, h: Double) {
        guard let window = WindowManager.shared.server.window(id: id) else { return }
        let rect = WindowRect(x: x, y: y, width: UInt32(max(1.0, w)), height: UInt32(max(1.0, h)))
        window.moveRequestedAndCommittedFrame(to: rect)
        window.seedPresentationActorToRect(
            PresentationRect(x: x, y: y, w: Double(rect.width), h: Double(rect.height)),
            slotGeneration: window.presentationActor.currentSlotGeneration)
    }

    /// Drive an interactive-grab configure for `windowId`'s toplevel at its current
    /// model rect: a move-reason configure (untile) when `resizing` is false, a
    /// resize-reason configure (the dragged size) when true. Mirrors the retired
    /// `WaylandSwiftDispatch.roleConfigureForWindow` for the router path.
    func configureInteractive(
        windowId id: UInt64, resizing: Bool, targetRect: WireWindowRect? = nil
    ) {
        let wm = WindowManager.shared
        guard let toplevel = toplevel(forWindowId: id),
            let window = wm.server.window(id: id)
        else { return }
        let rect = targetRect.map {
            WindowRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
        } ?? window.currentRect()
        window.setRequestedFrame(rect)
        let request = ConfigureRequest(
            windowID: id,
            reason: resizing ? .resize : .move,
            targetRect: rect,
            targetOutputID: window.currentOutputID,
            activated: isFocused(id),
            resizing: resizing,
            tileEdges: TileEdges())
        guard let plan = wm.planConfigure(request), plan.shouldConfigure else { return }
        byToplevel[token(toplevel)]?.pendingPlan = plan
        byToplevel[token(toplevel)]?.replanReason = resizing ? .resize : .move
        toplevel.xdgSurface?.configureToplevel(initial: false)
    }

    // MARK: - taskbar actions (foreign-toplevel control verbs, by model window id)
    //
    // The taskbar funnels its handle verbs through the same window model + configure
    // path the compositor's own chrome uses. Activate + minimize resolve by window id
    // (so they cover xdg and xwayland); the configure-driven verbs (close / maximize /
    // fullscreen) target the xdg toplevel and no-op for an xwayland window, whose
    // equivalent control lands with the xwayland EWMH refinement.

    func foreignActivate(windowID: UInt64) {
        guard let window = WindowManager.shared.server.window(id: windowID), window.surfaceObjectId != 0
        else { return }
        // Activating a minimized window restores it first — a taskbar `activate` on a
        // minimized entry is the standard "un-minimize and focus" gesture, and
        // focusing an invisible, input-ineligible window would otherwise be a no-op.
        unminimize(windowId: windowID)
        activateSurfaceImpl(surfaceId: UInt32(window.surfaceObjectId))
    }

    func foreignClose(windowID: UInt64) {
        toplevel(forWindowId: windowID)?.sendClose()
    }

    func foreignSetMaximized(windowID: UInt64, _ on: Bool) {
        guard let toplevel = toplevel(forWindowId: windowID) else { return }
        setMaximizedImpl(token: token(toplevel), on)
        toplevel.xdgSurface?.configureToplevel(initial: false)
    }

    func foreignSetFullscreen(
        windowID: UInt64, _ on: Bool, outputID: UInt64?
    ) {
        guard let toplevel = toplevel(forWindowId: windowID) else { return }
        setFullscreenImpl(
            token: token(toplevel), on, outputID: outputID)
        toplevel.xdgSurface?.configureToplevel(initial: false)
    }

    func foreignSetMinimized(windowID: UInt64, _ on: Bool) {
        if on { _ = minimize(windowId: windowID) } else { unminimize(windowId: windowID) }
    }
}

extension RouterWindowDriver: ForeignToplevelActions {}

// MARK: - delegate conformances (nonisolated C-dispatch entry points)

/// A stable, process-unique identity token for a toplevel's lifetime: its object
/// pointer. Used only as the driver's table key / WindowManager role-table key —
/// never sent on the wire and never dereferenced as a pointer.
@inline(__always)
private func token(_ object: AnyObject) -> UInt {
    UInt(bitPattern: Unmanaged.passUnretained(object).toOpaque())
}

extension RouterWindowDriver: XdgShellDelegate {
    nonisolated func configure(for toplevel: XdgToplevel, initial: Bool) -> XdgToplevelConfigure {
        let t = token(toplevel)
        let surfaceId = toplevel.xdgSurface?.surface?.objectId ?? 0
        return MainActor.assumeIsolated { self.configureImpl(token: t, surfaceId: surfaceId, initial: initial) }
    }
    nonisolated func toplevelConfigureSent(_ toplevel: XdgToplevel, serial: UInt32, initial: Bool) {
        let t = token(toplevel)
        MainActor.assumeIsolated { self.configureSentImpl(token: t, serial: serial, initial: initial) }
    }
    nonisolated func toplevelDidCommit(
        _ toplevel: XdgToplevel, ackedSerial: UInt32, hasBuffer: Bool
    ) {
        let t = token(toplevel)
        let surfaceId = toplevel.xdgSurface?.surface?.objectId ?? 0
        let geom = toplevel.windowGeometry
        return MainActor.assumeIsolated {
            self.didCommitImpl(
                token: t, surfaceId: surfaceId, ackedSerial: ackedSerial,
                geom: geom, hasBuffer: hasBuffer)
        }
    }
    nonisolated func toplevelDidRequest(_ toplevel: XdgToplevel, _ request: XdgToplevelRequest) {
        let t = token(toplevel)
        switch request {
        case .setTitle(let title):
            MainActor.assumeIsolated { self.setTitleImpl(token: t, title) }
        case .setAppId(let appId):
            MainActor.assumeIsolated { self.setAppIdImpl(token: t, appId) }
        case .setParent(let parent):
            let parentToken = parent.map { token($0) }
            MainActor.assumeIsolated { self.setParentImpl(token: t, parentToken: parentToken) }
        case .setMaximized(let on):
            MainActor.assumeIsolated { self.setMaximizedImpl(token: t, on) }
        case .setFullscreen(let on, let outputID):
            MainActor.assumeIsolated {
                self.setFullscreenImpl(
                    token: t, on, outputID: outputID)
            }
        case .setMinimized:
            MainActor.assumeIsolated {
                guard let id = self.byToplevel[t]?.windowID,
                    self.minimize(windowId: id)
                else { return }
                self.seatDriver.setKeyboardFocus(toSurfaceId: 0)
                RenderBridge.requestFrame(forWindowID: id)
            }
        case .setMinSize, .setMaxSize:
            // XDG size hints constrain future client-chosen sizes. They are
            // validated and retained by XdgToplevel; server configure policy does
            // not synthesize a client size from those hints.
            break
        case .move:
            MainActor.assumeIsolated {
                guard let id = self.byToplevel[t]?.windowID else { return }
                RouterHost.shared.inputHost?.dispatch.beginInteractiveMove(windowID: id)
            }
        case .resize(_, let edges):
            MainActor.assumeIsolated {
                guard let id = self.byToplevel[t]?.windowID else { return }
                RouterHost.shared.inputHost?.dispatch.beginInteractiveResize(
                    windowID: id, edges: edges)
            }
        case .showWindowMenu:
            MainActor.assumeIsolated {
                guard let id = self.byToplevel[t]?.windowID else { return }
                RouterHost.shared.inputHost?.dispatch.showWindowMenu(windowID: id)
            }
        }
    }
    nonisolated func authorizeInteractiveRequest(
        _ toplevel: XdgToplevel,
        seat: UnsafeMutablePointer<wl_resource>?,
        serial: UInt32
    ) -> Bool {
        let seatBits = seat.map { UInt(bitPattern: $0) } ?? 0
        let surfaceID = toplevel.xdgSurface?.surface?.objectId ?? 0
        return MainActor.assumeIsolated {
            self.seatDriver.authorizeUserIntent(
                serial: serial,
                seatResourceBits: seatBits,
                surfaceID: surfaceID)
        }
    }
    nonisolated func toplevelWillDestroy(_ toplevel: XdgToplevel) {
        let t = token(toplevel)
        let surfaceId = toplevel.xdgSurface?.surface?.objectId ?? 0
        MainActor.assumeIsolated { self.willDestroyImpl(token: t, surfaceId: surfaceId) }
    }
    nonisolated func resolvePopup(
        _ popup: XdgPopup,
        positioner: XdgPositionerSnapshot,
        base: WlRect
    ) -> WlRect {
        let parentSurfaceID = popup.parent?.surface?.objectId ?? 0
        return MainActor.assumeIsolated {
            let parentWindowID = self.windowId(
                forSurfaceId: parentSurfaceID)
            guard parentWindowID != 0 else { return base }
            var wire = WirePopupPositioner()
            wire.sizeW = positioner.sizeW
            wire.sizeH = positioner.sizeH
            wire.anchorRectX = positioner.anchorRect.x
            wire.anchorRectY = positioner.anchorRect.y
            wire.anchorRectW = positioner.anchorRect.width
            wire.anchorRectH = positioner.anchorRect.height
            wire.anchor = positioner.anchor
            wire.gravity = positioner.gravity
            wire.constraintAdjustment = positioner.constraintAdjustment
            wire.offsetX = positioner.offsetX
            wire.offsetY = positioner.offsetY
            guard let resolved = WindowManager.shared.resolvePopup(
                parentID: parentWindowID, positioner: wire)
            else { return base }
            return WlRect(
                x: resolved.x, y: resolved.y,
                width: resolved.w, height: resolved.h)
        }
    }
    nonisolated func popupGrabRequested(
        _ popup: XdgPopup,
        seat: UnsafeMutablePointer<wl_resource>?,
        serial: UInt32
    ) -> Bool {
        let seatBits = seat.map { UInt(bitPattern: $0) } ?? 0
        let surfaceID = popup.grabOriginSurface?.objectId ?? 0
        let popupBits = UInt(
            bitPattern: Unmanaged.passUnretained(popup).toOpaque())
        return MainActor.assumeIsolated {
            guard self.seatDriver.authorizeUserIntent(
                serial: serial,
                seatResourceBits: seatBits,
                surfaceID: surfaceID)
            else { return false }
            let popup = Unmanaged<XdgPopup>.fromOpaque(
                UnsafeRawPointer(bitPattern: popupBits)!
            ).takeUnretainedValue()
            self.seatDriver.beginPopupGrab(popup)
            return true
        }
    }
}

extension RouterWindowDriver: SurfaceSceneDelegate {
    nonisolated func surfaceCommitted(_ commit: SurfaceCommit) {
        MainActor.assumeIsolated {
            self.sceneDriver.importCommit(commit)
        }
    }
    nonisolated func surfaceDestroyed(surfaceID: UInt32, iosurfaceID: UInt32) {
        MainActor.assumeIsolated {
            // Scene teardown (release iosurface, child-surface + layer-surface scene) is
            // the scene driver's; the seat/model unmap stays on this model adapter.
            self.sceneDriver.surfaceDestroyed(surfaceId: surfaceID, iosurfaceId: iosurfaceID)
            self.surfaceDestroyedImpl(surfaceId: surfaceID)
        }
    }
}

extension RouterWindowDriver: XdgActivationDelegate {
    nonisolated func activateSurface(_ surface: WlSurface?, token: String) {
        guard let surfaceId = surface?.objectId, surfaceId != 0 else { return }
        MainActor.assumeIsolated { self.activateSurfaceImpl(surfaceId: surfaceId) }
    }
}

extension RouterWindowDriver: XdgForeignDelegate {
    nonisolated func setForeignParent(child: WlSurface, parent: WlSurface?) {
        let childId = child.objectId
        let parentId = parent?.objectId
        MainActor.assumeIsolated {
            self.setForeignParentImpl(childSurfaceId: childId, parentSurfaceId: parentId)
        }
    }
}

extension RouterWindowDriver: DecorationDelegate {
    nonisolated func resolveDecorationMode(for toplevel: XdgToplevel?, clientRequested: UInt32?) -> UInt32 {
        2  // server_side — the compositor draws the chrome for managed toplevels.
    }
}

extension RouterWindowDriver: CursorShapeDelegate {
    /// A client requested a named cursor shape (wp_cursor_shape_v1). Map it to the
    /// theme name and realize it through the shell's cursor path (which loads the
    /// theme pixels into the cursor model → the hardware cursor plane), then request a
    /// frame so the new image reaches a commit. Returns false only for an out-of-range
    /// shape, which the router reports as `invalid_shape`.
    nonisolated func applyCursorShape(_ shape: UInt32) -> Bool {
        guard let name = cursorShapeName(shape) else { return false }
        MainActor.assumeIsolated {
            NucleusCompositorServer.shared.shellPolicy?.cursorApplyNamed(name)
            RenderBridge.requestCursorFrame()
        }
        return true
    }
}

extension RouterWindowDriver: LayerShellDelegate {
    nonisolated func defaultLayerOutputID() -> UInt64 {
        MainActor.assumeIsolated {
            NucleusCompositorServer.shared.layout.primaryDisplayID()
                ?? NucleusCompositorServer.shared.layout.displays.first?.id
                ?? 0
        }
    }
    nonisolated func defaultLayerOutputRect() -> WlRect? {
        MainActor.assumeIsolated { self.defaultLayerOutputRectImpl() }
    }
    nonisolated func layerSurfaceMapped(_ surface: ZwlrLayerSurface) {
        // The window + scene are authored from the content path (publishLayerSurfaceContent,
        // which runs on the map commit before this fires); here the surface's exclusive
        // zone is published to the layout policy so toplevels avoid the panel band.
        guard let surfaceId = surface.surface?.objectId else { return }
        let arrangement = surface.arrangement
        MainActor.assumeIsolated { self.registerLayerExclusiveZone(surfaceId: surfaceId, arrangement: arrangement) }
    }
    nonisolated func layerSurfaceUnmapped(surfaceID: UInt32) {
        // The role object was destroyed (or a null buffer committed) while the
        // wl_surface persists — `surfaceDestroyed` won't fire, so tear the model
        // window + exclusive zone down here. Idempotent: `destroyLayerSurface` no-ops
        // if the window is already gone.
        MainActor.assumeIsolated { self.sceneDriver.destroyLayerSurface(surfaceId: surfaceID) }
    }

    private func registerLayerExclusiveZone(surfaceId: UInt32, arrangement: ZwlrLayerSurface.LayerArrangement) {
        let record = LayerSurfaceRecord(
            id: UInt64(surfaceId),
            layer: arrangement.layer,
            anchor: arrangement.anchor,
            exclusiveZone: arrangement.exclusiveZone,
            margin: LayerMargin(
                top: arrangement.marginTop, right: arrangement.marginRight,
                bottom: arrangement.marginBottom, left: arrangement.marginLeft),
            outputID: arrangement.outputID,
            namespace: arrangement.namespace,
            keyboardInteractivity: Int32(arrangement.keyboardInteractivity),
            mapped: true)
        WindowManager.shared.layerShellPolicy.register(record)
        RouterHost.shared.xwaylandHost?.updateScale()
    }
}
