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
    private unowned let overlayScene: OverlaySceneRuntime
    private unowned let notifications: NotificationService

    public init(
        overlayScene: OverlaySceneRuntime,
        notifications: NotificationService
    ) {
        self.overlayScene = overlayScene
        self.notifications = notifications
    }

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
        overlayScene.frameUpdated(NucleusCompositorOverlayTypes.FrameInfo(
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
        let result = overlayScene.inputDispatched(event)
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
        overlayScene.hotkeyVisibilitySet(visible: visible)
        frameRequested = true
    }

    public func isHotkeyVisible() -> Bool {
        hotkeyVisible
    }

    public func hasActiveNotifications() -> Bool {
        hasActiveNotificationsImpl()
    }

    private func hasActiveNotificationsImpl() -> Bool {
        overlayScene.notificationFrameActive()
    }

    public func hasCommittedContent() -> Bool {
        notifications.notificationCount() > 0 || hotkeyVisible
    }

    public func notificationDrawCount() -> UInt {
        notifications.notificationCount() > 0 ? 1 : 0
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
