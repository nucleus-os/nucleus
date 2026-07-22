import Testing
import NucleusTypes
import NucleusCompositorServerTypes
@testable import NucleusCompositorServer

@Test func outputTopologyDiffIsStableAndClassifiesReplacement() {
    func output(
        _ id: UInt64, crtc: UInt32, width: UInt32 = 1_920
    ) -> OutputTopologyFingerprint {
        OutputTopologyFingerprint(
            outputID: id,
            pixelWidth: width,
            pixelHeight: 1_080,
            refreshMilliHz: 60_000,
            crtcID: crtc,
            primaryPlaneID: crtc + 100,
            cursorPlaneID: crtc + 200)
    }

    let diff = OutputTopologyDiff.compute(
        current: [output(30, crtc: 3), output(10, crtc: 1), output(20, crtc: 2)],
        proposed: [
            output(40, crtc: 4),
            output(20, crtc: 8),
            output(10, crtc: 1),
        ])
    #expect(diff.removed == [30])
    #expect(diff.changed == [20])
    #expect(diff.added == [40])
    #expect(diff.unchanged == [10])

    let forced = OutputTopologyDiff.compute(
        current: [output(10, crtc: 1)],
        proposed: [output(10, crtc: 1)],
        forceChanged: true)
    #expect(forced.changed == [10])
    #expect(forced.unchanged.isEmpty)
}

@MainActor
@Test func displayRefreshAndRedrawStatePreserveExactDemand() {
    var mode = DisplayMode()
    mode.pixelWidth = 1920
    mode.pixelHeight = 1080
    mode.refreshMhz = 59_940
    let display = Display(
        id: 1,
        configuration: DisplayConfiguration(mode: mode))

    #expect(display.displayLink.refreshIntervalNs == 16_683_350)
    #expect(display.redrawState == .idle)
    #expect(display.displayLink.targetPresentNs() == nil)

    display.requestRedraw([.surfaceDamage, .cursor])
    #expect(display.redrawState == .queued([.surfaceDamage, .cursor]))
    #expect(display.beginRedraw(frameBuildID: 4))
    display.requestRedraw(.animation)
    display.redrawSubmitted(submissionID: 9)
    #expect(display.redrawState == .awaitingPresentation(
        submissionID: 9, pending: .animation))

    display.requestRedraw(.shellOverlay)
    let coalesced = display.sampleRedrawMetrics()
    #expect(coalesced.redrawRequests == 3)
    #expect(coalesced.coalescedRequests == 2)
    #expect(coalesced.coalescedByReason[1] == 1)
    #expect(coalesced.coalescedByReason[3] == 1)
    display.redrawPresented(submissionID: 8)
    #expect(display.redrawState == .awaitingPresentation(
        submissionID: 9, pending: [.animation, .shellOverlay]))
    display.redrawPresented(submissionID: 9)
    #expect(display.redrawState == .queued([.animation, .shellOverlay]))

    display.suspendRedraws()
    #expect(display.redrawState == .suspended([.animation, .shellOverlay]))
    display.resumeRedraws()
    #expect(display.redrawState == .queued([
        .animation, .shellOverlay, .recovery,
    ]))
}

@Test func queuedFrameKeepsItsSelectedVblankUntilConsumed() {
    var link = DisplayLink(refreshIntervalNs: 16_666_667)
    link.requestFrame()
    let selectedVblank = link.targetPresentNs()
    #expect(selectedVblank != nil)

    // Simulate the presentation timeline advancing past the selected target
    // before the reactor rechecks it after waking. A dynamic prediction now
    // points at a later vblank, while queued demand must keep the original one.
    link.lastPresentationNs = Int64(bitPattern: selectedVblank!)
    #expect(link.predictedPresentNs(0) > selectedVblank!)
    #expect(link.targetPresentNs() == selectedVblank)

    let consumed = link.consumeFrameDemand()
    #expect(consumed)
    #expect(link.targetPresentNs() == nil)
}

@MainActor
@Test func desktopLayoutPlacesOutputsWithoutOverlapAndNormalizesPrimary() {
    let layout = DesktopLayout()
    var mode = DisplayMode()
    mode.pixelWidth = 1_920
    mode.pixelHeight = 1_080
    mode.refreshMhz = 60_000

    let first = layout.addDisplay(
        id: 10,
        configuration: DisplayConfiguration(
            logicalX: 50, logicalY: 25, mode: mode))
    let second = layout.addDisplay(
        id: 20,
        configuration: DisplayConfiguration(mode: mode),
        logicalXSpecified: false,
        logicalYSpecified: false)

    #expect(second.logicalRect.x == first.logicalRect.maxX)
    #expect(second.logicalRect.y == first.logicalRect.y)
    #expect(layout.primaryDisplayID() == 10)
    _ = layout.removeDisplay(id: 10)
    #expect(layout.primaryDisplayID() == 20)
    #expect(second.configuration.primary)
}

@MainActor
@Test func displayAndWindowABIRoundTrip() throws {
    let server = NucleusCompositorServer()
    server.serverReset()

    var mode = WireDisplayMode()
    mode.pixelWidth = 3000
    mode.pixelHeight = 2000
    mode.refreshMhz = 120000

    var config = WireDisplayConfiguration()
    config.enabled = true
    config.primary = true
    config.scale = 2
    config.logicalX = 10
    config.logicalY = 20
    config.fractionalScale = 2
    config.mode = mode

    try server.displayAdd(id: 7, configuration: config)

    let rect = try server.displayFind(id: 7)
    #expect(rect.x == 10)
    #expect(rect.y == 20)
    #expect(rect.width == 1500)
    #expect(rect.height == 1000)
    let desktopBounds = try server.displayDesktopBounds()
    #expect(desktopBounds.x == rect.x)
    #expect(desktopBounds.y == rect.y)
    #expect(desktopBounds.width == rect.width)
    #expect(desktopBounds.height == rect.height)
    #expect(server.displayOutputForPoint(x: 20, y: 30) == 7)
    #expect(server.displayOutputForPoint(x: -100, y: -100) == 0)
    #expect(server.displayFractionalScaleAt(x: 20, y: 30) == 2)
    #expect(server.displayFractionalScaleForOutput(id: 7) == 2)
    #expect(server.displayFractionalScaleForOutput(id: 99) == 0)
    #expect(server.spacesActiveForDisplay(displayID: 7) != 0)
    #expect(server.spacesOverlayDisplayID() == 7)

    let windowID = try server.windowCreate(source: .xdg)
    #expect(windowID != 0)

    var windowRect = WireWindowRect()
    windowRect.x = 30
    windowRect.y = 40
    windowRect.width = 800
    windowRect.height = 600
    try server.windowSetGeometry(id: windowID, rect: windowRect)
    let queriedRect = try server.windowGetGeometry(id: windowID)
    #expect(queriedRect.x == 30)
    #expect(queriedRect.y == 40)
    #expect(queriedRect.width == 800)
    #expect(queriedRect.height == 600)

    guard let window = server.window(id: windowID) else {
        Issue.record("missing created window")
        return
    }
    let slotGeneration = window.protocolState.queueConfigure(
        rect: WindowRect(x: 30, y: 40, width: 800, height: 600),
        activeMaximized: false,
        activeFullscreen: false,
        specialOutputID: nil,
        layoutTransitionID: 0,
        serial: 44
    )
    #expect(slotGeneration == 1)
    #expect(server.windowPendingConfigureCount(id: windowID) == 1)
    #expect(window.protocolState.latest?.serial == 44)
    #expect(window.protocolState.configure(forAckSerial: 44)?.slotGeneration == 1)
    #expect(window.consumeAckedConfigure(serial: 44) != nil)
    #expect(server.windowPendingConfigureCount(id: windowID) == 0)

    server.windowSetMapped(id: windowID, mapped: true)
    server.windowNoteSurfaceOutput(id: windowID, outputID: 7)
    window.requestedFullscreen = true
    window.specialOutputID = 7
    window.level = 100
    window.restoreRect = WindowRect(x: 45, y: 55, width: 640, height: 480)
    window.tileEdges = TileEdges(left: true, top: true)
    #expect(server.windowGetRequestedFullscreen(id: windowID))
    #expect(server.windowGetCurrentOutput(id: windowID) == 7)
    #expect(server.windowGetLevel(id: windowID) == 100)
    let queriedEdges = try server.windowGetTileEdges(id: windowID)
    #expect(queriedEdges.left == true)
    #expect(queriedEdges.top == true)
    let policySnapshot = try server.windowCopyPolicySnapshot(windowID: windowID)
    #expect(policySnapshot.policyOutputId == 7)
    #expect(policySnapshot.requestedFullscreenOutputId == 7)
    #expect(policySnapshot.requestedSpecial.activeFullscreen == true)
    #expect(policySnapshot.requestedSpecial.willSpecial == true)
    #expect(policySnapshot.managedAppWindow == true)
    var usable = WireUsableArea()
    usable.x = 10
    usable.y = 20
    usable.w = 1200
    usable.h = 900
    let layoutSnapshot = try server.spacesOutputLayoutSnapshot(outputID: 7, usable: usable)
    let fullscreenRect = layoutSnapshot.fullscreenRect
    #expect(fullscreenRect.x == 10)
    #expect(fullscreenRect.y == 20)
    #expect(fullscreenRect.width == 1500)
    #expect(fullscreenRect.height == 1000)
    let maximizedRect = layoutSnapshot.maximizedRect
    #expect(maximizedRect.x == 20)
    #expect(maximizedRect.y == 40)
    #expect(maximizedRect.width == 1200)
    #expect(maximizedRect.height == 900)
    let defaultRect = layoutSnapshot.defaultRect
    #expect(defaultRect.x == 220)
    #expect(defaultRect.y == 190)
    #expect(defaultRect.width == 800)
    #expect(defaultRect.height == 600)

    let secondWindowID = try server.windowCreate(source: .xwayland)
    #expect(secondWindowID != 0)
    #expect(server.windowListRaise(id: windowID))

    let iterated = Array<WireWindowRenderOrderEntry>(
        capacity: Int(server.windowRenderOrderCount(frontToBack: false))
    ) { out in
        server.windowRenderOrderFill(frontToBack: false, into: &out)
    }
    #expect(iterated.map(\.windowId) == [secondWindowID, windowID])

    let frontIterated = Array<WireWindowRenderOrderEntry>(
        capacity: Int(server.windowRenderOrderCount(frontToBack: true))
    ) { out in
        server.windowRenderOrderFill(frontToBack: true, into: &out)
    }
    #expect(frontIterated.map(\.windowId) == [windowID, secondWindowID])

    let spaceID = try server.spacesCreate(outputID: 1)
    #expect(spaceID != 0)
    #expect(server.spacesAssignWindowToSpace(windowID: windowID, spaceID: spaceID))

    try server.windowDestroy(id: windowID)
    try server.windowDestroy(id: secondWindowID)
}

@MainActor
@Test func spacesHideWindowsOnInactiveWorkspace() throws {
    let server = NucleusCompositorServer()
    server.serverReset()

    var mode = WireDisplayMode()
    mode.pixelWidth = 1920
    mode.pixelHeight = 1080
    mode.refreshMhz = 60000
    var config = WireDisplayConfiguration()
    config.enabled = true
    config.primary = true
    config.scale = 1
    config.mode = mode
    try server.displayAdd(id: 1, configuration: config)

    // The output gets an auto-created active workspace.
    let active = server.spacesActiveForDisplay(displayID: 1)
    #expect(active != 0)

    // A mapped managed window (output set before map) joins the output's active
    // workspace and is therefore visible, not space-hidden.
    let windowID = try server.windowCreate(source: .xdg)
    server.windowNoteSurfaceOutput(id: windowID, outputID: 1)
    server.windowSetMapped(id: windowID, mapped: true)
    #expect(server.windowGetSpaceHidden(id: windowID) == false)

    // A second workspace on the same output; switching to it hides the window
    // (it stays on the now-inactive first workspace).
    let second = try server.spacesCreate(outputID: 1)
    #expect(server.spacesSetActive(displayID: 1, spaceID: second))
    #expect(server.spacesActiveForDisplay(displayID: 1) == second)
    #expect(server.windowGetSpaceHidden(id: windowID) == true)

    // Switching back reveals it again.
    #expect(server.spacesSetActive(displayID: 1, spaceID: active))
    #expect(server.windowGetSpaceHidden(id: windowID) == false)

    // Moving the window to the (now inactive) second workspace hides it without
    // switching the active workspace.
    #expect(server.spacesAssignWindowToSpace(windowID: windowID, spaceID: second))
    #expect(server.spacesActiveForDisplay(displayID: 1) == active)
    #expect(server.windowGetSpaceHidden(id: windowID) == true)

    // Activating an unknown / wrong-output workspace is refused and changes nothing.
    #expect(server.spacesSetActive(displayID: 1, spaceID: 9999) == false)
    #expect(server.spacesActiveForDisplay(displayID: 1) == active)

    try server.windowDestroy(id: windowID)
}

@MainActor
@Test func spaceHiddenMirrorDrivesSceneVisibility() throws {
    // The scene feeder (visibleInScene) and hit-test (eligibleForInput) read the
    // per-window `spaceHidden` mirror, which the server must keep in sync with the
    // authoritative Spaces.isSpaceHidden on every workspace change — otherwise the
    // mirror stays permanently false and windows are never hidden by workspace.
    let server = NucleusCompositorServer()
    server.serverReset()

    var mode = WireDisplayMode()
    mode.pixelWidth = 1920
    mode.pixelHeight = 1080
    mode.refreshMhz = 60000
    var config = WireDisplayConfiguration()
    config.enabled = true
    config.primary = true
    config.scale = 1
    config.mode = mode
    try server.displayAdd(id: 1, configuration: config)

    let active = server.spacesActiveForDisplay(displayID: 1)
    let windowID = try server.windowCreate(source: .xdg)
    server.windowNoteSurfaceOutput(id: windowID, outputID: 1)
    server.windowSetMapped(id: windowID, mapped: true)

    let window = try #require(server.windows.window(id: windowID))
    // Visible on its active workspace: mirror false, scene + input eligible.
    #expect(window.spaceHidden == false)
    #expect(window.visibleInScene())
    #expect(window.eligibleForInput())

    // Switching to a second workspace hides the window from scene AND input.
    let second = try server.spacesCreate(outputID: 1)
    #expect(server.spacesSetActive(displayID: 1, spaceID: second))
    #expect(window.spaceHidden == true)
    #expect(!window.visibleInScene())
    #expect(!window.eligibleForInput())

    // Switching back reveals it.
    #expect(server.spacesSetActive(displayID: 1, spaceID: active))
    #expect(window.spaceHidden == false)
    #expect(window.visibleInScene())

    try server.windowDestroy(id: windowID)
}

@MainActor
@Test func spacesEnsureCreatesWorkspacesOnDemand() throws {
    let server = NucleusCompositorServer()
    server.serverReset()

    var mode = WireDisplayMode()
    mode.pixelWidth = 1920
    mode.pixelHeight = 1080
    mode.refreshMhz = 60000
    var config = WireDisplayConfiguration()
    config.enabled = true
    config.primary = true
    config.scale = 1
    config.mode = mode
    try server.displayAdd(id: 1, configuration: config)

    // The output starts with its auto-created workspace 1.
    let first = server.spacesActiveForDisplay(displayID: 1)
    #expect(first != 0)
    // Ensuring index 1 returns that same workspace — idempotent, no new space.
    #expect(server.spacesEnsureForOutput(outputID: 1, index: 1) == first)
    // Ensuring index 3 creates the missing leading workspaces and returns the
    // third; re-asking the same index is stable.
    let third = server.spacesEnsureForOutput(outputID: 1, index: 3)
    #expect(third != 0)
    #expect(third != first)
    #expect(server.spacesEnsureForOutput(outputID: 1, index: 3) == third)
    // The intermediate workspace (index 2) was created and is distinct.
    let second = server.spacesEnsureForOutput(outputID: 1, index: 2)
    #expect(second != first)
    #expect(second != third)
    // Index 0 is invalid.
    #expect(server.spacesEnsureForOutput(outputID: 1, index: 0) == 0)
    // The Super+N switch path activates a created workspace.
    #expect(server.spacesSetActive(displayID: 1, spaceID: third))
    #expect(server.spacesActiveForDisplay(displayID: 1) == third)
}

@MainActor
final class RecordingSelectionObserver: DataSelectionObserver {
    var changes: [(kind: SelectionKind, seat: UInt64)] = []
    func selectionDidChange(kind: SelectionKind, seat: DataSeatHandle) {
        changes.append((kind, seat.rawValue))
    }
}

@MainActor
@Test func dataExchangeSharedPrimitivesBackDataControl() {
    // The ext_data_control projection stands on three shared DataExchangeService
    // primitives: a process-unique handle space (so its handles never collide with
    // wl_data_device's in the shared maps), a source-event registry (so a transfer
    // or cancel crosses to the owning source's router), and a selection-change
    // broadcast (so the always-on clipboard view stays current). This pins them.
    let service = NucleusCompositorServer().dataExchange
    service.reset()

    // Handles are unique and non-zero.
    let h1 = service.allocateHandle()
    let h2 = service.allocateHandle()
    #expect(h1 != 0 && h2 != 0 && h1 != h2)

    let observer = RecordingSelectionObserver()
    service.addSelectionObserver(observer)

    let seat = DataSeatHandle(rawValue: 1)
    let client = DataClientHandle(rawValue: 7)

    // A source with a registered send/cancel emitter (models a router's source).
    let src = DataSourceHandle(rawValue: service.allocateHandle())
    service.sourceCreated(src, ownerKind: .wayland, client: client)
    service.addMimeType("text/plain", to: src)
    service.addMimeType("text/html", to: src)
    var sentMimes: [String] = []
    var cancelledCount = 0
    service.registerSourceEvents(src, onSend: { mime, _ in sentMimes.append(mime) }, onCancel: { cancelledCount += 1 })

    // The mime accessor reflects offer order (the projection enumerates offers with it).
    #expect(service.mimeTypes(for: src) == ["text/plain", "text/html"])

    // Setting the clipboard selection fires the broadcast.
    _ = service.setSelection(kind: .clipboard, seat: seat, source: src, serial: 1)
    #expect(observer.changes.contains { $0.kind == .clipboard && $0.seat == 1 })

    // A transfer routes through the registered emitter — models a paste reaching
    // the owning source regardless of which router holds the offer.
    let offer = DataOfferHandle(rawValue: service.allocateHandle())
    service.offerCreated(offer, kind: .clipboard, source: src, destination: client)
    let transfer = service.requestTransfer(offer, mimeType: "text/plain")
    #expect(transfer.allowed)
    if let s = transfer.source { service.emitSourceSend(s, mimeType: "text/plain", fd: -1) }
    #expect(sentMimes == ["text/plain"])

    // The cancel emitter reaches the owning source.
    service.emitSourceCancelled(src)
    #expect(cancelledCount == 1)

    // Replacing the selection fires the broadcast again and reports the superseded
    // owner so the projection can cancel it.
    let before = observer.changes.count
    let src2 = DataSourceHandle(rawValue: service.allocateHandle())
    service.sourceCreated(src2, ownerKind: .wayland, client: client)
    let plan = service.setSelection(kind: .clipboard, seat: seat, source: src2, serial: 2)
    #expect(observer.changes.count > before)
    #expect(plan.cancelSource == src)

    // Destroying the owning source clears the selection and fires the broadcast.
    let beforeDestroy = observer.changes.count
    _ = service.sourceDestroyed(src2)
    #expect(observer.changes.count > beforeDestroy)
    #expect(service.snapshot(seat: seat).clipboardOwner == nil)

    service.removeSelectionObserver(observer)
    service.reset()
}

@MainActor
@Test func eventDispatchAdvancesState() throws {
    let server = NucleusCompositorServer()
    server.serverReset()

    var event = WireEventRecord()
    event.kind = .mouseMoved
    event.x = 12
    event.y = 34
    var bounds = WirePointerBounds()
    bounds.minX = 0
    bounds.minY = 0
    bounds.maxX = 100
    bounds.maxY = 100
    let decision = try server.eventServerDispatch(event: event, bounds: bounds)
    #expect(decision.action == .route)
    #expect(decision.event.x == 12)
    #expect(decision.event.y == 34)
    #expect(decision.state.cursorX == 12)
    #expect(decision.state.cursorY == 34)
    #expect(decision.change.cursorMoved == true)
}

@MainActor
@Test func seatFocusABIRoundTrip() throws {
    let server = NucleusCompositorServer()
    server.serverReset()

    server.seatFocusSetPointer(surfaceID: 0x111)
    server.seatFocusSetKeyboard(surfaceID: 0x222)
    server.seatFocusRecordPointerButton(state: 1, serial: 44, focusedSurfaceID: 0x111)

    var snapshot = try server.seatFocusGetSnapshot()
    #expect(snapshot.pointerSurfaceId == 0x111)
    #expect(snapshot.keyboardSurfaceId == 0x222)
    #expect(snapshot.buttonCount == 1)
    #expect(snapshot.lastPointerButtonSerial == 44)
    #expect(snapshot.lastPointerButtonSurfaceId == 0x111)

    server.seatFocusInvalidateSurface(surfaceID: 0x111)
    snapshot = try server.seatFocusGetSnapshot()
    #expect(snapshot.pointerSurfaceId == 0)
    #expect(snapshot.keyboardSurfaceId == 0x222)
    #expect(snapshot.buttonCount == 0)
    #expect(snapshot.lastPointerButtonSerial == 0)

    server.seatFocusClearKeyboard()
    snapshot = try server.seatFocusGetSnapshot()
    #expect(snapshot.keyboardSurfaceId == 0)
}

@MainActor
@Test func raiseKeepsChildWindowsAboveTheirParent() {
    let list = WindowList()
    let parent = Window(id: 1, source: .xdg)
    let child = Window(id: 2, source: .xdg)
    child.parentWindowID = 1
    let other = Window(id: 3, source: .xdg)
    list.add(parent)
    list.add(child)
    list.add(other)
    // orderedIDs is back-to-front; the last id is frontmost.
    #expect(list.orderedIDs() == [1, 2, 3])

    // Raising the parent brings its child along, above the parent — a dialog
    // is never buried under the window it belongs to.
    list.raise(id: 1)
    #expect(list.orderedIDs() == [3, 1, 2])

    // Raising an unrelated window keeps the child directly above its parent.
    list.raise(id: 3)
    #expect(list.orderedIDs() == [1, 2, 3])

    // Raising the child brings the whole family forward, child still above parent.
    list.raise(id: 2)
    #expect(list.orderedIDs() == [3, 1, 2])
}

@MainActor
@Test func fullscreenOcclusionPredicate() throws {
    let server = NucleusCompositorServer()
    server.serverReset()

    var mode = WireDisplayMode()
    mode.pixelWidth = 1920
    mode.pixelHeight = 1080
    mode.refreshMhz = 60000
    var config = WireDisplayConfiguration()
    config.enabled = true
    config.primary = true
    config.scale = 1
    config.logicalX = 0
    config.logicalY = 0
    config.fractionalScale = 1
    config.mode = mode
    try server.displayAdd(id: 1, configuration: config)

    // Created back-to-front: `back` (farthest back), the fullscreen `owner`, then
    // `front` (front-most). Same level, so insertion order is the z-order.
    let backID = try server.windowCreate(source: .xdg)
    server.windowSetMapped(id: backID, mapped: true)
    server.windowNoteSurfaceOutput(id: backID, outputID: 1)

    let ownerID = try server.windowCreate(source: .xdg)
    server.windowSetMapped(id: ownerID, mapped: true)
    server.windowNoteSurfaceOutput(id: ownerID, outputID: 1)
    let owner = server.window(id: ownerID)!
    owner.specialOutputID = 1
    owner.activeFullscreen = true

    let frontID = try server.windowCreate(source: .xdg)
    server.windowSetMapped(id: frontID, mapped: true)
    server.windowNoteSurfaceOutput(id: frontID, outputID: 1)

    let back = server.window(id: backID)!
    let front = server.window(id: frontID)!

    // The front-most fullscreen window is the owner.
    #expect(server.fullscreenOwner(onOutput: 1)?.id == ownerID)

    // Same level: behind the owner is occluded, in front is not, and the owner
    // does not occlude itself.
    #expect(server.isOccludedByFullscreen(back))
    #expect(!server.isOccludedByFullscreen(front))
    #expect(!server.isOccludedByFullscreen(owner))

    // Cross-level: a higher level is never occluded by a lower-level fullscreen
    // owner (even from behind in raw order); a lower level always is.
    front.level = 10
    #expect(!server.isOccludedByFullscreen(front))
    back.level = -10
    #expect(server.isOccludedByFullscreen(back))

    // A minimized fullscreen window is not an owner; nothing is occluded.
    owner.minimized = true
    #expect(server.fullscreenOwner(onOutput: 1) == nil)
    #expect(!server.isOccludedByFullscreen(back))
}

// MARK: - Compositor-owned presentation (the tiling spring)

@MainActor
@Test func presentationActorUnseededReturnsModelRect() {
    let window = Window(id: 1, source: .xdg)
    window.setGeometry(WindowRect(x: 100, y: 200, width: 800, height: 600))
    // Before the actor is seeded, the presented rect IS the authorized model rect
    // (a hard snap), there is no animation, and the crossfade overlay is inert.
    #expect(!window.hasActiveTileAnimation())
    let rect = window.currentAnimatedRect()
    #expect(rect.x == 100 && rect.y == 200 && rect.w == 800 && rect.h == 600)
    #expect(window.tileCrossfadeOpacity() == 1)
}

@MainActor
@Test func tileSpringEasesMonotonicallyAndSettlesOnCommitted() {
    let window = Window(id: 1, source: .xdg)
    let start = PresentationRect(x: 0, y: 0, w: 400, h: 300)
    let final = PresentationRect(x: 200, y: 100, w: 800, h: 600)
    window.seedPresentationActorToRect(start, slotGeneration: 1)
    // The client commits the requested final size in response to the tile.
    window.committedLogicalSize = RenderSize(w: 800, h: 600)
    window.beginPresentationTileAnimation(finalRect: final, slotGeneration: 2)
    #expect(window.hasActiveTileAnimation())

    let t0 = 1000.0
    var previousDistance = Double.greatestFiniteMagnitude
    var inFlight = true
    var time = t0
    while time <= t0 + 0.8 {
        inFlight = window.advanceTileAnimation(presentTimeSeconds: time)
        let presented = window.currentAnimatedRect()
        let distance = abs(presented.x - final.x) + abs(presented.y - final.y)
            + abs(presented.w - final.w) + abs(presented.h - final.h)
        // Critically damped → monotonic, overshoot-free approach: never recedes.
        #expect(distance <= previousDistance + 1e-6)
        previousDistance = distance
        if !inFlight { break }
        time += 0.016
    }
    #expect(!inFlight)
    let presented = window.currentAnimatedRect()
    #expect(abs(presented.x - final.x) < 0.5 && abs(presented.y - final.y) < 0.5)
    #expect(abs(presented.w - 800) < 0.5 && abs(presented.h - 600) < 0.5)
    #expect(!window.hasActiveTileAnimation())
}

@MainActor
@Test func tileSpringCarriesVelocityOnReTile() {
    let window = Window(id: 1, source: .xdg)
    window.seedPresentationActorToRect(PresentationRect(x: 0, y: 0, w: 400, h: 300), slotGeneration: 1)
    window.beginPresentationTileAnimation(
        finalRect: PresentationRect(x: 0, y: 0, w: 1200, h: 900), slotGeneration: 2)
    // Advance partway so the spring carries nonzero velocity.
    _ = window.advanceTileAnimation(presentTimeSeconds: 1000.0)
    _ = window.advanceTileAnimation(presentTimeSeconds: 1000.05)
    let carriedVel = window.presentationActor.tileAnimation!.currentVel
    #expect(carriedVel.w != 0)
    // A mid-flight re-tile to a new target carries the live velocity into the new
    // segment (C¹-continuous), rather than restarting from rest.
    window.beginPresentationTileAnimation(
        finalRect: PresentationRect(x: 0, y: 0, w: 600, h: 450), slotGeneration: 3)
    let reTiled = window.presentationActor.tileAnimation!
    #expect(reTiled.startVel == carriedVel)
    #expect(reTiled.finalRect.w == 600 && reTiled.finalRect.h == 450)
}

@MainActor
@Test func tileSpringRedundantReTileLeavesCurveUntouched() {
    let window = Window(id: 1, source: .xdg)
    window.seedPresentationActorToRect(PresentationRect(x: 0, y: 0, w: 400, h: 300), slotGeneration: 1)
    let final = PresentationRect(x: 10, y: 20, w: 800, h: 600)
    window.beginPresentationTileAnimation(finalRect: final, slotGeneration: 2)
    _ = window.advanceTileAnimation(presentTimeSeconds: 1000.0)
    _ = window.advanceTileAnimation(presentTimeSeconds: 1000.05)
    let velBefore = window.presentationActor.tileAnimation!.currentVel
    // Re-issuing the SAME target (a focus-state configure, re-issued maximize)
    // must not rebuild the curve — that would stutter or snap it short.
    window.beginPresentationTileAnimation(finalRect: final, slotGeneration: 3)
    let animation = window.presentationActor.tileAnimation!
    #expect(animation.startSlotGeneration == 2)
    #expect(animation.currentVel == velBefore)
}

@MainActor
@Test func tileSpringGraceBackstopSettlesOnCommittedForResponsiveClient() {
    let window = Window(id: 1, source: .xdg)
    window.seedPresentationActorToRect(PresentationRect(x: 0, y: 0, w: 400, h: 300), slotGeneration: 1)
    // The client quantized its size (committed a nearby-but-different extent) and
    // responded to the tile configure.
    window.committedLogicalSize = RenderSize(w: 770, h: 600)
    let final = PresentationRect(x: 0, y: 0, w: 800, h: 600)
    window.beginPresentationTileAnimation(finalRect: final, slotGeneration: 2)
    window.presentationActor.currentSlotGeneration = 3

    var inFlight = true
    var time = 1000.0
    _ = window.advanceTileAnimation(presentTimeSeconds: time)
    while inFlight && time <= 1000.0 + 2.0 {
        time += 0.05
        inFlight = window.advanceTileAnimation(presentTimeSeconds: time)
    }
    #expect(!inFlight)
    let presented = window.currentAnimatedRect()
    // Lands on the committed size at the final origin → identity presented/base scale.
    #expect(abs(presented.w - 770) < 0.5 && abs(presented.h - 600) < 0.5)
    #expect(presented.x == 0 && presented.y == 0)
}

@MainActor
@Test func tileSpringUnresponsiveClientSettlesOnRequestedSize() {
    let window = Window(id: 1, source: .xdg)
    window.seedPresentationActorToRect(PresentationRect(x: 0, y: 0, w: 400, h: 300), slotGeneration: 5)
    // The client never re-commits: committed stays the stale pre-tile extent and the
    // slot generation never advances past the segment's start.
    window.committedLogicalSize = RenderSize(w: 400, h: 300)
    let final = PresentationRect(x: 0, y: 0, w: 800, h: 600)
    window.beginPresentationTileAnimation(finalRect: final, slotGeneration: 5)

    var inFlight = true
    var time = 2000.0
    _ = window.advanceTileAnimation(presentTimeSeconds: time)
    while inFlight && time <= 2000.0 + 2.0 {
        time += 0.05
        inFlight = window.advanceTileAnimation(presentTimeSeconds: time)
    }
    #expect(!inFlight)
    let presented = window.currentAnimatedRect()
    // No client response → land on the requested final size, not the stale 400×300.
    #expect(abs(presented.w - 800) < 0.5 && abs(presented.h - 600) < 0.5)
}

@MainActor
@Test func tileCrossfadeOpacityDissolvesWithMotion() {
    let window = Window(id: 1, source: .xdg)
    window.seedPresentationActorToRect(PresentationRect(x: 0, y: 0, w: 400, h: 300), slotGeneration: 1)
    window.committedLogicalSize = RenderSize(w: 800, h: 600)
    window.beginPresentationTileAnimation(
        finalRect: PresentationRect(x: 0, y: 0, w: 800, h: 600), slotGeneration: 2)
    // At the start shape (elapsed 0) the full displacement remains → snapshot opaque.
    _ = window.advanceTileAnimation(presentTimeSeconds: 6000.0)
    #expect(abs(window.tileCrossfadeOpacity() - 1.0) < 1e-6)
    // One step into the motion the snapshot has begun dissolving, still in flight.
    let inFlight = window.advanceTileAnimation(presentTimeSeconds: 6000.05)
    #expect(inFlight)
    let mid = window.tileCrossfadeOpacity()
    #expect(mid < 1.0 && mid > 0.0)
}

@MainActor
@Test func snapshotTransitionGenerationRejectsLateCompletionAndRetiresOnce() {
    let window = Window(id: 1, source: .xdg)
    window.mapped = true
    window.seedPresentationActorToRect(
        PresentationRect(x: 0, y: 0, w: 400, h: 300),
        slotGeneration: 1)

    let first = window.installTileCrossfade(snapshotHandle: 101)
    #expect(first.replaced == nil)
    let second = window.installTileCrossfade(snapshotHandle: 202)
    #expect(second.generation != first.generation)
    #expect(second.replaced == WindowTransitionRetirement(
        generation: first.generation,
        snapshotHandle: 101,
        wasClosing: false,
        destroyWindow: false))

    // A completion racing the replacement cannot consume the new resource.
    #expect(window.takePresentationTransition(
        generation: first.generation) == nil)
    #expect(window.presentationActor.transition?.snapshotHandle == 202)
    #expect(window.takePresentationTransition(
        generation: second.generation)?.snapshotHandle == 202)
    #expect(window.takePresentationTransition(
        generation: second.generation) == nil)
}

@MainActor
@Test func closingFadeFreezesGeometryDisablesInputAndUsesPresentationClock() {
    let window = Window(id: 7, source: .xdg)
    window.mapped = true
    let frozen = PresentationRect(x: 12, y: 34, w: 640, h: 480)
    window.seedPresentationActorToRect(frozen, slotGeneration: 1)
    window.beginPresentationTileAnimation(
        finalRect: PresentationRect(x: 100, y: 100, w: 900, h: 700),
        slotGeneration: 2)
    let installed = window.installClosingFade(
        snapshotHandle: 303,
        destroyWindowOnCompletion: true)
    window.mapped = false

    #expect(!window.eligibleForInput())
    #expect(window.visibleInScene())
    #expect(!window.hasActiveTileAnimation())
    #expect(window.currentAnimatedRect() == frozen)
    #expect(window.transitionOverlayOpacity() == 1)

    #expect(window.advanceClosingFade(presentTimeSeconds: 50))
    #expect(window.windowPresentationOpacity() == 1)
    #expect(window.advanceClosingFade(
        presentTimeSeconds: 50 + PresentationTiming.closingFadeSeconds / 2))
    let midpoint = window.windowPresentationOpacity()
    #expect(abs(midpoint - 0.5) < 0.001)
    #expect(!window.advanceClosingFade(
        presentTimeSeconds: 50 + PresentationTiming.closingFadeSeconds))
    #expect(window.windowPresentationOpacity() == 0)
    #expect(window.currentAnimatedRect() == frozen)

    let retirement = window.takePresentationTransition(
        generation: installed.generation)
    #expect(retirement?.snapshotHandle == 303)
    #expect(retirement?.wasClosing == true)
    #expect(retirement?.destroyWindow == true)
    #expect(!window.visibleInScene())
    #expect(window.takePresentationTransition(
        generation: installed.generation) == nil)
}

@MainActor
@Test func closingSupersedesTileAndCanUpgradeUnmapToDestruction() {
    let window = Window(id: 9, source: .xdg)
    window.mapped = true
    window.seedPresentationActorToRect(
        PresentationRect(x: 0, y: 0, w: 800, h: 600),
        slotGeneration: 1)
    let tile = window.installTileCrossfade(snapshotHandle: 11)
    let close = window.installClosingFade(
        snapshotHandle: 22,
        destroyWindowOnCompletion: false)
    #expect(close.replaced?.generation == tile.generation)
    #expect(close.replaced?.snapshotHandle == 11)
    window.requireWindowDestructionAfterClosing()
    #expect(window.takePresentationTransition(
        generation: close.generation)?.destroyWindow == true)
}

@MainActor
@Test func requestedCommittedAndPresentedGeometryRemainIndependent() {
    let window = Window(id: 42, source: .xdg)
    let committed = WindowRect(x: 10, y: 20, width: 640, height: 480)
    window.committedLogicalSize = RenderSize(w: 600, h: 440)
    window.setGeometry(committed)
    window.seedPresentationActorToRect(
        PresentationRect(x: 10, y: 20, w: 640, h: 480), slotGeneration: 1)

    let requested = WindowRect(x: 30, y: 40, width: 1000, height: 700)
    window.setRequestedFrame(requested)
    #expect(window.currentRect() == requested)
    #expect(window.currentCommittedRect() == committed)
    #expect(window.currentAnimatedRect() == PresentationRect(x: 10, y: 20, w: 640, h: 480))

    window.acceptCommittedFrame(WindowRect(x: 30, y: 40, width: 980, height: 680))
    #expect(window.committedLogicalSize == RenderSize(w: 600, h: 440),
            "outer-frame acceptance must not overwrite client content extent")
}
