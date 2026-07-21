import NucleusCompositorServerTypes
@_spi(NucleusCompositor) import NucleusLayers

/// A change to the observable desktop model — the typed stream the external-shell
/// management protocols (and any other consumer) project. Identity is by id;
/// `windowChanged` is coarse (some projected-relevant property changed) and the
/// observer re-reads the current `Window`, which is idempotent on the wire.
/// Observers must tolerate a change for an id they do not know.
public enum DesktopChange: Sendable, Equatable {
    case windowAdded(WindowID)
    case windowRemoved(WindowID)
    case windowChanged(WindowID)
    case focusChanged(WindowID?)
    case spaceAdded(SpaceID)
    case spaceRemoved(SpaceID)
    case spaceChanged(SpaceID)
    case spaceActivated(output: DisplayID, space: SpaceID)
    case windowSpaceChanged(window: WindowID, space: SpaceID?)
}

@MainActor
public protocol DesktopModelObserver: AnyObject {
    /// One coalesced batch per per-iteration drain. On registration the observer
    /// is replayed the current model state as synthetic `*Added`/`focusChanged`
    /// changes through this same method, so it has a single apply path.
    func desktopModelDidChange(_ changes: [DesktopChange])
}

@MainActor
public final class Connection {
    public let id: UInt64
    public var contextID: ContextID?

    public init(id: UInt64, contextID: ContextID? = nil) {
        self.id = id
        self.contextID = contextID
    }
}

@MainActor
public final class EventServer {
    private struct PointerBounds {
        var minX: Double
        var minY: Double
        var maxX: Double
        var maxY: Double

        init(wireValue c: WirePointerBounds) {
            minX = c.minX
            minY = c.minY
            maxX = c.maxX
            maxY = c.maxY
        }

        func clamped(x: Double, y: Double) -> (Double, Double) {
            (max(minX, min(x, maxX)), max(minY, min(y, maxY)))
        }
    }

    private struct StreamState {
        var cursorX: Double = 0
        var cursorY: Double = 0
        var flags: UInt64 = 0
        var leftButtonDown: Bool = false
        var rightButtonDown: Bool = false
        var otherButtonCount: UInt8 = 0

        var snapshot: WireEventStateSnapshot {
            var s = WireEventStateSnapshot()
            s.cursorX = cursorX
            s.cursorY = cursorY
            s.flags = flags
            s.leftButtonDown = leftButtonDown
            s.rightButtonDown = rightButtonDown
            s.otherButtonCount = otherButtonCount
            s.reserved0 = 0
            return s
        }

        mutating func resetInput() {
            flags = 0
            leftButtonDown = false
            rightButtonDown = false
            otherButtonCount = 0
        }

        mutating func apply(_ event: inout WireEventRecord, bounds: PointerBounds) -> WireEventStateChange {
            var change = WireEventStateChange()
            switch event.kind {
            case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
                let oldX = cursorX
                let oldY = cursorY
                let clamped = bounds.clamped(x: event.x, y: event.y)
                event.x = clamped.0
                event.y = clamped.1
                cursorX = clamped.0
                cursorY = clamped.1
                change.cursorMoved = (oldX != cursorX || oldY != cursorY)
            case .leftMouseDown, .rightMouseDown, .otherMouseDown,
                 .leftMouseUp, .rightMouseUp, .otherMouseUp:
                applyButton(button: UInt32(truncatingIfNeeded: event.data0), down: isButtonDown(event.kind))
                event.x = cursorX
                event.y = cursorY
                change.buttonChanged = true
            case .flagsChanged, .keyDown, .keyUp:
                flags = event.flags
                change.flagsChanged = true
            default:
                break
            }
            return change
        }

        private mutating func applyButton(button: UInt32, down: Bool) {
            switch button {
            case 272:
                leftButtonDown = down
            case 273:
                rightButtonDown = down
            default:
                if down {
                    if otherButtonCount < UInt8.max { otherButtonCount += 1 }
                } else if otherButtonCount > 0 {
                    otherButtonCount -= 1
                }
            }
        }

        private func isButtonDown(_ kind: WireEventKind) -> Bool {
            kind == .leftMouseDown || kind == .rightMouseDown || kind == .otherMouseDown
        }
    }

    private var state = StreamState()

    public init() {}

    public func dispatch(_ event: WireEventRecord, bounds: WirePointerBounds) -> WireEventDispatchDecision {
        var accepted = event
        let pointerBounds = PointerBounds(wireValue: bounds)

        let change = state.apply(&accepted, bounds: pointerBounds)

        var decision = WireEventDispatchDecision()
        decision.action = .route
        decision.dispatchValue = 0
        decision.event = accepted
        decision.state = state.snapshot
        decision.change = change
        return decision
    }

    public func resetInputState() {
        state.resetInput()
    }

    public func setFlags(_ flags: UInt64) {
        state.flags = flags
    }

    public func setCursor(x: Double, y: Double) {
        state.cursorX = x
        state.cursorY = y
    }

    /// The accepted cursor position (the hardware cursor-plane path reads this).
    public var cursorX: Double { state.cursorX }
    public var cursorY: Double { state.cursorY }

    public func reset() {
        state = StreamState()
    }
}

@MainActor
public final class CursorServer {
    public var imageHandle: UInt64 = 0
    public var hotSpotX: Int32 = 0
    public var hotSpotY: Int32 = 0
    public var width: UInt32 = 0
    public var height: UInt32 = 0

    /// The current cursor's ARGB8888 pixels (tightly packed, `width * height * 4`
    /// bytes, row stride `width * 4`), retained so the hardware cursor-plane path can
    /// upload them. Empty until a cursor image is applied.
    public private(set) var pixels: [UInt8] = []
    /// Bumps on every image change. The cursor-plane feed re-uploads the KMS cursor BO
    /// only when this changes, so per-frame position updates cost no re-upload.
    public private(set) var generation: UInt64 = 0

    /// The theme name of the current cursor, or nil when it is a client-provided image
    /// (`wl_pointer.set_cursor`) or hidden. The theme path (`cursorApplyNamed`) dedupes
    /// against this to skip redundant reloads; a client image clears it so a following
    /// theme apply is not skipped.
    public private(set) var themeName: String?

    public init() {}

    /// Replace the current cursor with a client-provided image (`set_cursor`), retaining
    /// its pixels + hotspot and clearing the theme-name marker. `pixels` is
    /// tightly-packed ARGB8888 (`width * height * 4`).
    public func setImage(
        pixels: [UInt8], width: UInt32, height: UInt32, hotSpotX: Int32, hotSpotY: Int32
    ) {
        self.pixels = pixels
        self.width = width
        self.height = height
        self.hotSpotX = hotSpotX
        self.hotSpotY = hotSpotY
        self.imageHandle = 0
        self.themeName = nil
        generation &+= 1
    }

    /// Apply a named theme cursor's image, tagging it with `name` so a repeat apply of
    /// the same name is a no-op for the caller to skip.
    public func applyTheme(
        name: String, pixels: [UInt8], width: UInt32, height: UInt32, hotSpotX: Int32, hotSpotY: Int32
    ) {
        setImage(pixels: pixels, width: width, height: height, hotSpotX: hotSpotX, hotSpotY: hotSpotY)
        self.themeName = name
    }

    /// Hide the cursor (client passed a nil surface to `set_cursor`): an empty image the
    /// cursor plane renders as fully transparent.
    public func hide() {
        setImage(pixels: [], width: 0, height: 0, hotSpotX: 0, hotSpotY: 0)
    }

    public func reset() {
        imageHandle = 0
        hotSpotX = 0
        hotSpotY = 0
        width = 0
        height = 0
        pixels = []
        themeName = nil
        generation &+= 1
    }
}

@MainActor
public final class SeatFocus {
    public private(set) var pointerSurfaceID: UInt64 = 0
    public private(set) var keyboardSurfaceID: UInt64 = 0
    public private(set) var buttonCount: UInt32 = 0
    public private(set) var lastPointerButtonSerial: UInt32 = 0
    public private(set) var lastPointerButtonSurfaceID: UInt64 = 0

    public init() {}

    public func setPointerFocus(surfaceID: UInt64) {
        pointerSurfaceID = surfaceID
    }

    public func clearPointerFocus() {
        pointerSurfaceID = 0
    }

    public func setKeyboardFocus(surfaceID: UInt64) {
        keyboardSurfaceID = surfaceID
    }

    public func clearKeyboardFocus() {
        keyboardSurfaceID = 0
    }

    public func recordPointerButton(state: UInt32, serial: UInt32, focusedSurfaceID: UInt64) {
        if state == 1 {
            buttonCount &+= 1
        } else if buttonCount > 0 {
            buttonCount -= 1
        }
        if state == 1 && serial != 0 {
            lastPointerButtonSerial = serial
            lastPointerButtonSurfaceID = focusedSurfaceID
        }
    }

    public func resetPointerButtons() {
        buttonCount = 0
        lastPointerButtonSerial = 0
        lastPointerButtonSurfaceID = 0
    }

    public func invalidateSurface(id: UInt64) {
        if pointerSurfaceID == id { pointerSurfaceID = 0 }
        if keyboardSurfaceID == id { keyboardSurfaceID = 0 }
        if lastPointerButtonSurfaceID == id { resetPointerButtons() }
    }

    public var snapshot: WireSeatFocusSnapshot {
        var snapshot = WireSeatFocusSnapshot()
        snapshot.pointerSurfaceId = pointerSurfaceID
        snapshot.keyboardSurfaceId = keyboardSurfaceID
        snapshot.buttonCount = buttonCount
        snapshot.lastPointerButtonSerial = lastPointerButtonSerial
        snapshot.lastPointerButtonSurfaceId = lastPointerButtonSurfaceID
        return snapshot
    }

    public func reset() {
        pointerSurfaceID = 0
        keyboardSurfaceID = 0
        resetPointerButtons()
    }
}

@MainActor
public final class DisplayServer {
    public let layout: DesktopLayout

    public init(layout: DesktopLayout) {
        self.layout = layout
    }
}

public struct LayerGeometry: Sendable, Equatable {
    public var layerID: UInt64
    public var rect: RenderRect
}

@MainActor
public final class Composition {
    public private(set) var rootLayerID: UInt64 = 0
    public private(set) var shellOverlayHostLayerID: UInt64 = 0
    private var nextLayerID: UInt64 = 1

    public init() {}

    public func allocLayerID() -> UInt64 {
        let id = nextLayerID
        nextLayerID &+= 1
        if nextLayerID == 0 { nextLayerID = 1 }
        return id
    }

    public func ensureRoots() {
        if rootLayerID == 0 { rootLayerID = allocLayerID() }
        if shellOverlayHostLayerID == 0 { shellOverlayHostLayerID = allocLayerID() }
    }

    public func reset() {
        rootLayerID = 0
        shellOverlayHostLayerID = 0
        nextLayerID = 1
    }
}

/// The compositor-owned result of a keybind dispatch, decoupled from the shell's
/// wire `KeybindDecision` so the seam protocol carries no `.shell`/overlay-ABI
/// types into the `.server` layer. `kind`: pass/consume/deferred; `action`/`value`
/// follow the shell keybind-action table (the compositor executes compositor-owned
/// actions, the shell executes its own through the seam's other methods).
public struct KeybindOutcome: Sendable {
    public enum Kind: UInt8, Sendable { case pass = 0, consume = 1, deferred = 2 }
    public var kind: Kind
    public var action: UInt8
    public var value: UInt32
    public init(kind: Kind, action: UInt8, value: UInt32) {
        self.kind = kind
        self.action = action
        self.value = value
    }
}

/// The seam the compositor input dispatch uses to reach the Swift shell policy
/// services that live in the `.shell` layer above it. The import-audit area DAG
/// forbids the compositor from importing `NucleusCompositorShell`/`NucleusCompositorOverlay` directly,
/// so the dependency is inverted: this protocol is defined here in `.server`, the
/// shell conforms to it, and injects the instance into `NucleusCompositorServer.shared` at
/// startup. The dispatch calls through `NucleusCompositorServer.shared.shellPolicy`.
@MainActor
public protocol CompositorShellPolicy: AnyObject {
    /// Session keybind policy (Super-prefixed combos, the launcher table, hotkey
    /// overlay toggles, the reserved-modifier rule).
    func dispatchKeybind(keycode: UInt32, modifiers: UInt64, pressed: Bool) -> KeybindOutcome

    // Cursor + shell/overlay reach-up the input dispatch makes during routing. The
    // owners live in `.shell` (`NucleusCompositorShell` cursor/bezel services and
    // `NucleusCompositorOverlayScene`); the dispatch reaches them through this seam instead of
    // importing those modules (the area DAG forbids `.nucleus_compositor_substrate → .shell`).
    func cursorApplyDefault()
    func cursorApplyNamed(_ name: String)
    func toggleHotkey()
    func dismissHotkey()
    func overlayActive() -> Bool
    func overlaySceneMenuVisible() -> Bool
    /// Whether the overlay wants keyboard input routed to it — an open menu, or
    /// a focused text field in the overlay's own scene.
    func overlaySceneWantsKeyboard() -> Bool
    func overlayPointer(x: Float, y: Float, kind: UInt32, button: UInt32, timestampNs: UInt64) -> UInt64
    func overlayKey(keycode: UInt32, modifiers: UInt32, text: String?, kind: UInt32, timestampNs: UInt64) -> UInt64
    func overlaySceneShowWindowMenu(windowID: UInt64, x: Double, y: Double, capabilities: UInt32)
}

/// The compositor session-control seam: the input host (`.nucleus_compositor_substrate`)
/// reaches the composition root's session lifecycle (`.nucleus_compositor_runtime`) — VT
/// switch resume/pause and process-exit — without importing it (the area DAG
/// forbids substrate → runtime). The runtime conforms + installs the instance.
@MainActor
public protocol CompositorSessionControl: AnyObject {
    func sessionResume() -> Bool
    /// Begin VT deactivation. Returns true when DRM state is already retired and
    /// libseat may be acknowledged before the callback returns. False defers the
    /// acknowledgement until the composition root completes the transition.
    func sessionPause() -> Bool
    func requestExit()
}

/// Input-side hooks the display model needs during output lifetime changes. The
/// implementation lives with the Swift input dispatcher; the server only knows
/// the policy-level fact that an output is leaving.
@MainActor
public protocol CompositorInputControl: AnyObject {
    func displayWillRemove(hasFallbackDisplay: Bool)
    /// Run a window-menu verb (close/minimize/maximize/fullscreen/move/resize) the
    /// overlay reported back to the shell, against the router window model. The shell
    /// (`.shell`) reaches the input dispatch (`.nucleus_compositor_substrate`) through this seam
    /// since the build stage forbids the reverse import.
    func windowMenuSelected(windowID: UInt64, verb: Int32)

    /// The evdev keycodes currently held down, so the seat can report correct key
    /// state in wl_keyboard.enter when a surface gains focus mid-press.
    func currentPressedEvdevKeys() -> [UInt32]
}

@MainActor
public final class NucleusCompositorServer {
    public static let shared = NucleusCompositorServer()

    /// The shell-policy seam, injected by the shell layer at startup (nil until
    /// then; the dispatch treats a nil seam as "no compositor keybind matched").
    public weak var shellPolicy: CompositorShellPolicy?
    public weak var inputControl: CompositorInputControl?
    /// The composition root's session lifecycle, injected at bring-up (the input
    /// host's VT enable/disable + exit reach it through here).
    public weak var sessionControl: CompositorSessionControl?
    /// The render service installed after successful GPU bring-up and cleared
    /// before teardown. The weak reference does not extend renderer lifetime.
    public weak var renderService: (any CompositorRenderService)?

    public let layout = DesktopLayout()
    public let windows = WindowList()
    public let spaces = Spaces()
    public let composition = Composition()
    public let events = EventServer()
    public let cursor = CursorServer()
    public let seatFocus = SeatFocus()
    public lazy var displayServer = DisplayServer(layout: layout)

    private var nextWindowID: WindowID = 1

    // MARK: Observation

    private struct WeakObserver { weak var value: DesktopModelObserver? }
    private var observers: [WeakObserver] = []
    private var pendingChanges: [DesktopChange] = []

    public init() {
        windows.onChange = { [weak self] change in self?.recordChange(change) }
        spaces.onChange = { [weak self] change in
            // A workspace state change (assignment / active-space switch) can hide or
            // reveal windows, so refresh the per-window spaceHidden mirror the scene +
            // input read before recording the change for observers.
            self?.refreshSpaceHiddenMirror()
            self?.recordChange(change)
        }
    }

    /// Pin a mapped managed app window to its output's active workspace once both its
    /// mapped state and output membership are known (either arrives first — this is
    /// called from `windowNoteSurfaceOutput` after the output resolves). No-op for
    /// layer-shell / unmapped / outputless windows; `assignToActiveSpace` self-guards
    /// a deliberate same-output assignment, so re-calls are idempotent.
    public func assignWorkspaceIfReady(id: WindowID) {
        guard let window = windows.window(id: id), window.mapped, window.isManagedAppWindow(),
              window.layerHost == nil, let outputID = window.currentOutputID else { return }
        spaces.assignToActiveSpace(window: id, outputID: outputID)
    }

    /// Mirror the authoritative `Spaces.isSpaceHidden` onto each window's cached
    /// `spaceHidden` (read by `visibleInScene`/`eligibleForInput`). Without this the
    /// field stays permanently false and windows are never hidden by workspace.
    private func refreshSpaceHiddenMirror() {
        for window in windows.windows {
            window.spaceHidden = spaces.isSpaceHidden(window: window.id)
        }
    }

    /// Record a model change for the next per-iteration drain. No-op when nothing
    /// observes — a freshly registered observer is replayed the full snapshot, so
    /// changes from before its registration are irrelevant to it.
    public func recordChange(_ change: DesktopChange) {
        guard !observers.isEmpty else { return }
        pendingChanges.append(change)
    }

    public func addObserver(_ observer: DesktopModelObserver) {
        observers.removeAll { $0.value == nil || $0.value === observer }
        observers.append(WeakObserver(value: observer))
        observer.desktopModelDidChange(snapshotChanges())
    }

    public func removeObserver(_ observer: DesktopModelObserver) {
        observers.removeAll { $0.value == nil || $0.value === observer }
    }

    /// Dispatch the coalesced pending changes to every observer. Called once per
    /// event-loop iteration, after dispatch settles and before the client flush.
    public func drainChanges() {
        observers.removeAll { $0.value == nil }
        guard !pendingChanges.isEmpty else { return }
        let batch = Self.coalesce(pendingChanges)
        pendingChanges.removeAll(keepingCapacity: true)
        for observer in observers { observer.value?.desktopModelDidChange(batch) }
    }

    /// The current model state as synthetic `*Added`/`focusChanged` changes, so a
    /// newly registered observer reconciles through the same apply path the live
    /// stream uses.
    private func snapshotChanges() -> [DesktopChange] {
        var changes: [DesktopChange] = []
        for space in spaces.spaces { changes.append(.spaceAdded(space.id)) }
        for window in windows.windows { changes.append(.windowAdded(window.id)) }
        if let focused = windows.focusedWindow { changes.append(.focusChanged(focused.id)) }
        return changes
    }

    /// Collapse repeated `windowChanged(id)` within a batch to one — the common
    /// title+app-id+state burst in a single iteration — leaving lifecycle/focus
    /// events in order. Observers tolerate a change for an unknown id, so add/remove
    /// races within a batch need no further collapsing.
    private static func coalesce(_ changes: [DesktopChange]) -> [DesktopChange] {
        var seenChanged: Set<WindowID> = []
        var result: [DesktopChange] = []
        result.reserveCapacity(changes.count)
        for change in changes {
            if case let .windowChanged(id) = change, !seenChanged.insert(id).inserted {
                continue
            }
            result.append(change)
        }
        return result
    }

    @discardableResult
    public func createWindow(source: WindowSource, id requestedID: WindowID = 0) -> Window {
        let id = requestedID == 0 ? nextWindowID : requestedID
        nextWindowID = max(nextWindowID, id + 1)
        if let existing = windows.window(id: id) { return existing }
        let window = Window(id: id, source: source)
        window.changeRecorder = { [weak self] change in self?.recordChange(change) }
        // Windows start borderless; server chrome is applied only once a client
        // negotiates it through xdg-decoration (DecorationPolicy forces server-side
        // for any client that binds the protocol). A client that never binds it
        // (e.g. a GTK app that always draws its own client-side titlebar) is left
        // undecorated so the compositor does not double-decorate it. xwayland and
        // layer-shell surfaces likewise stay borderless.
        windows.add(window)
        return window
    }

    @discardableResult
    public func destroyWindow(id: WindowID) -> Bool {
        guard let window = windows.remove(id: id) else { return false }
        window.changeRecorder = nil
        return true
    }

    public func window(id: WindowID) -> Window? {
        windows.window(id: id)
    }

    public func reset() {
        for window in windows.windows { window.changeRecorder = nil }
        windows.reset()
        nextWindowID = 1
        while let display = layout.displays.first {
            _ = layout.removeDisplay(id: display.id)
        }
        spaces.reset()
        events.reset()
        cursor.reset()
        seatFocus.reset()
        composition.reset()
        pendingChanges.removeAll(keepingCapacity: true)
        observers.removeAll()
    }
}

// MARK: - Fullscreen occlusion (the authoritative predicate the renderer, input
// dispatch, and scanout planning query).

extension NucleusCompositorServer {
    /// The front-most managed, fullscreen, visible window whose policy output is
    /// `output`, or nil.
    public func fullscreenOwner(onOutput output: DisplayID) -> Window? {
        for window in windows.windowsFrontToBack {
            guard window.isManagedAppWindow(), window.activeFullscreen,
                  window.mapped, !window.minimized,
                  spaces.policyOutputID(for: window, layout: layout) == output
            else { continue }
            return window
        }
        return nil
    }

    /// Whether `window` is fully occluded by its output's fullscreen owner: the
    /// cross-level rule decides, with same-level cases tie-broken by back-to-front
    /// z-order (a window behind the owner is occluded).
    public func isOccludedByFullscreen(_ window: Window) -> Bool {
        let output = spaces.policyOutputID(for: window, layout: layout)
        return isOccludedByFullscreen(window, owner: fullscreenOwner(onOutput: output))
    }

    /// The occlusion decision against an already-resolved output fullscreen `owner`
    /// (nil = none). Lets a caller that tests many windows resolve owners once (see
    /// `fullscreenOccludedWindowIDs`) instead of rescanning per window.
    public func isOccludedByFullscreen(_ window: Window, owner: Window?) -> Bool {
        guard let owner else { return false }
        if let decided = window.occludedByFullscreen(at: owner) { return decided }
        guard let windowIndex = windows.backToFrontIndex(of: window.id),
              let ownerIndex = windows.backToFrontIndex(of: owner.id)
        else { return false }
        return windowIndex < ownerIndex
    }

    /// One pass over the model: the ids of all windows fully occluded by their
    /// output's fullscreen owner. O(n) for a caller (hit-test, render) that would
    /// otherwise call `isOccludedByFullscreen` — each an O(n) owner rescan — per
    /// window. Empty when no output has a fullscreen owner.
    public func fullscreenOccludedWindowIDs() -> Set<WindowID> {
        // Front-most fullscreen owner per output, in one front-to-back pass (the
        // first qualifying window for an output is its front-most = its owner).
        var owners: [DisplayID: Window] = [:]
        for window in windows.windowsFrontToBack {
            guard window.isManagedAppWindow(), window.activeFullscreen,
                  window.mapped, !window.minimized
            else { continue }
            let output = spaces.policyOutputID(for: window, layout: layout)
            if owners[output] == nil { owners[output] = window }
        }
        guard !owners.isEmpty else { return [] }
        var occluded: Set<WindowID> = []
        for window in windows.windows {
            let output = spaces.policyOutputID(for: window, layout: layout)
            if isOccludedByFullscreen(window, owner: owners[output]) { occluded.insert(window.id) }
        }
        return occluded
    }
}
