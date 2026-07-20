import Testing
import NucleusTypes
import NucleusCompositorServerTypes
@testable import NucleusCompositorServer
@testable import NucleusCompositorWindowManager

@MainActor
private func seedConfigurePolicyDisplay(id: UInt64 = 7, x: Double = 0) throws {
    var mode = WireDisplayMode()
    mode.pixelWidth = 1600
    mode.pixelHeight = 900
    mode.refreshMhz = 60000
    var config = WireDisplayConfiguration()
    config.enabled = true
    config.primary = id == 7
    config.scale = 1
    config.fractionalScale = 1
    config.logicalX = x
    config.mode = mode
    try NucleusCompositorServer.shared.displayAdd(id: id, configuration: config)
}

private func layerSurfaceRecord(
    id: UInt64,
    outputID: UInt64,
    anchor: UInt32,
    exclusiveZone: Int32,
    marginTop: Int32 = 0,
    marginRight: Int32 = 0,
    marginBottom: Int32 = 0,
    marginLeft: Int32 = 0,
    mapped: Bool = true
) -> LayerSurfaceRecord {
    LayerSurfaceRecord(
        id: id,
        layer: 2,
        anchor: anchor,
        exclusiveZone: exclusiveZone,
        margin: LayerMargin(top: marginTop, right: marginRight, bottom: marginBottom, left: marginLeft),
        outputID: outputID,
        namespace: "",
        keyboardInteractivity: 1,
        mapped: mapped
    )
}

@MainActor
private func nucleus_compositor_window_manager_record_configure_sent(
    _ windowID: UInt64,
    _ serial: UInt32,
    _ plan: ConfigurePlan
) -> WindowPendingConfigure? {
    WindowManager.shared.recordConfigureSent(windowID: windowID, serial: serial, plan: plan)
}

@MainActor
private func nucleus_compositor_window_manager_report_configure_ack(
    _ windowID: UInt64,
    _ ackedSerial: UInt32
) -> WindowPendingConfigure? {
    WindowManager.shared.reportConfigureAck(windowID: windowID, ackedSerial: ackedSerial)
}

@MainActor
private func nucleus_compositor_window_manager_report_configure_commit(_ report: ConfigureCommitReport) -> UInt8 {
    WindowManager.shared.reportConfigureCommit(report) ? 1 : 0
}

@MainActor
private func nucleus_compositor_window_manager_normalize_output_state(
    _ windowID: UInt64,
    _ fallbackOutputID: UInt64,
    _ hasTranslatedRestore: UInt8,
    _ translatedRestore: WireWindowRect,
    _ translatedRestoreOutputID: UInt64
) -> UInt8 {
    let restore = hasTranslatedRestore != 0
        ? RestoreTranslation(rect: WindowRect(wireValue: translatedRestore), outputID: translatedRestoreOutputID)
        : nil
    return WindowManager.shared.normalizeOutputState(
        windowID: windowID,
        fallbackOutputID: fallbackOutputID,
        translatedRestore: restore
    ) ? 1 : 0
}

@MainActor
private func nucleus_compositor_window_manager_migrate_off_output(
    _ windowID: UInt64,
    _ removedOutputID: UInt64,
    _ hasFallbackOutputID: UInt8,
    _ fallbackOutputID: UInt64,
    _ hasRemovedUsable: UInt8,
    _ removedUsable: WireUsableArea,
    _ hasFallbackUsable: UInt8,
    _ fallbackUsable: WireUsableArea,
    _ hasFullscreenRect: UInt8,
    _ fullscreenRect: WireWindowRect,
    _ hasMaximizedRect: UInt8,
    _ maximizedRect: WireWindowRect,
    _ outManaged: UnsafeMutablePointer<UInt8>?,
    _ outChanged: UnsafeMutablePointer<UInt8>?,
    _ outSpecialChanged: UnsafeMutablePointer<UInt8>?
) -> UInt8 {
    guard let result = try? WindowManager.shared.migrateOffOutput(
        windowID: windowID,
        removedOutputID: removedOutputID,
        hasFallbackOutputID: hasFallbackOutputID != 0,
        fallbackOutputID: fallbackOutputID,
        hasRemovedUsable: hasRemovedUsable != 0,
        removedUsable: removedUsable,
        hasFallbackUsable: hasFallbackUsable != 0,
        fallbackUsable: fallbackUsable,
        hasFullscreenRect: hasFullscreenRect != 0,
        fullscreenRect: fullscreenRect,
        hasMaximizedRect: hasMaximizedRect != 0,
        maximizedRect: maximizedRect
    ) else { return 0 }
    outManaged?.pointee = result.managed ? 1 : 0
    outChanged?.pointee = result.changed ? 1 : 0
    outSpecialChanged?.pointee = result.specialChanged ? 1 : 0
    return 1
}

@MainActor
@Test func interactionStateHostMethodsRoundTrip() throws {
    WindowManager.shared.reset()

    #expect(WindowManager.shared.nextLayoutTransitionID() == 1)
    #expect(WindowManager.shared.nextLayoutTransitionID() == 2)

    var rect = WireWindowRect()
    rect.x = 10
    rect.y = 20
    rect.width = 100
    rect.height = 80
    WindowManager.shared.seedInteractiveStartContext(windowID: 77, cursorX: 5, cursorY: 5, startRect: rect)
    WindowManager.shared.beginInteractiveMove(windowID: 77, serial: 44)
    #expect(WindowManager.shared.interactiveGrabActive() == true)

    let moveUpdate = try #require(try WindowManager.shared.updateInteractiveGrab(cursorX: 15, cursorY: 25))
    #expect(moveUpdate.mode == .move)
    #expect(moveUpdate.windowId == 77)
    #expect(moveUpdate.rect.x == 20)
    #expect(moveUpdate.rect.y == 40)
    #expect(moveUpdate.rect.width == 100)
    #expect(moveUpdate.needsResizeConfigure == false)

    WindowManager.shared.clearGrabFor(windowID: 99)
    #expect(WindowManager.shared.interactiveGrabActive() == true)
    WindowManager.shared.clearGrabFor(windowID: 77)
    #expect(WindowManager.shared.interactiveGrabActive() == false)

    var edges = WireResizeEdges()
    edges.right = true
    edges.bottom = true
    WindowManager.shared.seedInteractiveStartContext(windowID: 88, cursorX: 0, cursorY: 0, startRect: rect)
    WindowManager.shared.beginInteractiveResize(windowID: 88, serial: 45, edges: edges)
    let resizeUpdate = try #require(try WindowManager.shared.updateInteractiveGrab(cursorX: 20, cursorY: 30))
    #expect(resizeUpdate.mode == .resize)
    #expect(resizeUpdate.windowId == 88)
    #expect(resizeUpdate.rect.width == 120)
    #expect(resizeUpdate.rect.height == 110)
    #expect(resizeUpdate.needsResizeConfigure == true)

    WindowManager.shared.endInteractiveGrab()
    #expect(WindowManager.shared.interactiveGrabActive() == false)
}

@MainActor
@Test func tileRegionPolicyComesFromWindowManager() {
    let output = LogicalRect(x: 100, y: 50, width: 1200, height: 800)

    let leftTile = WindowManager.shared.tileRegion(command: TileCommand(rawValue: 1)!, output: output)
    #expect(leftTile.action == .tile)
    #expect(leftTile.rect.x == 100)
    #expect(leftTile.rect.y == 50)
    #expect(leftTile.rect.width == 600)
    #expect(leftTile.rect.height == 800)
    #expect(leftTile.edges.left == true)
    #expect(leftTile.edges.right == false)
    #expect(leftTile.edges.top == true)
    #expect(leftTile.edges.bottom == true)

    let cornerTile = WindowManager.shared.tileRegion(command: TileCommand(rawValue: 6)!, output: output)
    #expect(cornerTile.action == .tile)
    #expect(cornerTile.rect.x == 700)
    #expect(cornerTile.rect.y == 50)
    #expect(cornerTile.rect.width == 600)
    #expect(cornerTile.rect.height == 400)
    #expect(cornerTile.edges.left == false)
    #expect(cornerTile.edges.right == true)
    #expect(cornerTile.edges.top == true)
    #expect(cornerTile.edges.bottom == false)

    let maximize = WindowManager.shared.tileRegion(command: TileCommand(rawValue: 9)!, output: output)
    #expect(maximize.action == .maximize)
    #expect(maximize.rect.x == 100)
    #expect(maximize.rect.y == 50)
    #expect(maximize.rect.width == 1200)
    #expect(maximize.rect.height == 800)
    #expect(maximize.edges.left == true)
    #expect(maximize.edges.right == true)
    #expect(maximize.edges.top == true)
    #expect(maximize.edges.bottom == true)
}

@MainActor
@Test func nativeCommandPolicyMatchesWindowIdentity() {
    NucleusCompositorServer.shared.serverReset()
    WindowManager.shared.reset()

    // xdg toplevel with a native-Command app-id resolves to native. This is the
    // case the Zig side could not see — the app-id lives here — so these clients
    // were previously always translated.
    let kitty = WindowManager.shared.xdgCreated(xdgToplevelID: 1)
    NucleusCompositorServer.shared.window(id: kitty)?.appId = "kitty"
    #expect(WindowManager.shared.nativeCommandPolicy(windowID: kitty) == true)

    // The match is case-insensitive.
    let gnome = WindowManager.shared.xdgCreated(xdgToplevelID: 2)
    NucleusCompositorServer.shared.window(id: gnome)?.appId = "org.GNOME.Terminal"
    #expect(WindowManager.shared.nativeCommandPolicy(windowID: gnome) == true)

    // A non-native xdg app is translated (Command → Control).
    let editor = WindowManager.shared.xdgCreated(xdgToplevelID: 3)
    NucleusCompositorServer.shared.window(id: editor)?.appId = "com.example.editor"
    #expect(WindowManager.shared.nativeCommandPolicy(windowID: editor) == false)

    // Xwayland windows match on either X11 class or instance.
    let xfox = WindowManager.shared.xwaylandCreated(
        x11WindowID: 100, overrideRedirect: false, wantsKeyboardFocus: true)
    WindowManager.shared.xwaylandSetClass(windowID: xfox, windowClass: "firefox", instance: "Navigator")
    #expect(WindowManager.shared.nativeCommandPolicy(windowID: xfox) == true)

    // An unknown window id is not native.
    #expect(WindowManager.shared.nativeCommandPolicy(windowID: 999_999) == false)
}

@MainActor
final class RecordingDesktopObserver: DesktopModelObserver {
    var batches: [[DesktopChange]] = []
    func desktopModelDidChange(_ changes: [DesktopChange]) { batches.append(changes) }
    var flat: [DesktopChange] { batches.flatMap { $0 } }
}

@MainActor
@Test func desktopModelObservationReplaysSnapshotAndStreamsCoalesced() {
    NucleusCompositorServer.shared.serverReset()
    WindowManager.shared.reset()

    // A window that exists before registration is replayed as a snapshot add.
    let pre = WindowManager.shared.xdgCreated(xdgToplevelID: 1)
    let observer = RecordingDesktopObserver()
    NucleusCompositorServer.shared.addObserver(observer)
    #expect(observer.flat.contains(.windowAdded(pre)))

    // Live changes accumulate and dispatch on drain, not synchronously.
    let live = WindowManager.shared.xdgCreated(xdgToplevelID: 2)
    NucleusCompositorServer.shared.window(id: live)?.title = "A"
    NucleusCompositorServer.shared.window(id: live)?.title = "B"
    NucleusCompositorServer.shared.window(id: live)?.appId = "app"
    let batchesBeforeDrain = observer.batches.count
    #expect(observer.batches.count == batchesBeforeDrain)

    NucleusCompositorServer.shared.drainChanges()
    let batch = observer.batches.last ?? []
    #expect(batch.contains(.windowAdded(live)))
    // The two title sets + app-id set in one iteration coalesce to one change.
    #expect(batch.filter { $0 == .windowChanged(live) }.count == 1)

    // Focus + removal stream as their own events.
    _ = WindowManager.shared.server.windows.focus(id: live)
    NucleusCompositorServer.shared.drainChanges()
    #expect((observer.batches.last ?? []).contains(.focusChanged(live)))

    _ = NucleusCompositorServer.shared.destroyWindow(id: live)
    NucleusCompositorServer.shared.drainChanges()
    #expect((observer.batches.last ?? []).contains(.windowRemoved(live)))

    NucleusCompositorServer.shared.removeObserver(observer)
}

@MainActor
@Test func projectedWindowFieldsNotifyObserversForForeignToplevel() {
    // The foreign-toplevel projection is a thin observer: it re-reads a window and
    // restreams title/app_id/state/output whenever the model reports the window
    // changed. This pins the model→observer contract it stands on — that every
    // field the projection mirrors records a change, idempotently and coalesced.
    NucleusCompositorServer.shared.serverReset()
    WindowManager.shared.reset()

    let id = WindowManager.shared.xdgCreated(xdgToplevelID: 1)
    let observer = RecordingDesktopObserver()
    NucleusCompositorServer.shared.addObserver(observer)
    guard let window = NucleusCompositorServer.shared.window(id: id) else {
        Issue.record("missing created window")
        return
    }

    func changedCountAfterDrain() -> Int {
        NucleusCompositorServer.shared.drainChanges()
        return (observer.batches.last ?? []).filter { $0 == .windowChanged(id) }.count
    }

    // Each mirrored field emits exactly one windowChanged on its own drain.
    window.mapped = true
    #expect(changedCountAfterDrain() == 1)
    window.title = "Editor"
    #expect(changedCountAfterDrain() == 1)
    window.appId = "org.example.Editor"
    #expect(changedCountAfterDrain() == 1)
    window.activeMaximized = true
    #expect(changedCountAfterDrain() == 1)
    window.activeFullscreen = true
    #expect(changedCountAfterDrain() == 1)
    window.currentOutputID = 5
    #expect(changedCountAfterDrain() == 1)
    window.mapped = false
    #expect(changedCountAfterDrain() == 1)

    // Re-setting a field to its current value records nothing: no drain batch, so
    // the projection produces no spurious wire traffic.
    let batchesBefore = observer.batches.count
    window.title = "Editor"
    window.appId = "org.example.Editor"
    NucleusCompositorServer.shared.drainChanges()
    #expect(observer.batches.count == batchesBefore)

    // Several mirrored fields changing in one iteration coalesce to one change —
    // one re-read covers them all.
    window.activeMaximized = false
    window.activeFullscreen = false
    window.currentOutputID = 9
    #expect(changedCountAfterDrain() == 1)

    NucleusCompositorServer.shared.removeObserver(observer)
}

@MainActor
@Test func spaceChangesNotifyObserversForExtWorkspace() throws {
    // The ext_workspace projection is a thin observer: it maps spaceAdded/Changed/
    // Removed/Activated and windowSpaceChanged onto per-output group + workspace
    // handles. This pins the model→observer contract it stands on — that each space
    // mutation records the change the projection needs, with no spurious traffic.
    NucleusCompositorServer.shared.serverReset()
    WindowManager.shared.reset()

    let observer = RecordingDesktopObserver()
    NucleusCompositorServer.shared.addObserver(observer)

    // Adding a display creates its initial workspace → spaceAdded streams on drain.
    try seedConfigurePolicyDisplay(id: 7)
    NucleusCompositorServer.shared.drainChanges()
    let firstSpace = NucleusCompositorServer.shared.spacesActiveForDisplay(displayID: 7)
    #expect(firstSpace != 0)
    #expect((observer.batches.last ?? []).contains(.spaceAdded(firstSpace)))

    // Appending a workspace streams another spaceAdded.
    let second = NucleusCompositorServer.shared.spacesAppend(outputID: 7)
    NucleusCompositorServer.shared.drainChanges()
    #expect((observer.batches.last ?? []).contains(.spaceAdded(second)))

    // Switching the active workspace streams spaceActivated for that output/space.
    #expect(NucleusCompositorServer.shared.spacesSetActive(displayID: 7, spaceID: second))
    NucleusCompositorServer.shared.drainChanges()
    #expect((observer.batches.last ?? []).contains(.spaceActivated(output: 7, space: second)))

    // Re-activating the already-active workspace records nothing — no spurious done.
    let batchesBefore = observer.batches.count
    #expect(NucleusCompositorServer.shared.spacesSetActive(displayID: 7, spaceID: second))
    NucleusCompositorServer.shared.drainChanges()
    #expect(observer.batches.count == batchesBefore)

    // Assigning a window to a workspace streams windowSpaceChanged.
    let windowID = WindowManager.shared.xdgCreated(xdgToplevelID: 1)
    #expect(NucleusCompositorServer.shared.spacesAssignWindowToSpace(windowID: windowID, spaceID: firstSpace))
    NucleusCompositorServer.shared.drainChanges()
    #expect((observer.batches.last ?? []).contains(.windowSpaceChanged(window: windowID, space: firstSpace)))

    // Removing an empty, inactive workspace streams spaceRemoved; the active one is
    // refused (still streams nothing).
    let third = NucleusCompositorServer.shared.spacesAppend(outputID: 7)
    NucleusCompositorServer.shared.drainChanges()
    #expect(NucleusCompositorServer.shared.spacesRemove(spaceID: third))
    NucleusCompositorServer.shared.drainChanges()
    #expect((observer.batches.last ?? []).contains(.spaceRemoved(third)))
    // `second` is active → removal refused → no event.
    let beforeRefused = observer.batches.count
    #expect(NucleusCompositorServer.shared.spacesRemove(spaceID: second) == false)
    NucleusCompositorServer.shared.drainChanges()
    #expect(observer.batches.count == beforeRefused)

    NucleusCompositorServer.shared.removeObserver(observer)
}

@MainActor
@Test func fullscreenAndPopupPoliciesUseWindowMechanismHostMethods() throws {
    NucleusCompositorServer.shared.serverReset()
    WindowManager.shared.reset()
    try seedConfigurePolicyDisplay()

    var exceptID: UInt64 = 0
    var firstID: UInt64 = 0
    var secondID: UInt64 = 0
    var parentID: UInt64 = 0
    exceptID = try NucleusCompositorServer.shared.windowCreate(source: .xdg)
    firstID = try NucleusCompositorServer.shared.windowCreate(source: .xdg)
    secondID = try NucleusCompositorServer.shared.windowCreate(source: .xdg)
    parentID = try NucleusCompositorServer.shared.windowCreate(source: .xdg)

    guard let except = NucleusCompositorServer.shared.window(id: exceptID),
          let first = NucleusCompositorServer.shared.window(id: firstID),
          let second = NucleusCompositorServer.shared.window(id: secondID),
          let parent = NucleusCompositorServer.shared.window(id: parentID)
    else {
        Issue.record("missing created windows")
        return
    }

    for window in [except, first, second, parent] {
        window.currentOutputID = 7
        window.mapped = true
        window.managedAppWindow = true
    }
    except.activeFullscreen = true
    first.activeFullscreen = true
    second.requestedFullscreen = true

    let ids = try WindowManager.shared.fullscreenRelinquishPlan(outputID: 7, exceptID: exceptID)
    #expect(ids == [firstID, secondID])

    var parentRect = WireWindowRect()
    parentRect.width = 200
    parentRect.height = 100
    try NucleusCompositorServer.shared.windowSetGeometry(id: parentID, rect: parentRect)

    var positioner = WirePopupPositioner()
    positioner.sizeW = 50
    positioner.sizeH = 20
    positioner.anchorRectX = 10
    positioner.anchorRectY = 20
    positioner.anchorRectW = 100
    positioner.anchorRectH = 40
    positioner.anchor = 8
    positioner.gravity = 8
    positioner.offsetX = 5
    positioner.offsetY = -3

    let resolved = try #require(WindowManager.shared.resolvePopup(parentID: parentID, positioner: positioner))
    #expect(resolved.x == 115)
    #expect(resolved.y == 57)
    #expect(resolved.w == 50)
    #expect(resolved.h == 20)
}

@MainActor
@Test func configureQueueSlotGenerationIsWindowManagerOwned() throws {
    NucleusCompositorServer.shared.serverReset()
    WindowManager.shared.reset()

    var windowID: UInt64 = 0
    windowID = try NucleusCompositorServer.shared.windowCreate(source: .xdg)

    let plan = ConfigurePlan(
        shouldConfigure: true,
        shouldPresent: false,
        isRedundant: false,
        targetRect: WindowRect(x: 10, y: 20, width: 300, height: 200),
        stateMask: XdgStateMask(),
        activeMaximized: false,
        activeFullscreen: false,
        specialOutputID: nil,
        layoutOutputID: nil,
        layoutTransitionID: 0,
        clearRequestedSpecial: false
    )

    let queued1 = try #require(nucleus_compositor_window_manager_record_configure_sent(windowID, 101, plan))
    #expect(queued1.slotGeneration == 1)
    #expect(queued1.serial == 101)

    let queued2 = try #require(nucleus_compositor_window_manager_record_configure_sent(windowID, 102, plan))
    #expect(queued2.slotGeneration == 2)
    #expect(NucleusCompositorServer.shared.windowPendingConfigureCount(id: windowID) == 2)
}

@MainActor
@Test func configurePlanInitialConfigureAckAndFirstCommit() throws {
    NucleusCompositorServer.shared.serverReset()
    WindowManager.shared.reset()
    try seedConfigurePolicyDisplay()

    var windowID: UInt64 = 0
    windowID = try NucleusCompositorServer.shared.windowCreate(source: .xdg)

    let request = ConfigureRequest(windowID: windowID, reason: .initialMap)

    let plan = try #require(WindowManager.shared.planConfigure(request))
    #expect(plan.shouldConfigure == true)
    #expect(plan.targetRect.width > 1)

    let pending = try #require(nucleus_compositor_window_manager_record_configure_sent(windowID, 101, plan))
    #expect(pending.serial == 101)
    #expect(pending.slotGeneration == 1)
    #expect(NucleusCompositorServer.shared.windowPendingConfigureCount(id: windowID) == 1)

    #expect(nucleus_compositor_window_manager_report_configure_ack(windowID, 101) != nil)
    #expect(NucleusCompositorServer.shared.windowPendingConfigureCount(id: windowID) == 0)

    let report = ConfigureCommitReport(
        windowID: windowID,
        ackedSerial: 101,
        commitSequence: 1,
        bufferAttached: true,
        hasBuffer: true,
        committedWidth: plan.targetRect.width,
        committedHeight: plan.targetRect.height
    )
    #expect(nucleus_compositor_window_manager_report_configure_commit(report) == 1)
}

@MainActor
@Test func firstMapPlacementCentersFloatingWindowOnItsOutput() throws {
    NucleusCompositorServer.shared.serverReset()
    WindowManager.shared.reset()
    try seedConfigurePolicyDisplay()

    var windowID: UInt64 = 0
    windowID = try NucleusCompositorServer.shared.windowCreate(source: .xdg)
    NucleusCompositorServer.shared.window(id: windowID)?.currentOutputID = 7

    // A floating window's committed size is centered on its 1600x900 output:
    // (1600-800)/2 = 400, (900-600)/2 = 150.
    let rect = WindowManager.shared.centeredFirstMapRect(windowID: windowID, contentWidth: 800, contentHeight: 600)
    #expect(rect?.x == 400)
    #expect(rect?.y == 150)
    #expect(rect?.width == 800)
    #expect(rect?.height == 600)
}

@MainActor
@Test func firstMapPlacementCentersDialogOverParentAndSkipsSpecial() throws {
    NucleusCompositorServer.shared.serverReset()
    WindowManager.shared.reset()
    try seedConfigurePolicyDisplay()

    var parentID: UInt64 = 0
    var dialogID: UInt64 = 0
    parentID = try NucleusCompositorServer.shared.windowCreate(source: .xdg)
    dialogID = try NucleusCompositorServer.shared.windowCreate(source: .xdg)
    guard let parent = NucleusCompositorServer.shared.window(id: parentID),
          let dialog = NucleusCompositorServer.shared.window(id: dialogID)
    else {
        Issue.record("missing created windows")
        return
    }
    parent.currentOutputID = 7
    parent.mapped = true
    parent.setGeometry(WindowRect(x: 200, y: 100, width: 1000, height: 700))
    dialog.parentWindowID = parentID

    // A dialog is centered over its parent's rect, not its output:
    // 200 + (1000-400)/2 = 500, 100 + (700-300)/2 = 300.
    let rect = WindowManager.shared.centeredFirstMapRect(windowID: dialogID, contentWidth: 400, contentHeight: 300)
    #expect(rect?.x == 500)
    #expect(rect?.y == 300)

    // A special (fullscreen) window owns its placement — no centering.
    dialog.requestedFullscreen = true
    #expect(WindowManager.shared.centeredFirstMapRect(windowID: dialogID, contentWidth: 400, contentHeight: 300) == nil)
}

@MainActor
@Test func mapFocusPolicyComesFromWindowManager() throws {
    NucleusCompositorServer.shared.serverReset()
    WindowManager.shared.reset()
    try seedConfigurePolicyDisplay()

    var targetID: UInt64 = 0
    var fullscreenID: UInt64 = 0
    targetID = try NucleusCompositorServer.shared.windowCreate(source: .xdg)
    fullscreenID = try NucleusCompositorServer.shared.windowCreate(source: .xdg)

    guard let target = NucleusCompositorServer.shared.window(id: targetID),
          let fullscreen = NucleusCompositorServer.shared.window(id: fullscreenID)
    else {
        Issue.record("missing created windows")
        return
    }

    target.currentOutputID = 7
    target.mapped = true
    fullscreen.currentOutputID = 7
    fullscreen.mapped = true
    fullscreen.activeFullscreen = true
    fullscreen.managedAppWindow = true

    #expect(WindowManager.shared.evaluateFocusOnMap(windowID: targetID) == false)

    target.level = 1
    #expect(WindowManager.shared.evaluateFocusOnMap(windowID: targetID) == true)

    target.level = 0
    target.wantsKeyboardFocus = false
    #expect(WindowManager.shared.evaluateFocusOnMap(windowID: targetID) == false)
}

@MainActor
@Test func resizeConfigureWaitsForDelayedAckBeforeConsumingPending() throws {
    NucleusCompositorServer.shared.serverReset()
    WindowManager.shared.reset()
    try seedConfigurePolicyDisplay()

    var windowID: UInt64 = 0
    windowID = try NucleusCompositorServer.shared.windowCreate(source: .xdg)

    let request = ConfigureRequest(
        windowID: windowID,
        reason: .resize,
        targetRect: WindowRect(x: 10, y: 20, width: 900, height: 700),
        resizing: true
    )

    let plan = try #require(WindowManager.shared.planConfigure(request))
    #expect(plan.stateMask.contains(.resizing))

    #expect(nucleus_compositor_window_manager_record_configure_sent(windowID, 200, plan) != nil)
    #expect(nucleus_compositor_window_manager_report_configure_ack(windowID, 199) == nil)
    #expect(NucleusCompositorServer.shared.windowPendingConfigureCount(id: windowID) == 1)
    #expect(nucleus_compositor_window_manager_report_configure_ack(windowID, 200) != nil)
    #expect(NucleusCompositorServer.shared.windowPendingConfigureCount(id: windowID) == 0)
}

@MainActor
@Test func fullscreenExitPreservesSwiftRestoreRect() throws {
    NucleusCompositorServer.shared.serverReset()
    WindowManager.shared.reset()
    try seedConfigurePolicyDisplay()

    var windowID: UInt64 = 0
    windowID = try NucleusCompositorServer.shared.windowCreate(source: .xdg)
    var rect = WireWindowRect()
    rect.x = 80
    rect.y = 90
    rect.width = 640
    rect.height = 480
    try NucleusCompositorServer.shared.windowSetGeometry(id: windowID, rect: rect)

    guard let window = NucleusCompositorServer.shared.window(id: windowID) else {
        Issue.record("missing created window")
        return
    }
    window.requestedFullscreen = true
    window.currentOutputID = 7

    var plan = try #require(WindowManager.shared.planConfigure(
        ConfigureRequest(windowID: windowID, reason: .fullscreen)
    ))
    #expect(plan.stateMask.contains(.fullscreen))

    #expect(window.restoreRect?.x == 80)

    NucleusCompositorServer.shared.windowClearRequestedSpecial(id: windowID)
    plan = try #require(WindowManager.shared.planConfigure(
        ConfigureRequest(windowID: windowID, reason: .restore)
    ))
    #expect(!plan.stateMask.contains(.fullscreen))
    #expect(plan.targetRect.x == 80)
    #expect(plan.targetRect.width == 640)
}

@MainActor
@Test func maximizePlanSurvivesOutputMigration() throws {
    NucleusCompositorServer.shared.serverReset()
    WindowManager.shared.reset()
    try seedConfigurePolicyDisplay()
    try seedConfigurePolicyDisplay(id: 9, x: 1600)

    var windowID: UInt64 = 0
    windowID = try NucleusCompositorServer.shared.windowCreate(source: .xdg)
    guard let window = NucleusCompositorServer.shared.window(id: windowID) else {
        Issue.record("missing created window")
        return
    }
    window.requestedMaximized = true
    window.currentOutputID = 7
    window.specialOutputID = 7

    let plan = try #require(WindowManager.shared.planConfigure(
        ConfigureRequest(windowID: windowID, reason: .maximize)
    ))
    #expect(plan.stateMask.contains(.maximized))

    var usable = WireUsableArea()
    usable.w = 1600
    usable.h = 900
    var migratedRect = WireWindowRect()
    migratedRect.x = 1600
    migratedRect.width = 1600
    migratedRect.height = 900
    var managed: UInt8 = 0
    var changed: UInt8 = 0
    var specialChanged: UInt8 = 0
    #expect(nucleus_compositor_window_manager_migrate_off_output(
        windowID,
        7,
        1, 9,
        1, usable,
        1, usable,
        1, migratedRect,
        1, migratedRect,
        &managed,
        &changed,
        &specialChanged
    ) == 1)
    #expect(specialChanged == 1)
}

@MainActor
@Test func tileConfigurePlanOwnsEdgesAndGeometry() throws {
    NucleusCompositorServer.shared.serverReset()
    WindowManager.shared.reset()
    try seedConfigurePolicyDisplay()

    var windowID: UInt64 = 0
    windowID = try NucleusCompositorServer.shared.windowCreate(source: .xdg)
    let request = ConfigureRequest(
        windowID: windowID,
        reason: .tile,
        targetRect: WindowRect(width: 800, height: 900),
        targetOutputID: 7,
        tileEdges: TileEdges(left: true, top: true, bottom: true)
    )

    let plan = try #require(WindowManager.shared.planConfigure(request))
    #expect(plan.shouldConfigure == true)
    #expect(plan.stateMask.contains(.tiledLeft))
    #expect(plan.stateMask.contains(.tiledTop))
    #expect(plan.targetRect.width == 800)
}

@MainActor
@Test func xwaylandStateRequestsUseConfigurePlanGeometry() throws {
    NucleusCompositorServer.shared.serverReset()
    WindowManager.shared.reset()
    try seedConfigurePolicyDisplay()

    let windowID = WindowManager.shared.xwaylandCreated(x11WindowID: 0x70001, overrideRedirect: false, wantsKeyboardFocus: true)
    let request = XwaylandStateRequest(
        windowID: windowID,
        action: 1,
        stateMask: UInt64(xwaylandNetStateFullscreen),
        sourceIndication: 0
    )
    let statePlan = WindowManager.shared.xwaylandHandleStateRequest(request)
    #expect(statePlan.requestConfigure == true)

    let plan = try #require(WindowManager.shared.planConfigure(
        ConfigureRequest(windowID: windowID, reason: .xwaylandStateRequest)
    ))
    #expect(plan.activeFullscreen == true)
    #expect(plan.targetRect.width == 1600)
    #expect(plan.targetRect.height == 900)
}

@MainActor
@Test func staleConfigureAckIsIgnored() throws {
    NucleusCompositorServer.shared.serverReset()
    WindowManager.shared.reset()
    try seedConfigurePolicyDisplay()

    var windowID: UInt64 = 0
    windowID = try NucleusCompositorServer.shared.windowCreate(source: .xdg)
    let plan = try #require(WindowManager.shared.planConfigure(
        ConfigureRequest(windowID: windowID, reason: .initialMap)
    ))
    #expect(nucleus_compositor_window_manager_record_configure_sent(windowID, 300, plan) != nil)
    #expect(nucleus_compositor_window_manager_report_configure_ack(windowID, 299) == nil)
    #expect(NucleusCompositorServer.shared.windowPendingConfigureCount(id: windowID) == 1)
}

@MainActor
@Test func configureAckAppliesCanonicalWindowGeometryAndState() throws {
    NucleusCompositorServer.shared.serverReset()
    WindowManager.shared.reset()

    var windowID: UInt64 = 0
    windowID = try NucleusCompositorServer.shared.windowCreate(source: .xdg)

    let plan = ConfigurePlan(
        shouldConfigure: true,
        shouldPresent: false,
        isRedundant: false,
        targetRect: WindowRect(x: 40, y: 50, width: 640, height: 480),
        stateMask: XdgStateMask(),
        activeMaximized: true,
        activeFullscreen: false,
        specialOutputID: 7,
        layoutOutputID: nil,
        layoutTransitionID: 0,
        clearRequestedSpecial: false
    )

    #expect(nucleus_compositor_window_manager_record_configure_sent(windowID, 501, plan) != nil)
    #expect(NucleusCompositorServer.shared.windowPendingConfigureCount(id: windowID) == 1)
    #expect(nucleus_compositor_window_manager_report_configure_ack(windowID, 501) != nil)
    #expect(NucleusCompositorServer.shared.windowPendingConfigureCount(id: windowID) == 0)

    let geometry = try NucleusCompositorServer.shared.windowGetGeometry(id: windowID)
    // Placement comes from the configure; size does not. The client owns its
    // size (a fixed-size window acks a configure it won't honor), so the
    // configured 640x480 is intentionally ignored and the window keeps its
    // committed size — here the 1x1 default, since this test commits no buffer.
    #expect(geometry.x == 40)
    #expect(geometry.y == 50)
    #expect(geometry.width == 1)
    #expect(geometry.height == 1)
    #expect(NucleusCompositorServer.shared.windowGetActiveMaximized(id: windowID))
    #expect(!NucleusCompositorServer.shared.windowGetActiveFullscreen(id: windowID))
    #expect(NucleusCompositorServer.shared.window(id: windowID)?.specialOutputID == 7)
}

@MainActor
@Test func windowDestroyDuringInFlightConfigureDropsPendingState() throws {
    NucleusCompositorServer.shared.serverReset()
    WindowManager.shared.reset()
    try seedConfigurePolicyDisplay()

    let windowID = WindowManager.shared.xdgCreated(xdgToplevelID: 0x5501)
    #expect(windowID != 0)

    let plan = try #require(WindowManager.shared.planConfigure(
        ConfigureRequest(windowID: windowID, reason: .initialMap)
    ))
    #expect(nucleus_compositor_window_manager_record_configure_sent(windowID, 401, plan) != nil)
    #expect(NucleusCompositorServer.shared.windowPendingConfigureCount(id: windowID) == 1)

    WindowManager.shared.xdgDestroyed(windowID: windowID)
    try NucleusCompositorServer.shared.windowDestroy(id: windowID)
    #expect(WindowManager.shared.xdgRole(windowID: windowID) == nil)
    #expect(NucleusCompositorServer.shared.window(id: windowID) == nil)

    #expect(NucleusCompositorServer.shared.windowPendingConfigureCount(id: windowID) == 0)
    #expect(NucleusCompositorServer.shared.window(id: windowID)?.protocolState.latest == nil)
    #expect(NucleusCompositorServer.shared.window(id: windowID)?.protocolState.configure(forAckSerial: 401) == nil)
    #expect(nucleus_compositor_window_manager_report_configure_ack(windowID, 401) == nil)

    let report = ConfigureCommitReport(
        windowID: windowID,
        ackedSerial: 401,
        commitSequence: 0,
        bufferAttached: true,
        hasBuffer: true,
        committedWidth: plan.targetRect.width,
        committedHeight: plan.targetRect.height
    )
    #expect(nucleus_compositor_window_manager_report_configure_commit(report) == 0)
}

@MainActor
@Test func outputNormalizationPolicyComesFromWindowManager() throws {
    NucleusCompositorServer.shared.serverReset()
    WindowManager.shared.reset()

    var mode = WireDisplayMode()
    mode.pixelWidth = 1000
    mode.pixelHeight = 800
    var config = WireDisplayConfiguration()
    config.enabled = true
    config.primary = true
    config.scale = 1
    config.mode = mode
    try NucleusCompositorServer.shared.displayAdd(id: 9, configuration: config)

    var windowID: UInt64 = 0
    windowID = try NucleusCompositorServer.shared.windowCreate(source: .xdg)

    guard let window = NucleusCompositorServer.shared.window(id: windowID) else {
        Issue.record("missing created window")
        return
    }
    window.currentOutputID = 7
    window.preferredOutputID = 7
    window.specialOutputID = 7
    window.restoreOutputID = 7
    window.requestedFullscreen = true
    window.restoreRect = WindowRect(x: 10, y: 10, width: 400, height: 300)

    var translated = WireWindowRect()
    translated.x = 1600
    translated.y = 100
    translated.width = 400
    translated.height = 300
    #expect(nucleus_compositor_window_manager_normalize_output_state(windowID, 9, 1, translated, 9) == 1)

    #expect(window.currentOutputID == 9)
    #expect(window.preferredOutputID == 9)
    #expect(window.specialOutputID == 9)
    #expect(window.restoreOutputID == 9)
    #expect(window.restoreRect?.x == 1600)
}

@MainActor
@Test func outputMigrationPolicyMutatesWindowManagerStateAndPendingConfigures() throws {
    NucleusCompositorServer.shared.serverReset()
    WindowManager.shared.reset()

    var mode = WireDisplayMode()
    mode.pixelWidth = 1600
    mode.pixelHeight = 900
    mode.refreshMhz = 60000
    var config = WireDisplayConfiguration()
    config.enabled = true
    config.primary = true
    config.scale = 1
    config.mode = mode
    try NucleusCompositorServer.shared.displayAdd(id: 7, configuration: config)
    config.logicalX = 1600
    try NucleusCompositorServer.shared.displayAdd(id: 9, configuration: config)

    var windowID: UInt64 = 0
    windowID = try NucleusCompositorServer.shared.windowCreate(source: .xdg)
    guard let window = NucleusCompositorServer.shared.window(id: windowID) else {
        Issue.record("missing created window")
        return
    }
    window.currentOutputID = 7
    window.preferredOutputID = 7
    window.specialOutputID = 7
    window.restoreOutputID = 7
    window.activeFullscreen = true
    window.restoreRect = WindowRect(x: 100, y: 100, width: 500, height: 400)

    let pendingPlan = ConfigurePlan(
        shouldConfigure: true,
        shouldPresent: false,
        isRedundant: false,
        targetRect: WindowRect(width: 1600, height: 900),
        stateMask: XdgStateMask(),
        activeMaximized: false,
        activeFullscreen: true,
        specialOutputID: 7,
        layoutOutputID: nil,
        layoutTransitionID: 0,
        clearRequestedSpecial: false
    )
    #expect(nucleus_compositor_window_manager_record_configure_sent(windowID, 11, pendingPlan) != nil)

    var usable = WireUsableArea()
    usable.w = 1600
    usable.h = 900
    var fullscreen = WireWindowRect()
    fullscreen.x = 1600
    fullscreen.width = 1600
    fullscreen.height = 900
    let maximized = fullscreen

    var managed: UInt8 = 0
    var changed: UInt8 = 0
    var specialChanged: UInt8 = 0
    #expect(nucleus_compositor_window_manager_migrate_off_output(
        windowID,
        7,
        1, 9,
        1, usable,
        1, usable,
        1, fullscreen,
        1, maximized,
        &managed,
        &changed,
        &specialChanged
    ) == 1)
    #expect(managed == 1)
    #expect(changed == 1)
    #expect(specialChanged == 1)

    #expect(window.currentOutputID == 9)
    #expect(window.preferredOutputID == 9)
    #expect(window.specialOutputID == 9)
    #expect(window.restoreOutputID == 9)

    let queriedPending = try #require(NucleusCompositorServer.shared.window(id: windowID)?.protocolState.latest)
    #expect(queriedPending.specialOutputID == 9)
    #expect(queriedPending.rect.x == 1600)
}

@MainActor
@Test func layerShellPolicyComputesExclusiveZones() throws {
    NucleusCompositorServer.shared.serverReset()
    WindowManager.shared.reset()
    try seedConfigurePolicyDisplay()
    try seedConfigurePolicyDisplay(id: 9, x: 1600)

    let top = layerSurfaceRecord(
        id: 10,
        outputID: 7,
        anchor: 1 | 4 | 8,
        exclusiveZone: 20,
        marginTop: 5
    )
    let left = layerSurfaceRecord(
        id: 11,
        outputID: 7,
        anchor: 1 | 2 | 4,
        exclusiveZone: 10,
        marginLeft: 2
    )

    #expect(WindowManager.shared.layerShellPolicy.register(top) == true)
    #expect(WindowManager.shared.layerShellPolicy.register(left) == true)

    let zones = try #require(WindowManager.shared.layerShellPolicy.recalcZones(outputID: 7))
    #expect(zones.top == 25)
    #expect(zones.left == 12)
    #expect(WindowManager.shared.layerShellPolicy.hasMappedSurface(outputID: 7) == true)

    var topUnmapped = top
    topUnmapped.mapped = false
    WindowManager.shared.layerShellPolicy.update(topUnmapped)
    let zonesAfterUnmap = try #require(WindowManager.shared.layerShellPolicy.recalcZones(outputID: 7))
    #expect(zonesAfterUnmap.top == 0)
    #expect(zonesAfterUnmap.left == 12)

    WindowManager.shared.layerShellPolicy.unregister(id: 10)

    let resolvedOutput = WindowManager.shared.layerShellPolicy.resolveOutput(requestedID: 0, namespace: "panel", server: .shared)
    #expect(resolvedOutput != nil)
    #expect((resolvedOutput ?? 0) != 0)
}

@MainActor
@Test func xdgRoleStateSurfaceMutatesWindowManagerRecords() {
    NucleusCompositorServer.shared.serverReset()
    WindowManager.shared.reset()

    let windowID = WindowManager.shared.xdgCreated(xdgToplevelID: 0xabc)
    #expect(windowID != 0)
    #expect(NucleusCompositorServer.shared.window(id: windowID)?.source == .xdg)

    // Title/app-id are normalized onto the Window model (the single metadata
    // home); parent + special-mode requests still flow through the role surface.
    NucleusCompositorServer.shared.window(id: windowID)?.title = "Terminal"
    NucleusCompositorServer.shared.window(id: windowID)?.appId = "org.example.Terminal"
    WindowManager.shared.xdgSetParent(windowID: windowID, parentWindowID: 42)
    WindowManager.shared.xdgRequestFullscreen(windowID: windowID, target: 7)
    WindowManager.shared.xdgRequestMaximize(windowID: windowID, requested: true)

    let role = WindowManager.shared.xdgRole(windowID: windowID)
    #expect(NucleusCompositorServer.shared.window(id: windowID)?.title == "Terminal")
    #expect(NucleusCompositorServer.shared.window(id: windowID)?.appId == "org.example.Terminal")
    #expect(role?.parentWindowID == 42)
    #expect(role?.requestedFullscreenTarget == 7)
    #expect(NucleusCompositorServer.shared.window(id: windowID)?.requestedFullscreen == true)
    #expect(NucleusCompositorServer.shared.window(id: windowID)?.requestedMaximized == true)

    WindowManager.shared.xdgUnsetFullscreen(windowID: windowID)
    WindowManager.shared.xdgRequestMaximize(windowID: windowID, requested: false)
    #expect(NucleusCompositorServer.shared.window(id: windowID)?.requestedFullscreen == false)
    #expect(NucleusCompositorServer.shared.window(id: windowID)?.requestedMaximized == false)

    WindowManager.shared.xdgDestroyed(windowID: windowID)
    #expect(WindowManager.shared.xdgRole(windowID: windowID) == nil)
}

@MainActor
@Test func xdgRoleIdentityIsWindowPrimaryWithToplevelIndex() throws {
    NucleusCompositorServer.shared.serverReset()
    WindowManager.shared.reset()

    let first = WindowManager.shared.xdgCreated(xdgToplevelID: 0xabc)
    let duplicate = WindowManager.shared.xdgCreated(xdgToplevelID: 0xabc)
    #expect(duplicate == first)
    #expect(WindowManager.shared.xdgRole(windowID: first)?.xdgToplevelID == 0xabc)

    WindowManager.shared.xdgDestroyed(windowID: first)
    #expect(WindowManager.shared.xdgRole(windowID: first) == nil)
    try NucleusCompositorServer.shared.windowDestroy(id: first)

    let second = WindowManager.shared.xdgCreated(xdgToplevelID: 0xabc)
    #expect(second != 0)
    #expect(second != first)
    #expect(WindowManager.shared.xdgRole(windowID: second)?.xdgToplevelID == 0xabc)
}

@MainActor
@Test func xwaylandRoleStateSurfaceMutatesWindowManagerRecords() {
    NucleusCompositorServer.shared.serverReset()
    WindowManager.shared.reset()

    let windowID = WindowManager.shared.xwaylandCreated(x11WindowID: 0x12004, overrideRedirect: false, wantsKeyboardFocus: true)
    #expect(windowID != 0)
    #expect(NucleusCompositorServer.shared.window(id: windowID)?.source == .xwayland)
    #expect(NucleusCompositorServer.shared.window(id: windowID)?.wantsKeyboardFocus == true)

    WindowManager.shared.xwaylandSetTitle(windowID: windowID, title: "XTerm")
    WindowManager.shared.xwaylandSetClass(windowID: windowID, windowClass: "XTermClass")
    let metadata = XwaylandWindowMetadata(
        x11WindowID: 0x12004,
        transientForX11: 0,
        windowTypeMask: UInt64(xwaylandWindowTypeDialog),
        netStateMask: 0,
        protocolMask: UInt32(xwaylandProtocolTakeFocus),
        pid: 0,
        userTime: 0,
        overrideRedirect: false,
        inputHint: false,
        urgent: false,
        decorationsOff: false
    )
    WindowManager.shared.xwaylandApplyMetadata(windowID: windowID, metadata: metadata)

    let role = WindowManager.shared.xwaylandRole(windowID: windowID)
    #expect(role?.x11WindowID == 0x12004)
    #expect(role?.title == "XTerm")
    #expect(role?.windowClass == "XTermClass")
    #expect(role?.focusModel == .globallyActive)
    #expect(role?.windowTypes.contains(.dialog) == true)
    #expect(role?.wantsKeyboardFocus == true)
    #expect(NucleusCompositorServer.shared.window(id: windowID)?.wantsKeyboardFocus == true)

    WindowManager.shared.xwaylandDestroyed(windowID: windowID)
    #expect(WindowManager.shared.xwaylandRole(windowID: windowID) == nil)
}

@MainActor
@Test func xwaylandRoleIdentityIsWindowPrimaryWithXIDIndex() throws {
    NucleusCompositorServer.shared.serverReset()
    WindowManager.shared.reset()

    let parent = WindowManager.shared.xwaylandCreated(x11WindowID: 0x12004, overrideRedirect: false, wantsKeyboardFocus: true)
    let duplicate = WindowManager.shared.xwaylandCreated(x11WindowID: 0x12004, overrideRedirect: false, wantsKeyboardFocus: true)
    #expect(duplicate == parent)

    let child = WindowManager.shared.xwaylandCreated(x11WindowID: 0x12005, overrideRedirect: false, wantsKeyboardFocus: true)
    let childMetadata = XwaylandWindowMetadata(
        x11WindowID: 0x12005,
        transientForX11: 0x12004,
        windowTypeMask: 0,
        netStateMask: 0,
        protocolMask: 0,
        pid: 0,
        userTime: 0,
        overrideRedirect: false,
        inputHint: true,
        urgent: false,
        decorationsOff: false
    )
    WindowManager.shared.xwaylandApplyMetadata(windowID: child, metadata: childMetadata)
    #expect(WindowManager.shared.xwaylandRole(windowID: child)?.parentWindowID == parent)

    WindowManager.shared.xwaylandDestroyed(windowID: parent)
    #expect(WindowManager.shared.xwaylandRole(windowID: parent) == nil)
    try NucleusCompositorServer.shared.windowDestroy(id: parent)

    let replacement = WindowManager.shared.xwaylandCreated(x11WindowID: 0x12004, overrideRedirect: false, wantsKeyboardFocus: true)
    #expect(replacement != 0)
    #expect(replacement != parent)
    WindowManager.shared.xwaylandApplyMetadata(windowID: child, metadata: childMetadata)
    #expect(WindowManager.shared.xwaylandRole(windowID: child)?.parentWindowID == replacement)
}

@MainActor
@Test func xwaylandMetadataLateUpdatesFlowThroughSwift() {
    NucleusCompositorServer.shared.serverReset()
    WindowManager.shared.reset()

    let windowID = WindowManager.shared.xwaylandCreated(x11WindowID: 0x20001, overrideRedirect: false, wantsKeyboardFocus: true)
    WindowManager.shared.xwaylandApplyMetadata(
        windowID: windowID,
        metadata: XwaylandWindowMetadata(
            x11WindowID: 0x20001,
            transientForX11: 0,
            windowTypeMask: UInt64(xwaylandWindowTypeNormal),
            netStateMask: 0,
            protocolMask: 0,
            pid: 0,
            userTime: 0,
            overrideRedirect: false,
            inputHint: true,
            urgent: false,
            decorationsOff: false
        )
    )

    WindowManager.shared.xwaylandApplyMetadata(
        windowID: windowID,
        metadata: XwaylandWindowMetadata(
            x11WindowID: 0x20001,
            transientForX11: 0,
            windowTypeMask: UInt64(xwaylandWindowTypeDialog),
            netStateMask: UInt64(xwaylandNetStateDemandsAttention),
            protocolMask: 0,
            pid: 0,
            userTime: 0,
            overrideRedirect: false,
            inputHint: true,
            urgent: false,
            decorationsOff: true
        )
    )

    let role = WindowManager.shared.xwaylandRole(windowID: windowID)
    #expect(role?.windowTypes.contains(.dialog) == true)
    #expect(role?.urgent == true)
    #expect(role?.decorationsOff == true)
}

@MainActor
@Test func xwaylandNetWmStateRequestsMutateSwiftPolicy() throws {
    NucleusCompositorServer.shared.serverReset()
    WindowManager.shared.reset()

    let windowID = WindowManager.shared.xwaylandCreated(x11WindowID: 0x20002, overrideRedirect: false, wantsKeyboardFocus: true)
    WindowManager.shared.xwaylandApplyMetadata(
        windowID: windowID,
        metadata: XwaylandWindowMetadata(
            x11WindowID: 0x20002,
            transientForX11: 0,
            windowTypeMask: 0,
            netStateMask: 0,
            protocolMask: 0,
            pid: 0,
            userTime: 0,
            overrideRedirect: false,
            inputHint: true,
            urgent: false,
            decorationsOff: false
        )
    )

    var plan = WindowManager.shared.xwaylandHandleStateRequest(XwaylandStateRequest(
        windowID: windowID,
        action: 1,
        stateMask: UInt64(xwaylandNetStateFullscreen) | UInt64(xwaylandNetStateMaximizedVert),
        sourceIndication: 0
    ))
    #expect(plan.handled == true)
    #expect(plan.requestConfigure == true)
    #expect(plan.requestedFullscreen == true)
    #expect(plan.requestedMaximized == false)
    #expect(NucleusCompositorServer.shared.window(id: windowID)?.requestedFullscreen == true)

    plan = WindowManager.shared.xwaylandHandleStateRequest(XwaylandStateRequest(
        windowID: windowID,
        action: 0,
        stateMask: UInt64(xwaylandNetStateFullscreen),
        sourceIndication: 0
    ))
    #expect(plan.requestedFullscreen == false)
    #expect(NucleusCompositorServer.shared.window(id: windowID)?.requestedFullscreen == false)

    plan = WindowManager.shared.xwaylandHandleStateRequest(XwaylandStateRequest(
        windowID: windowID,
        action: 2,
        stateMask: UInt64(xwaylandNetStateMaximizedHorz),
        sourceIndication: 0
    ))
    #expect(plan.requestedMaximized == true)
    #expect(plan.netState.contains(.maximizedVert))
    #expect(plan.netState.contains(.maximizedHorz))
}

@MainActor
@Test func xwaylandFocusPlansCoverICCCMModelsAndOverrideRedirect() throws {
    NucleusCompositorServer.shared.serverReset()
    WindowManager.shared.reset()

    let passive = WindowManager.shared.xwaylandCreated(x11WindowID: 0x30001, overrideRedirect: false, wantsKeyboardFocus: true)
    let locallyActive = WindowManager.shared.xwaylandCreated(x11WindowID: 0x30002, overrideRedirect: false, wantsKeyboardFocus: true)
    let globallyActive = WindowManager.shared.xwaylandCreated(x11WindowID: 0x30003, overrideRedirect: false, wantsKeyboardFocus: true)
    let noInput = WindowManager.shared.xwaylandCreated(x11WindowID: 0x30004, overrideRedirect: false, wantsKeyboardFocus: true)
    let passiveOR = WindowManager.shared.xwaylandCreated(x11WindowID: 0x30005, overrideRedirect: true, wantsKeyboardFocus: true)

    func apply(_ windowID: UInt64, xid: UInt64, input: UInt8, takeFocus: Bool, overrideRedirect: UInt8 = 0, types: UInt64 = 0) {
        let metadata = XwaylandWindowMetadata(
            x11WindowID: xid,
            transientForX11: 0,
            windowTypeMask: types,
            netStateMask: 0,
            protocolMask: takeFocus ? UInt32(xwaylandProtocolTakeFocus) : 0,
            pid: 0,
            userTime: 0,
            overrideRedirect: overrideRedirect != 0,
            inputHint: input != 0,
            urgent: false,
            decorationsOff: false
        )
        WindowManager.shared.xwaylandApplyMetadata(windowID: windowID, metadata: metadata)
    }

    apply(passive, xid: 0x30001, input: 1, takeFocus: false)
    apply(locallyActive, xid: 0x30002, input: 1, takeFocus: true)
    apply(globallyActive, xid: 0x30003, input: 0, takeFocus: true)
    apply(noInput, xid: 0x30004, input: 0, takeFocus: false)
    apply(passiveOR, xid: 0x30005, input: 1, takeFocus: true, overrideRedirect: 1, types: UInt64(xwaylandWindowTypeTooltip))

    var focusPlan = WindowManager.shared.xwaylandFocusPlan(windowID: passive)
    #expect((focusPlan.actions & UInt32(xwaylandFocusSetInput)) != 0)
    #expect((focusPlan.actions & UInt32(xwaylandFocusTakeFocus)) == 0)

    focusPlan = WindowManager.shared.xwaylandFocusPlan(windowID: locallyActive)
    #expect((focusPlan.actions & UInt32(xwaylandFocusSetInput)) != 0)
    #expect((focusPlan.actions & UInt32(xwaylandFocusTakeFocus)) != 0)

    focusPlan = WindowManager.shared.xwaylandFocusPlan(windowID: globallyActive)
    #expect((focusPlan.actions & UInt32(xwaylandFocusSetInput)) == 0)
    #expect((focusPlan.actions & UInt32(xwaylandFocusTakeFocus)) != 0)

    focusPlan = WindowManager.shared.xwaylandFocusPlan(windowID: noInput)
    #expect(focusPlan.actions == 0)

    focusPlan = WindowManager.shared.xwaylandFocusPlan(windowID: passiveOR)
    #expect((focusPlan.actions & UInt32(xwaylandFocusDenied)) != 0)

    focusPlan = WindowManager.shared.xwaylandClearFocusPlan()
    #expect((focusPlan.actions & UInt32(xwaylandFocusClear)) != 0)
    #expect(focusPlan.activeX11Window == 0)
}

@MainActor
@Test func xwaylandCloseAndClientListPoliciesComeFromSwift() throws {
    NucleusCompositorServer.shared.serverReset()
    WindowManager.shared.reset()

    let managed = WindowManager.shared.xwaylandCreated(x11WindowID: 0x40001, overrideRedirect: false, wantsKeyboardFocus: true)
    let directDestroy = WindowManager.shared.xwaylandCreated(x11WindowID: 0x40002, overrideRedirect: false, wantsKeyboardFocus: true)
    let overrideRedirect = WindowManager.shared.xwaylandCreated(x11WindowID: 0x40003, overrideRedirect: true, wantsKeyboardFocus: true)

    WindowManager.shared.xwaylandApplyMetadata(
        windowID: managed,
        metadata: XwaylandWindowMetadata(
            x11WindowID: 0x40001,
            transientForX11: 0,
            windowTypeMask: 0,
            netStateMask: 0,
            protocolMask: UInt32(xwaylandProtocolDeleteWindow),
            pid: 0,
            userTime: 0,
            overrideRedirect: false,
            inputHint: true,
            urgent: false,
            decorationsOff: false
        )
    )

    WindowManager.shared.xwaylandApplyMetadata(
        windowID: directDestroy,
        metadata: XwaylandWindowMetadata(
            x11WindowID: 0x40002,
            transientForX11: 0,
            windowTypeMask: 0,
            netStateMask: 0,
            protocolMask: 0,
            pid: 0,
            userTime: 0,
            overrideRedirect: false,
            inputHint: true,
            urgent: false,
            decorationsOff: false
        )
    )

    WindowManager.shared.xwaylandApplyMetadata(
        windowID: overrideRedirect,
        metadata: XwaylandWindowMetadata(
            x11WindowID: 0x40003,
            transientForX11: 0,
            windowTypeMask: UInt64(xwaylandWindowTypePopupMenu),
            netStateMask: 0,
            protocolMask: 0,
            pid: 0,
            userTime: 0,
            overrideRedirect: true,
            inputHint: true,
            urgent: false,
            decorationsOff: false
        )
    )

    var closePlan = WindowManager.shared.xwaylandClosePlan(windowID: managed)
    #expect(closePlan.action == UInt32(xwaylandCloseDeleteWindow))
    closePlan = WindowManager.shared.xwaylandClosePlan(windowID: directDestroy)
    #expect(closePlan.action == UInt32(xwaylandCloseDestroy))

    #expect(WindowManager.shared.xwaylandClientListIncludes(windowID: managed) == true)
    #expect(WindowManager.shared.xwaylandClientListIncludes(windowID: overrideRedirect) == false)
    #expect(WindowManager.shared.xwaylandClientXIDs() == [0x40001, 0x40002])

    #expect(WindowManager.shared.server.windows.raise(id: managed))
    #expect(WindowManager.shared.xwaylandClientXIDs() == [0x40002, 0x40001])
}
