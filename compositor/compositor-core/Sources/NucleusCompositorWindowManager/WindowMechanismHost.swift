import NucleusTypes
import NucleusCompositorServerTypes
import NucleusCompositorServer

/// Stage B protocol that the reactor dispatches against via
/// `std.swift.ProtocolCaller`. First slice: three primitive-in/
/// primitive-out queries that previously had per-method `@c` exports.
/// Additional clusters (interaction, configure, output normalization,
/// xdg/xwayland state) join this protocol as they migrate.
///
/// Method names are prefixed to avoid colliding with existing
/// `WindowManager` methods that return `Bool` / take richer types;
/// the protocol surface returns wire-friendly primitives so the
/// witness ABI lines up with the reactor side.
@MainActor
public protocol WindowMechanismHost: AnyObject {
    func interactiveGrabActive() -> Bool
    func nextLayoutTransitionID() -> UInt64
    func evaluateFocusOnMap(windowID: UInt64) -> Bool
    func seedInteractiveStartContext(windowID: UInt64, cursorX: Double, cursorY: Double, startRect: WireWindowRect)
    func beginInteractiveMove(windowID: UInt64, serial: UInt32)
    func beginInteractiveResize(windowID: UInt64, serial: UInt32, edges: WireResizeEdges)
    func updateInteractiveGrab(cursorX: Double, cursorY: Double) throws(HostCallError) -> WireInteractionGrabUpdate?
    func endInteractiveGrab()
    func clearGrabFor(windowID: UInt64)
    func fullscreenRelinquishPlan(outputID: UInt64, exceptID: UInt64) throws(HostCallError) -> [UInt64]
    func migrateOffOutput(windowID: UInt64, removedOutputID: UInt64, hasFallbackOutputID: Bool, fallbackOutputID: UInt64, hasRemovedUsable: Bool, removedUsable: WireUsableArea, hasFallbackUsable: Bool, fallbackUsable: WireUsableArea, hasFullscreenRect: Bool, fullscreenRect: WireWindowRect, hasMaximizedRect: Bool, maximizedRect: WireWindowRect) throws(HostCallError) -> WireOutputMigrationResult
    func backdropPolicyResolve(
        inputs: UnsafePointer<WireBackdropLayerInput>?,
        inputsLen: UInt32
    ) throws(HostCallError) -> [WireBackdropDraw]
    func backdropResolveMaterials(
        inputs: UnsafePointer<WireBackdropMaterialInput>?,
        inputsLen: UInt32,
        keyWindowID: UInt64,
        accessibility: WireBackdropAccessibility,
        frameTime: Double
    ) throws(HostCallError) -> [WireBackdropMaterialSpec]
    /// Whether the focused window's client speaks Command/Super natively, so the
    /// compositor must NOT rewrite its macOS-shape Command chords into Linux Ctrl
    /// chords. Consults the window's identity — xdg app-id, Xwayland class/instance,
    /// shell layer surfaces — and the native-Command app list, all of which live on
    /// this side. The seat-translation mechanism calls this for the focused key.
    func nativeCommandPolicy(windowID: UInt64) -> Bool
    // All window-lifecycle xdg + xwayland crossings moved off this relay onto the
    // WaylandRouter substrate (the Swift roles / xwm reach WindowManager
    // in-process there). What remains is the mechanism→policy surface above.
}

@MainActor
extension WindowManager: WindowMechanismHost {
    public func interactiveGrabActive() -> Bool {
        interaction.hasGrab
    }

    public func nextLayoutTransitionID() -> UInt64 {
        interaction.allocLayoutTransitionID()
    }

    public func evaluateFocusOnMap(windowID: UInt64) -> Bool {
        shouldFocusOnMap(windowID: windowID)
    }

    public func seedInteractiveStartContext(
        windowID: UInt64,
        cursorX: Double,
        cursorY: Double,
        startRect: WireWindowRect
    ) {
        seedInteractiveStartContext(
            windowID: windowID,
            cursorX: cursorX,
            cursorY: cursorY,
            startRect: WindowRect(wireValue: startRect)
        )
    }

    public func beginInteractiveMove(windowID: UInt64, serial: UInt32) {
        _ = serial
        let context = takeInteractiveStartContext(windowID: windowID)
        interaction.beginInteractiveMove(
            windowID: windowID,
            cursorX: context.cursorX,
            cursorY: context.cursorY,
            startRect: context.startRect
        )
    }

    public func beginInteractiveResize(windowID: UInt64, serial: UInt32, edges: WireResizeEdges) {
        _ = serial
        let context = takeInteractiveStartContext(windowID: windowID)
        interaction.beginInteractiveResize(
            windowID: windowID,
            cursorX: context.cursorX,
            cursorY: context.cursorY,
            startRect: context.startRect,
            edges: edges
        )
    }

    public func updateInteractiveGrab(
        cursorX: Double,
        cursorY: Double
    ) throws(HostCallError) -> WireInteractionGrabUpdate? {
        let update = interaction.updateInteractiveGrab(cursorX: cursorX, cursorY: cursorY)
        guard update.hasUpdate else { return nil }
        return update
    }

    public func endInteractiveGrab() {
        interaction.endInteractiveGrab()
    }

    public func clearGrabFor(windowID: UInt64) {
        interaction.clearGrab(forWindow: windowID)
    }

    public func fullscreenRelinquishPlan(
        outputID: UInt64,
        exceptID: UInt64
    ) throws(HostCallError) -> [UInt64] {
        fullscreenRelinquishPlan(
            outputID: outputID,
            exceptID: exceptID,
            max: Int.max
        )
    }

    public func migrateOffOutput(
        windowID: UInt64,
        removedOutputID: UInt64,
        hasFallbackOutputID: Bool,
        fallbackOutputID: UInt64,
        hasRemovedUsable: Bool,
        removedUsable: WireUsableArea,
        hasFallbackUsable: Bool,
        fallbackUsable: WireUsableArea,
        hasFullscreenRect: Bool,
        fullscreenRect: WireWindowRect,
        hasMaximizedRect: Bool,
        maximizedRect: WireWindowRect
    ) throws(HostCallError) -> WireOutputMigrationResult {
        let result = migrateOffOutput(
            windowID: windowID,
            plan: OutputMigrationPlan(
                removedOutputID: removedOutputID,
                fallbackOutputID: hasFallbackOutputID ? fallbackOutputID : nil,
                removedUsable: hasRemovedUsable ? removedUsable : nil,
                fallbackUsable: hasFallbackUsable ? fallbackUsable : nil,
                fullscreenRect: hasFullscreenRect ? WindowRect(wireValue: fullscreenRect) : nil,
                maximizedRect: hasMaximizedRect ? WindowRect(wireValue: maximizedRect) : nil
            )
        )
        guard let result else { throw .failed }
        return WireOutputMigrationResult(
            managed: result.managed,
            changed: result.changed,
            specialChanged: result.specialChanged,
            reserved0: 0
        )
    }

    public func nativeCommandPolicy(windowID: UInt64) -> Bool {
        // Shell-owned layer surfaces (the bar, overlays) speak Command natively.
        if server.window(id: windowID)?.source == .layerShell { return true }
        // xdg toplevels match on their application id.
        if let appID = server.window(id: windowID)?.appId, Self.isNativeCommandIdentity(appID) {
            return true
        }
        // Xwayland windows match on their X11 class or instance.
        if let role = xwaylandRole(windowID: windowID) {
            return Self.isNativeCommandIdentity(role.windowClass)
                || Self.isNativeCommandIdentity(role.windowInstance)
        }
        return false
    }

    /// Apps whose clients use Command/Super natively — terminals that bind Super,
    /// and browsers that honor it for their own shortcuts — matched
    /// case-insensitively against an xdg app-id or an Xwayland class/instance.
    private static func isNativeCommandIdentity(_ identity: String) -> Bool {
        guard !identity.isEmpty else { return false }
        let lowered = identity.lowercased()
        return nativeCommandIdentities.contains(lowered)
    }

    /// Lowercased, so the match is case-insensitive against a `lowercased()` query.
    private static let nativeCommandIdentities: Set<String> = [
        "kitty", "kitty.desktop",
        "org.wezfurlong.wezterm", "org.wezfurlong.wezterm.desktop",
        "foot", "foot.desktop",
        "com.mitchellh.ghostty", "com.mitchellh.ghostty.desktop",
        "org.gnome.terminal", "org.gnome.terminal.desktop",
        "firefox", "firefox.desktop", "navigator",
    ]

}
