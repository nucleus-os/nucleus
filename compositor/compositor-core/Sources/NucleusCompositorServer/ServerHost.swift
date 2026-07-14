import NucleusTypes
import NucleusCompositorServerTypes

/// Shared failure type for NucleusCompositorServer caller-boundary (`*Host`)
/// requirements that surface a success/failure split as an error. One
/// case: the receiving reactor wrapper maps any thrown error to its single
/// `error{HostCallFailed}` tag. translate-swift mirrors `throws(HostCallError)`
/// requirements as `error{HostCallFailed}!T`.
public enum HostCallError: Error {
    case failed
}

@MainActor
public protocol ServerHost: AnyObject {
    func displayOutputForPoint(x: Double, y: Double) -> UInt64
    func cursorServerSetImage(imageHandle: UInt64, width: UInt32, height: UInt32)
    func cursorServerSetHotSpot(x: Int32, y: Int32)
    func seatFocusGetSnapshot() throws(HostCallError) -> WireSeatFocusSnapshot
    func serverReset()
    func displayAdd(id: UInt64, configuration: WireDisplayConfiguration) throws(HostCallError)
    func displayRemove(id: UInt64) throws(HostCallError)
    func displayConfigure(id: UInt64, changes: WireDisplayConfigurationChanges) throws(HostCallError)
    func displayLayoutUpdate() throws(HostCallError)
    func displayPrimaryID() -> UInt64
    func displayFallbackForRemoval(removedID: UInt64) -> UInt64
    func displayDesktopBounds() throws(HostCallError) -> WireLogicalRect
    func displayFind(id: UInt64) throws(HostCallError) -> WireLogicalRect
    func displayFractionalScaleAt(x: Double, y: Double) -> Double
    func displayFractionalScaleForOutput(id: UInt64) -> Double
    func displayUsableArea(id: UInt64) throws(HostCallError) -> WireUsableArea
    func windowCreate(source: WindowSource) throws(HostCallError) -> UInt64
    func windowDestroy(id: UInt64) throws(HostCallError)
    func windowSetGeometry(id: UInt64, rect: WireWindowRect) throws(HostCallError)
    func windowGetGeometry(id: UInt64) throws(HostCallError) -> WireWindowRect
    func windowGetRequestedMaximized(id: UInt64) -> Bool
    func windowGetRequestedFullscreen(id: UInt64) -> Bool
    func windowGetActiveMaximized(id: UInt64) -> Bool
    func windowGetActiveFullscreen(id: UInt64) -> Bool
    func windowGetManagedAppWindow(id: UInt64) -> Bool
    func windowGetWantsKeyboardFocus(id: UInt64) -> Bool
    func windowGetCurrentOutput(id: UInt64) -> UInt64
    func windowGetLevel(id: UInt64) -> Int32
    func windowGetTileEdges(id: UInt64) throws(HostCallError) -> WireResizeEdges
    func windowAllocSlotGeneration(id: UInt64) -> UInt64
    func windowSetMapped(id: UInt64, mapped: Bool)
    func windowNoteSurfaceOutput(id: UInt64, outputID: UInt64)
    func windowClearRequestedSpecial(id: UInt64)
    func windowPendingConfigureCount(id: UInt64) -> UInt32
    func windowListRaise(id: UInt64) -> Bool
    func windowListBelow(id: UInt64, siblingID: UInt64) -> Bool
    func windowListFocus(id: UInt64) -> Bool
    func windowRenderOrderCount(frontToBack: Bool) -> UInt64
    func windowRenderOrderFill(frontToBack: Bool, into out: inout OutputSpan<WireWindowRenderOrderEntry>)
    func spacesActiveForDisplay(displayID: UInt64) -> UInt32
    func spacesSetActive(displayID: UInt64, spaceID: UInt32) -> Bool
    func spacesOverlayDisplayID() -> UInt64
    func spacesCreate(outputID: UInt64) throws(HostCallError) -> UInt32
    func spacesEnsureForOutput(outputID: UInt64, index: UInt32) -> UInt32
    func spacesAppend(outputID: UInt64) -> UInt32
    func spacesRemove(spaceID: UInt32) -> Bool
    func spacesAssignWindowToSpace(windowID: UInt64, spaceID: UInt32) -> Bool
    func windowGetSpaceHidden(id: UInt64) -> Bool
    func windowCopyPolicySnapshot(windowID: UInt64) throws(HostCallError) -> WireWindowPolicySnapshot
    func spacesOutputLayoutSnapshot(
        outputID: UInt64,
        usable: WireUsableArea
    ) throws(HostCallError) -> WireOutputLayoutSnapshot
    func eventServerDispatch(
        event: WireEventRecord,
        bounds: WirePointerBounds
    ) throws(HostCallError) -> WireEventDispatchDecision
    func eventServerResetInputState()
    func eventServerSetFlags(flags: UInt64)
    func eventServerSetCursor(x: Double, y: Double)
    func eventServerCursorX() -> Double
    func eventServerCursorY() -> Double
    func seatFocusSetPointer(surfaceID: UInt64)
    func seatFocusClearPointer()
    func seatFocusSetKeyboard(surfaceID: UInt64)
    func seatFocusClearKeyboard()
    func seatFocusRecordPointerButton(state: UInt32, serial: UInt32, focusedSurfaceID: UInt64)
    func seatFocusResetPointerButtons()
    func seatFocusInvalidateSurface(surfaceID: UInt64)
    func windowGetChromeInsets(id: UInt64) throws(HostCallError) -> WireChromeInsets
    func windowChromeHit(id: UInt64, frameLocalX: Double, frameLocalY: Double, frameWidth: Double, frameHeight: Double) -> UInt64
    func windowCapabilities(id: UInt64) -> UInt32
}

// `NucleusCompositorServer` is the live state object; it fulfills the caller-boundary
// contract directly. Each requirement reads/mutates the server in place and
// returns by value (or throws `HostCallError`) — there is no relay object and
// no out-pointer/status-code wire shape between the witness boundary and the
// state. The genuine wire-type converters this conformance leans on
// (`DisplayConfiguration(wireValue:)`, `WindowRect.wireValue`, …) live in
// `WireBridge.swift`.
extension NucleusCompositorServer: ServerHost {
    public func displayOutputForPoint(x: Double, y: Double) -> UInt64 {
        for display in layout.displays {
            if x >= display.logicalRect.x && x < display.logicalRect.maxX &&
                y >= display.logicalRect.y && y < display.logicalRect.maxY
            {
                return display.id
            }
        }
        return 0
    }

    public func cursorServerSetImage(imageHandle: UInt64, width: UInt32, height: UInt32) {
        cursor.imageHandle = imageHandle
        cursor.width = width
        cursor.height = height
    }

    public func cursorServerSetHotSpot(x: Int32, y: Int32) {
        cursor.hotSpotX = x
        cursor.hotSpotY = y
    }

    public func seatFocusGetSnapshot() throws(HostCallError) -> WireSeatFocusSnapshot {
        seatFocus.snapshot
    }

    public func serverReset() {
        reset()
    }

    public func displayAdd(id: UInt64, configuration: WireDisplayConfiguration) throws(HostCallError) {
        _ = layout.addDisplay(
            id: id,
            configuration: DisplayConfiguration(wireValue: configuration),
            logicalXSpecified: (configuration.reserved0 & 1) != 0 || configuration.logicalX != 0,
            logicalYSpecified: (configuration.reserved0 & 2) != 0 || configuration.logicalY != 0
        )
        spaces.ensureDisplay(id)
    }

    public func displayRemove(id: UInt64) throws(HostCallError) {
        let hasFallbackDisplay = layout.fallbackDisplayIDForRemoval(id) != nil
        inputControl?.displayWillRemove(hasFallbackDisplay: hasFallbackDisplay)
        _ = layout.removeDisplay(id: id)
        spaces.removeDisplay(id, layout: layout)
    }

    public func displayConfigure(id: UInt64, changes: WireDisplayConfigurationChanges) throws(HostCallError) {
        guard layout.configureDisplay(id: id, changes: DisplayConfigurationChanges(wireValue: changes)) else {
            throw .failed
        }
    }

    public func displayLayoutUpdate() throws(HostCallError) {
        _ = layout.desktopBounds()
    }

    public func displayPrimaryID() -> UInt64 {
        layout.primaryDisplayID() ?? 0
    }

    public func displayFallbackForRemoval(removedID: UInt64) -> UInt64 {
        layout.fallbackDisplayIDForRemoval(removedID) ?? 0
    }

    public func displayDesktopBounds() throws(HostCallError) -> WireLogicalRect {
        guard let bounds = layout.desktopBounds() else { throw .failed }
        return bounds
    }

    public func displayFind(id: UInt64) throws(HostCallError) -> WireLogicalRect {
        guard let display = layout.display(id: id) else { throw .failed }
        return display.logicalRect
    }

    public func displayFractionalScaleAt(x: Double, y: Double) -> Double {
        let outputID = displayOutputForPoint(x: x, y: y)
        if outputID != 0, let display = layout.display(id: outputID) {
            return display.fractionalScale
        }
        guard let primary = layout.primaryOutputID.flatMap({ layout.display(id: $0) }) ?? layout.displays.first else {
            return 1
        }
        return primary.fractionalScale
    }

    public func displayFractionalScaleForOutput(id: UInt64) -> Double {
        layout.display(id: id)?.fractionalScale ?? 0
    }

    public func displayUsableArea(id: UInt64) throws(HostCallError) -> WireUsableArea {
        guard let display = layout.display(id: id) else { throw .failed }
        return UsableArea(
            x: Int32(display.logicalRect.x),
            y: Int32(display.logicalRect.y),
            w: Int32(max(1, display.logicalRect.width)),
            h: Int32(max(1, display.logicalRect.height))
        )
    }

    public func windowCreate(source: WindowSource) throws(HostCallError) -> UInt64 {
        createWindow(source: source).id
    }

    public func windowDestroy(id: UInt64) throws(HostCallError) {
        guard destroyWindow(id: id) else { throw .failed }
    }

    public func windowSetGeometry(id: UInt64, rect: WireWindowRect) throws(HostCallError) {
        guard let window = window(id: id) else { throw .failed }
        window.setGeometry(WindowRect(wireValue: rect))
    }

    public func windowGetGeometry(id: UInt64) throws(HostCallError) -> WireWindowRect {
        guard let window = window(id: id) else { throw .failed }
        return window.currentRect().wireValue
    }

    public func windowGetRequestedMaximized(id: UInt64) -> Bool {
        window(id: id)?.requestedMaximized == true
    }

    public func windowGetRequestedFullscreen(id: UInt64) -> Bool {
        window(id: id)?.requestedFullscreen == true
    }

    public func windowGetActiveMaximized(id: UInt64) -> Bool {
        window(id: id)?.activeMaximized == true
    }

    public func windowGetActiveFullscreen(id: UInt64) -> Bool {
        window(id: id)?.activeFullscreen == true
    }

    public func windowGetManagedAppWindow(id: UInt64) -> Bool {
        window(id: id)?.managedAppWindow == true
    }

    public func windowGetWantsKeyboardFocus(id: UInt64) -> Bool {
        window(id: id)?.wantsKeyboardFocus == true
    }

    public func windowGetCurrentOutput(id: UInt64) -> UInt64 {
        window(id: id)?.currentOutputID ?? 0
    }

    public func windowGetLevel(id: UInt64) -> Int32 {
        window(id: id)?.level ?? 0
    }

    public func windowGetTileEdges(id: UInt64) throws(HostCallError) -> WireResizeEdges {
        guard let window = window(id: id) else { throw .failed }
        var edges = WireResizeEdges()
        edges.left = window.tileEdges.left
        edges.right = window.tileEdges.right
        edges.top = window.tileEdges.top
        edges.bottom = window.tileEdges.bottom
        return edges
    }

    public func windowAllocSlotGeneration(id: UInt64) -> UInt64 {
        guard let window = window(id: id) else { return 0 }
        return window.protocolState.allocateSlotGeneration()
    }

    public func windowSetMapped(id: UInt64, mapped: Bool) {
        guard let window = window(id: id) else { return }
        window.mapped = mapped
        // On map, bind the window to its output's active workspace so it appears on
        // the current workspace and stays there (per-output, niri-like). Layer-shell
        // surfaces are not workspace-scoped — they belong to the output itself.
        if mapped, window.isManagedAppWindow(), window.layerHost == nil, let outputID = window.currentOutputID {
            spaces.assignToActiveSpace(window: id, outputID: outputID)
        }
    }

    public func windowNoteSurfaceOutput(id: UInt64, outputID: UInt64) {
        guard let window = window(id: id) else { return }
        let output = outputID == 0 ? nil : outputID
        window.currentOutputID = output
        if output != nil && !window.activeFullscreen && !window.activeMaximized {
            window.preferredOutputID = output
        }
        // Now that the window's output is known, pin it to that output's active
        // workspace (idempotent; no-op until it is also mapped).
        assignWorkspaceIfReady(id: id)
    }

    public func windowClearRequestedSpecial(id: UInt64) {
        guard let window = window(id: id) else { return }
        window.requestedFullscreen = false
        window.requestedMaximized = false
        window.fullscreenTarget = .automatic
    }

    public func windowPendingConfigureCount(id: UInt64) -> UInt32 {
        UInt32(window(id: id)?.protocolState.pendingConfigures.count ?? 0)
    }

    public func windowListRaise(id: UInt64) -> Bool {
        windows.raise(id: id)
    }

    public func windowListBelow(id: UInt64, siblingID: UInt64) -> Bool {
        windows.place(id: id, below: siblingID)
    }

    public func windowListFocus(id: UInt64) -> Bool {
        windows.focus(id: id)
    }

    public func windowRenderOrderCount(frontToBack: Bool) -> UInt64 {
        let ids = frontToBack ? windows.frontToBackOrderedIDs() : windows.orderedIDs()
        return UInt64(ids.count)
    }

    /// Fill the caller-provided `OutputSpan` with the window render order in
    /// place, stopping when the span is full. The caller owns the result buffer (sized
    /// from `windowRenderOrderCount`) and Swift appends into it, so no heap
    /// `Array` crosses back with cross-language ARC.
    public func windowRenderOrderFill(frontToBack: Bool, into out: inout OutputSpan<WireWindowRenderOrderEntry>) {
        let ids = frontToBack ? windows.frontToBackOrderedIDs() : windows.orderedIDs()
        for id in ids {
            if out.freeCapacity == 0 { break }
            out.append(renderOrderEntry(forID: id))
        }
    }

    public func spacesActiveForDisplay(displayID: UInt64) -> UInt32 {
        spaces.activeSpace(forDisplay: displayID) ?? 0
    }

    public func spacesSetActive(displayID: UInt64, spaceID: UInt32) -> Bool {
        spaces.setActiveSpace(spaceID, forDisplay: displayID)
    }

    public func windowGetSpaceHidden(id: UInt64) -> Bool {
        spaces.isSpaceHidden(window: id)
    }

    public func spacesOverlayDisplayID() -> UInt64 {
        spaces.overlayDisplayID(layout: layout)
    }

    public func spacesCreate(outputID: UInt64) throws(HostCallError) -> UInt32 {
        spaces.createSpace(name: "Space", outputID: outputID)
    }

    public func spacesEnsureForOutput(outputID: UInt64, index: UInt32) -> UInt32 {
        spaces.ensureWorkspace(onOutput: outputID, index: Int(index))
    }

    public func spacesAppend(outputID: UInt64) -> UInt32 {
        spaces.appendWorkspace(onOutput: outputID)
    }

    public func spacesRemove(spaceID: UInt32) -> Bool {
        spaces.removeSpace(spaceID)
    }

    public func spacesAssignWindowToSpace(windowID: UInt64, spaceID: UInt32) -> Bool {
        spaces.assign(window: windowID, toSpace: spaceID)
    }

    public func windowCopyPolicySnapshot(windowID: UInt64) throws(HostCallError) -> WireWindowPolicySnapshot {
        guard let window = window(id: windowID) else { throw .failed }
        return windowPolicySnapshot(for: window)
    }

    public func spacesOutputLayoutSnapshot(
        outputID: UInt64,
        usable: WireUsableArea
    ) throws(HostCallError) -> WireOutputLayoutSnapshot {
        guard let output = layout.display(id: outputID) else { throw .failed }
        var snapshot = WireOutputLayoutSnapshot()
        snapshot.fullscreenRect = spaces.fullscreenLayoutRect(for: output).wireValue
        snapshot.maximizedRect = spaces.maximizedLayoutRect(for: output, usable: usable).wireValue
        snapshot.defaultRect = spaces.defaultWindowRect(for: output, usable: usable).wireValue
        return snapshot
    }

    public func eventServerDispatch(
        event: WireEventRecord,
        bounds: WirePointerBounds
    ) throws(HostCallError) -> WireEventDispatchDecision {
        events.dispatch(event, bounds: bounds)
    }

    public func eventServerResetInputState() {
        events.resetInputState()
    }

    public func eventServerSetFlags(flags: UInt64) {
        events.setFlags(flags)
    }

    public func eventServerSetCursor(x: Double, y: Double) {
        events.setCursor(x: x, y: y)
    }

    public func eventServerCursorX() -> Double { events.cursorX }
    public func eventServerCursorY() -> Double { events.cursorY }

    public func seatFocusSetPointer(surfaceID: UInt64) {
        seatFocus.setPointerFocus(surfaceID: surfaceID)
    }

    public func seatFocusClearPointer() {
        seatFocus.clearPointerFocus()
    }

    public func seatFocusSetKeyboard(surfaceID: UInt64) {
        seatFocus.setKeyboardFocus(surfaceID: surfaceID)
    }

    public func seatFocusClearKeyboard() {
        seatFocus.clearKeyboardFocus()
    }

    public func seatFocusRecordPointerButton(state: UInt32, serial: UInt32, focusedSurfaceID: UInt64) {
        seatFocus.recordPointerButton(state: state, serial: serial, focusedSurfaceID: focusedSurfaceID)
    }

    public func seatFocusResetPointerButtons() {
        seatFocus.resetPointerButtons()
    }

    public func seatFocusInvalidateSurface(surfaceID: UInt64) {
        seatFocus.invalidateSurface(id: surfaceID)
    }

    public func windowGetChromeInsets(id: UInt64) throws(HostCallError) -> WireChromeInsets {
        guard let window = window(id: id) else { throw .failed }
        return window.chromeInsets
    }

    public func windowChromeHit(id: UInt64, frameLocalX: Double, frameLocalY: Double, frameWidth: Double, frameHeight: Double) -> UInt64 {
        guard let window = window(id: id) else { return 0 }
        return window.frameView.classify(
            x: frameLocalX,
            y: frameLocalY,
            frameWidth: frameWidth,
            frameHeight: frameHeight
        ).packed
    }

    public func windowCapabilities(id: UInt64) -> UInt32 {
        guard let window = window(id: id) else { return 0 }
        return window.frameView.windowMenuCapabilities
    }
}

extension NucleusCompositorServer {
    /// Build the policy snapshot for a window from the live spaces/layout state.
    /// Shared by `windowCopyPolicySnapshot` and the per-entry render-order fill.
    fileprivate func windowPolicySnapshot(for window: Window) -> WireWindowPolicySnapshot {
        var snapshot = WireWindowPolicySnapshot()
        snapshot.policyOutputId = spaces.policyOutputID(for: window, layout: layout)
        snapshot.requestedFullscreenOutputId = spaces.resolveSpecialOutputID(
            for: window,
            layout: layout,
            nextActiveFullscreen: true,
            nextActiveMaximized: false
        ) ?? 0
        snapshot.requestedMaximizedOutputId = spaces.resolveSpecialOutputID(
            for: window,
            layout: layout,
            nextActiveFullscreen: false,
            nextActiveMaximized: true
        ) ?? 0
        snapshot.requestedSpecial = spaces.requestedSpecialMode(for: window)
        snapshot.activeMaximized = window.activeMaximized
        snapshot.activeFullscreen = window.activeFullscreen
        snapshot.managedAppWindow = window.isManagedAppWindow()
        snapshot.wantsKeyboardFocus = window.wantsKeyboardFocus
        return snapshot
    }

    fileprivate func renderOrderEntry(forID id: UInt64) -> WireWindowRenderOrderEntry {
        guard let window = window(id: id) else {
            return WireWindowRenderOrderEntry()
        }
        var entry = WireWindowRenderOrderEntry()
        entry.windowId = window.id
        entry.policy = windowPolicySnapshot(for: window)
        return entry
    }
}
