import NucleusCompositorOverlayTypes
import NucleusCompositorOverlayScene

/// Host-protocol shape used by `Bezel.invoke` on the caller side.
@MainActor
public protocol BezelHost: AnyObject {
    func prepareFrame(
        outputWidth: UInt32,
        outputHeight: UInt32,
        scale: Float,
        overlayX: Float,
        overlayY: Float,
        overlayW: Float,
        overlayH: Float
    )
    func dispatchInput(_ event: NucleusCompositorOverlayTypes.InputEvent) -> NucleusCompositorOverlayTypes.InputResult
    func dismissHotkey()
    func toggleHotkey()
    func isHotkeyVisible() -> Bool
    func hasActiveNotifications() -> Bool
    func hasCommittedContent() -> Bool
    func notificationDrawCount() -> UInt
    func currentDevicePixelRatio() -> Float
    func takeFrameRequest() -> Bool
}

@MainActor
public final class BezelService: BezelHost {
    public static let shared = BezelService()

    private struct PreparedFrame: Equatable {
        var outputWidth: UInt32
        var outputHeight: UInt32
        var scale: Float
        var overlayX: Float
        var overlayY: Float
        var overlayW: Float
        var overlayH: Float
    }

    private var hotkeyVisible = true
    private var frameRequested = true
    private var devicePixelRatio: Float = 1
    private var lastPreparedFrame: PreparedFrame?

    private init() {}

    public func prepareFrame(
        outputWidth: UInt32,
        outputHeight: UInt32,
        scale: Float,
        overlayX: Float,
        overlayY: Float,
        overlayW: Float,
        overlayH: Float
    ) {
        let preparedFrame = PreparedFrame(
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            scale: scale,
            overlayX: overlayX,
            overlayY: overlayY,
            overlayW: overlayW,
            overlayH: overlayH
        )
        devicePixelRatio = scale
        guard lastPreparedFrame != preparedFrame || hasActiveNotificationsImpl() else {
            return
        }
        lastPreparedFrame = preparedFrame
        OverlaySceneRuntime.shared.frameUpdated(NucleusCompositorOverlayTypes.FrameInfo(
            outputWidth: outputWidth,
            outputHeight: outputHeight,
            devicePixelRatio: scale,
            overlayRegionX: overlayX,
            overlayRegionY: overlayY,
            overlayRegionW: overlayW,
            overlayRegionH: overlayH
        ))
    }

    public func dispatchInput(_ event: NucleusCompositorOverlayTypes.InputEvent) -> NucleusCompositorOverlayTypes.InputResult {
        let result = OverlaySceneRuntime.shared.inputDispatched(event)
        if result.wantsFrame { frameRequested = true }
        return result
    }

    public func dismissHotkey() {
        setHotkeyVisible(false)
    }

    public func toggleHotkey() {
        setHotkeyVisible(!hotkeyVisible)
    }

    public func setHotkeyVisible(_ visible: Bool) {
        guard hotkeyVisible != visible else { return }
        hotkeyVisible = visible
        OverlaySceneRuntime.shared.hotkeyVisibilitySet(visible: visible)
        frameRequested = true
    }

    public func isHotkeyVisible() -> Bool {
        hotkeyVisible
    }

    public func hasActiveNotifications() -> Bool {
        hasActiveNotificationsImpl()
    }

    private func hasActiveNotificationsImpl() -> Bool {
        OverlaySceneRuntime.shared.notificationFrameActive()
    }

    public func hasCommittedContent() -> Bool {
        NotificationService.shared.notificationCount() > 0 || hotkeyVisible
    }

    public func notificationDrawCount() -> UInt {
        NotificationService.shared.notificationCount() > 0 ? 1 : 0
    }

    public func currentDevicePixelRatio() -> Float {
        devicePixelRatio
    }

    public func takeFrameRequest() -> Bool {
        let requested = frameRequested
        frameRequested = false
        return requested
    }
}

@MainActor public func nucleus_compositor_shell_toggle_hotkey() {
    BezelService.shared.toggleHotkey()
}

@MainActor public func nucleus_compositor_shell_dismiss_hotkey() {
    BezelService.shared.dismissHotkey()
}

@MainActor public func nucleus_compositor_shell_overlay_active() -> Bool {
    BezelService.shared.isHotkeyVisible()
        || NotificationService.shared.notificationCount() > 0
        || BezelService.shared.hasCommittedContent()
        || nucleus_compositor_overlay_scene_menu_visible()
}

@MainActor public func nucleus_compositor_shell_overlay_pointer(
    _ x: Float,
    _ y: Float,
    _ kind: UInt32,
    _ button: UInt32,
    _ timestampNs: UInt64
) -> UInt64 {
    guard let inputKind = NucleusCompositorOverlayTypes.InputKind(rawValue: kind) else { return 0 }
    let result = BezelService.shared.dispatchInput(.init(
        kind: inputKind, button: button, x: x, y: y, scrollX: 0, scrollY: 0,
        keycode: 0, modifiers: 0, timestampNs: timestampNs
    ))
    return packedOverlayResult(result)
}

@MainActor public func nucleus_compositor_shell_overlay_key(
    _ keycode: UInt32,
    _ modifiers: UInt32,
    _ kind: UInt32,
    _ timestampNs: UInt64
) -> UInt64 {
    guard let inputKind = NucleusCompositorOverlayTypes.InputKind(rawValue: kind) else { return 0 }
    let result = BezelService.shared.dispatchInput(.init(
        kind: inputKind, button: 0, x: 0, y: 0, scrollX: 0, scrollY: 0,
        keycode: keycode, modifiers: modifiers, timestampNs: timestampNs
    ))
    return packedOverlayResult(result)
}

private func packedOverlayResult(_ result: NucleusCompositorOverlayTypes.InputResult) -> UInt64 {
    var bits: UInt32 = 0
    if result.consumed { bits |= 1 }
    if result.cursor == .pointer { bits |= 2 }
    if result.wantsFrame { bits |= 4 }
    return UInt64(bits)
}
