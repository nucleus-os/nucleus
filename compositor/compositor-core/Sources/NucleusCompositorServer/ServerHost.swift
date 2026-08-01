package import NucleusCompositorServerTypes
import NucleusTypes

/// Shared failure type for NucleusCompositorServer caller-boundary (`*Host`)
/// requirements that distinguish an invalid request from transient output
/// unavailability.
package enum HostCallError: Error, Equatable {
    case failed
    case noOutputs
}

@MainActor
package protocol ServerHost: AnyObject {
    func displayOutputForPoint(x: Double, y: Double) -> UInt64
    func cursorServerSetImage(imageHandle: UInt64, width: UInt32, height: UInt32)
    func cursorServerSetHotSpot(x: Int32, y: Int32)
    func seatFocusGetSnapshot() throws(HostCallError) -> WireSeatFocusSnapshot
    func serverReset()
    func displayAdd(id: UInt64, configuration: WireDisplayConfiguration) throws(HostCallError)
    func displayRemove(id: UInt64) throws(HostCallError)
    func displayConfigure(id: UInt64, changes: WireDisplayConfigurationChanges)
        throws(HostCallError)
    func displayLayoutUpdate() throws(HostCallError)
    func displayPrimaryID() throws(HostCallError) -> UInt64
    func displayFallbackForRemoval(removedID: UInt64) throws(HostCallError) -> UInt64
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
    func windowRenderOrderFill(
        frontToBack: Bool, into out: inout OutputSpan<WireWindowRenderOrderEntry>)
    func spacesActiveForDisplay(displayID: UInt64) -> UInt32
    func spacesSetActive(displayID: UInt64, spaceID: UInt32) -> Bool
    func spacesOverlayDisplayID() throws(HostCallError) -> UInt64
    func spacesCreate(outputID: UInt64) throws(HostCallError) -> UInt32
    func spacesEnsureForOutput(outputID: UInt64, index: UInt32) -> UInt32
    func spacesAppend(outputID: UInt64) -> UInt32
    func spacesRemove(spaceID: UInt32) -> Bool
    func spacesAssignWindowToSpace(windowID: UInt64, spaceID: UInt32) -> Bool
    func windowGetSpaceHidden(id: UInt64) -> Bool
    func windowCopyPolicySnapshot(windowID: UInt64) throws(HostCallError)
        -> WireWindowPolicySnapshot
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
    func windowChromeHit(
        id: UInt64, frameLocalX: Double, frameLocalY: Double, frameWidth: Double,
        frameHeight: Double
    ) -> UInt64
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
    package func displayOutputForPoint(x: Double, y: Double) -> UInt64 {
        for display in layout.displays {
            if x >= display.logicalRect.x && x < display.logicalRect.maxX
                && y >= display.logicalRect.y && y < display.logicalRect.maxY
            {
                return display.id
            }
        }
        return 0
    }

    package func cursorServerSetImage(imageHandle: UInt64, width: UInt32, height: UInt32) {
        cursor.imageHandle = imageHandle
        cursor.width = width
        cursor.height = height
    }

    package func cursorServerSetHotSpot(x: Int32, y: Int32) {
        cursor.hotSpotX = x
        cursor.hotSpotY = y
    }

    package func seatFocusGetSnapshot() throws(HostCallError) -> WireSeatFocusSnapshot {
        seatFocus.snapshot
    }

    package func serverReset() {
        reset()
    }

    package func displayAdd(id: UInt64, configuration: WireDisplayConfiguration)
        throws(HostCallError)
    {
        _ = layout.addDisplay(
            id: id,
            configuration: DisplayConfiguration(wireValue: configuration),
            logicalXSpecified: (configuration.reserved0 & 1) != 0 || configuration.logicalX != 0,
            logicalYSpecified: (configuration.reserved0 & 2) != 0 || configuration.logicalY != 0
        )
        spaces.ensureDisplay(id)
    }

    package func displayRemove(id: UInt64) throws(HostCallError) {
        guard !layout.displays.isEmpty else { throw .noOutputs }
        guard layout.display(id: id) != nil else { throw .failed }
        let hasFallbackDisplay = layout.fallbackDisplayIDForRemoval(id) != nil
        inputControl?.displayWillRemove(hasFallbackDisplay: hasFallbackDisplay)
        _ = layout.removeDisplay(id: id)
        spaces.removeDisplay(id, layout: layout)
    }

    package func displayConfigure(id: UInt64, changes: WireDisplayConfigurationChanges)
        throws(HostCallError)
    {
        guard !layout.displays.isEmpty else { throw .noOutputs }
        guard
            layout.configureDisplay(
                id: id, changes: DisplayConfigurationChanges(wireValue: changes))
        else {
            throw .failed
        }
    }

    package func displayLayoutUpdate() throws(HostCallError) {
        guard layout.desktopBounds() != nil else { throw .noOutputs }
    }

    package func displayPrimaryID() throws(HostCallError) -> UInt64 {
        guard let outputID = layout.primaryDisplayID()
        else { throw .noOutputs }
        return outputID
    }

    package func displayFallbackForRemoval(
        removedID: UInt64
    ) throws(HostCallError) -> UInt64 {
        guard !layout.displays.isEmpty else { throw .noOutputs }
        guard let outputID = layout.fallbackDisplayIDForRemoval(removedID)
        else { throw .failed }
        return outputID
    }

    package func displayDesktopBounds() throws(HostCallError) -> WireLogicalRect {
        guard let bounds = layout.desktopBounds() else { throw .noOutputs }
        return bounds
    }

    package func displayFind(id: UInt64) throws(HostCallError) -> WireLogicalRect {
        guard !layout.displays.isEmpty else { throw .noOutputs }
        guard let display = layout.display(id: id) else { throw .failed }
        return display.logicalRect
    }

    package func displayFractionalScaleAt(x: Double, y: Double) -> Double {
        let outputID = displayOutputForPoint(x: x, y: y)
        if outputID != 0, let display = layout.display(id: outputID) {
            return display.fractionalScale
        }
        guard
            let primary = layout.primaryOutputID.flatMap({ layout.display(id: $0) })
                ?? layout.displays.first
        else {
            return 1
        }
        return primary.fractionalScale
    }

    package func displayFractionalScaleForOutput(id: UInt64) -> Double {
        layout.display(id: id)?.fractionalScale ?? 0
    }

    package func displayUsableArea(id: UInt64) throws(HostCallError) -> WireUsableArea {
        guard !layout.displays.isEmpty else { throw .noOutputs }
        guard let display = layout.display(id: id) else { throw .failed }
        return UsableArea(
            x: Int32(display.logicalRect.x),
            y: Int32(display.logicalRect.y),
            w: Int32(max(1, display.logicalRect.width)),
            h: Int32(max(1, display.logicalRect.height))
        )
    }

    package func windowCreate(source: WindowSource) throws(HostCallError) -> UInt64 {
        createWindow(source: source).id
    }

    package func windowDestroy(id: UInt64) throws(HostCallError) {
        guard destroyWindow(id: id) else { throw .failed }
    }

    package func windowSetGeometry(id: UInt64, rect: WireWindowRect) throws(HostCallError) {
        guard let window = window(id: id) else { throw .failed }
        window.setGeometry(WindowRect(wireValue: rect))
    }

    package func windowGetGeometry(id: UInt64) throws(HostCallError) -> WireWindowRect {
        guard let window = window(id: id) else { throw .failed }
        return window.currentRect().wireValue
    }

    package func windowGetRequestedMaximized(id: UInt64) -> Bool {
        window(id: id)?.requestedMaximized == true
    }

    package func windowGetRequestedFullscreen(id: UInt64) -> Bool {
        window(id: id)?.requestedFullscreen == true
    }

    package func windowGetActiveMaximized(id: UInt64) -> Bool {
        window(id: id)?.activeMaximized == true
    }

    package func windowGetActiveFullscreen(id: UInt64) -> Bool {
        window(id: id)?.activeFullscreen == true
    }

    package func windowGetManagedAppWindow(id: UInt64) -> Bool {
        window(id: id)?.managedAppWindow == true
    }

    package func windowGetWantsKeyboardFocus(id: UInt64) -> Bool {
        window(id: id)?.wantsKeyboardFocus == true
    }

    package func windowGetCurrentOutput(id: UInt64) -> UInt64 {
        window(id: id)?.currentOutputID ?? 0
    }

    package func windowGetLevel(id: UInt64) -> Int32 {
        window(id: id)?.level ?? 0
    }

    package func windowGetTileEdges(id: UInt64) throws(HostCallError) -> WireResizeEdges {
        guard let window = window(id: id) else { throw .failed }
        var edges = WireResizeEdges()
        edges.left = window.tileEdges.left
        edges.right = window.tileEdges.right
        edges.top = window.tileEdges.top
        edges.bottom = window.tileEdges.bottom
        return edges
    }

    package func windowAllocSlotGeneration(id: UInt64) -> UInt64 {
        guard let window = window(id: id) else { return 0 }
        return window.protocolState.allocateSlotGeneration()
    }

    package func windowSetMapped(id: UInt64, mapped: Bool) {
        guard let window = window(id: id) else { return }
        window.mapped = mapped
        // On map, bind the window to its output's active workspace so it appears on
        // the current workspace and stays there (per-output, niri-like). Layer-shell
        // surfaces are not workspace-scoped — they belong to the output itself.
        if mapped, window.isManagedAppWindow(), window.layerHost == nil,
            let outputID = window.currentOutputID
        {
            spaces.assignToActiveSpace(window: id, outputID: outputID)
        }
    }

    package func windowNoteSurfaceOutput(id: UInt64, outputID: UInt64) {
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

    package func windowClearRequestedSpecial(id: UInt64) {
        guard let window = window(id: id) else { return }
        window.requestedFullscreen = false
        window.requestedMaximized = false
        window.fullscreenTarget = .automatic
    }

    package func windowPendingConfigureCount(id: UInt64) -> UInt32 {
        UInt32(window(id: id)?.protocolState.pendingConfigures.count ?? 0)
    }

    package func windowListRaise(id: UInt64) -> Bool {
        windows.raise(id: id)
    }

    package func windowListBelow(id: UInt64, siblingID: UInt64) -> Bool {
        windows.place(id: id, below: siblingID)
    }

    package func windowListFocus(id: UInt64) -> Bool {
        windows.focus(id: id)
    }

    package func windowRenderOrderCount(frontToBack: Bool) -> UInt64 {
        let ids = frontToBack ? windows.frontToBackOrderedIDs() : windows.orderedIDs()
        return UInt64(ids.count)
    }

    /// Fill the caller-provided `OutputSpan` with the window render order in
    /// place, stopping when the span is full. The caller owns the result buffer (sized
    /// from `windowRenderOrderCount`) and Swift appends into it, so no heap
    /// `Array` crosses back with cross-language ARC.
    package func windowRenderOrderFill(
        frontToBack: Bool, into out: inout OutputSpan<WireWindowRenderOrderEntry>
    ) {
        let ids = frontToBack ? windows.frontToBackOrderedIDs() : windows.orderedIDs()
        for id in ids {
            if out.freeCapacity == 0 { break }
            out.append(renderOrderEntry(forID: id))
        }
    }

    package func spacesActiveForDisplay(displayID: UInt64) -> UInt32 {
        spaces.activeSpace(forDisplay: displayID) ?? 0
    }

    package func spacesSetActive(displayID: UInt64, spaceID: UInt32) -> Bool {
        spaces.setActiveSpace(spaceID, forDisplay: displayID)
    }

    package func windowGetSpaceHidden(id: UInt64) -> Bool {
        spaces.isSpaceHidden(window: id)
    }

    package func spacesOverlayDisplayID() throws(HostCallError) -> UInt64 {
        guard let outputID = spaces.overlayDisplayID(layout: layout)
        else { throw .noOutputs }
        return outputID
    }

    package func spacesCreate(outputID: UInt64) throws(HostCallError) -> UInt32 {
        guard !layout.displays.isEmpty else { throw .noOutputs }
        guard layout.display(id: outputID) != nil else { throw .failed }
        return spaces.createSpace(name: "Space", outputID: outputID)
    }

    package func spacesEnsureForOutput(outputID: UInt64, index: UInt32) -> UInt32 {
        spaces.ensureWorkspace(onOutput: outputID, index: Int(index))
    }

    package func spacesAppend(outputID: UInt64) -> UInt32 {
        spaces.appendWorkspace(onOutput: outputID)
    }

    package func spacesRemove(spaceID: UInt32) -> Bool {
        spaces.removeSpace(spaceID)
    }

    package func spacesAssignWindowToSpace(windowID: UInt64, spaceID: UInt32) -> Bool {
        spaces.assign(window: windowID, toSpace: spaceID)
    }

    package func windowCopyPolicySnapshot(windowID: UInt64) throws(HostCallError)
        -> WireWindowPolicySnapshot
    {
        guard !layout.displays.isEmpty else { throw .noOutputs }
        guard let window = window(id: windowID) else { throw .failed }
        return windowPolicySnapshot(for: window)
    }

    package func spacesOutputLayoutSnapshot(
        outputID: UInt64,
        usable: WireUsableArea
    ) throws(HostCallError) -> WireOutputLayoutSnapshot {
        guard !layout.displays.isEmpty else { throw .noOutputs }
        guard let output = layout.display(id: outputID) else { throw .failed }
        var snapshot = WireOutputLayoutSnapshot()
        snapshot.fullscreenRect = spaces.fullscreenLayoutRect(for: output).wireValue
        snapshot.maximizedRect = spaces.maximizedLayoutRect(for: output, usable: usable).wireValue
        snapshot.defaultRect = spaces.defaultWindowRect(for: output, usable: usable).wireValue
        return snapshot
    }

    package func eventServerDispatch(
        event: WireEventRecord,
        bounds: WirePointerBounds
    ) throws(HostCallError) -> WireEventDispatchDecision {
        events.dispatch(event, bounds: bounds)
    }

    package func eventServerResetInputState() {
        events.resetInputState()
    }

    package func eventServerSetFlags(flags: UInt64) {
        events.setFlags(flags)
    }

    package func eventServerSetCursor(x: Double, y: Double) {
        events.setCursor(x: x, y: y)
    }

    package func eventServerCursorX() -> Double { events.cursorX }
    package func eventServerCursorY() -> Double { events.cursorY }

    package func seatFocusSetPointer(surfaceID: UInt64) {
        seatFocus.setPointerFocus(surfaceID: surfaceID)
    }

    package func seatFocusClearPointer() {
        seatFocus.clearPointerFocus()
    }

    package func seatFocusSetKeyboard(surfaceID: UInt64) {
        seatFocus.setKeyboardFocus(surfaceID: surfaceID)
    }

    package func seatFocusClearKeyboard() {
        seatFocus.clearKeyboardFocus()
    }

    package func seatFocusRecordPointerButton(
        state: UInt32, serial: UInt32, focusedSurfaceID: UInt64
    ) {
        seatFocus.recordPointerButton(
            state: state, serial: serial, focusedSurfaceID: focusedSurfaceID)
    }

    package func seatFocusResetPointerButtons() {
        seatFocus.resetPointerButtons()
    }

    package func seatFocusInvalidateSurface(surfaceID: UInt64) {
        seatFocus.invalidateSurface(id: surfaceID)
    }

    package func windowGetChromeInsets(id: UInt64) throws(HostCallError) -> WireChromeInsets {
        guard let window = window(id: id) else { throw .failed }
        return window.chromeInsets
    }

    package func windowChromeHit(
        id: UInt64, frameLocalX: Double, frameLocalY: Double, frameWidth: Double,
        frameHeight: Double
    ) -> UInt64 {
        guard let window = window(id: id) else { return 0 }
        return window.frameView.classify(
            x: frameLocalX,
            y: frameLocalY,
            frameWidth: frameWidth,
            frameHeight: frameHeight
        ).packed
    }

    package func windowCapabilities(id: UInt64) -> UInt32 {
        guard let window = window(id: id) else { return 0 }
        return window.frameView.windowMenuCapabilities
    }
}

extension NucleusCompositorServer {
    /// Build the policy snapshot for a window from the live spaces/layout state.
    /// Shared by `windowCopyPolicySnapshot` and the per-entry render-order fill.
    fileprivate func windowPolicySnapshot(for window: Window) -> WireWindowPolicySnapshot {
        var snapshot = WireWindowPolicySnapshot()
        snapshot.policyOutputId =
            spaces.policyOutputID(for: window, layout: layout) ?? 0
        snapshot.requestedFullscreenOutputId =
            spaces.resolveSpecialOutputID(
                for: window,
                layout: layout,
                nextActiveFullscreen: true,
                nextActiveMaximized: false
            ) ?? 0
        snapshot.requestedMaximizedOutputId =
            spaces.resolveSpecialOutputID(
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
