public enum NucleusDesktopCapabilityKind: String, Sendable, CaseIterable {
    case compositor = "wl_compositor"
    case subcompositor = "wl_subcompositor"
    case sharedMemory = "wl_shm"
    case output = "wl_output"
    case seat = "wl_seat"
    case layerShell = "zwlr_layer_shell_v1"
    case foreignToplevel = "zwlr_foreign_toplevel_manager_v1"
    case sessionLock = "ext_session_lock_manager_v1"
    case screencopy = "zwlr_screencopy_manager_v1"
    case viewporter = "wp_viewporter"
    case fractionalScale = "wp_fractional_scale_manager_v1"
    case outputDescription = "zxdg_output_manager_v1"
    case textInput = "zwp_text_input_manager_v3"
    case cursorShape = "wp_cursor_shape_manager_v1"
    case dataControl = "ext_data_control_manager_v1"
    case dataDevice = "wl_data_device_manager"
    case windowManagement = "xdg_wm_base"
    case dmaBuf = "zwp_linux_dmabuf_v1"
    case drmSyncobj = "wp_linux_drm_syncobj_manager_v1"
    case presentationTiming = "wp_presentation"
    case idleNotification = "ext_idle_notifier_v1"
    case alphaModifier = "wp_alpha_modifier_v1"
}

public struct NucleusDesktopSubsurfaceConfiguration:
    Sendable, Equatable
{
    public var x: Int32
    public var y: Int32

    public init(x: Int32 = 0, y: Int32 = 0) {
        self.x = x
        self.y = y
    }
}

public struct NucleusDesktopWindowConfiguration: Sendable, Equatable {
    public var title: String
    public var applicationID: String

    public init(title: String, applicationID: String) {
        self.title = title
        self.applicationID = applicationID
    }
}

public struct NucleusDesktopPopupConfiguration: Sendable, Equatable {
    public var width: Int32
    public var height: Int32
    public var anchorX: Int32
    public var anchorY: Int32
    public var anchorWidth: Int32
    public var anchorHeight: Int32

    public init(
        width: Int32,
        height: Int32,
        anchorX: Int32,
        anchorY: Int32,
        anchorWidth: Int32,
        anchorHeight: Int32
    ) {
        precondition(width > 0 && height > 0)
        precondition(anchorWidth > 0 && anchorHeight > 0)
        self.width = width
        self.height = height
        self.anchorX = anchorX
        self.anchorY = anchorY
        self.anchorWidth = anchorWidth
        self.anchorHeight = anchorHeight
    }
}

public enum NucleusDesktopWindowEvent: Sendable, Equatable {
    case configured(width: Int32, height: Int32, serial: UInt32)
    case closeRequested
}

public enum NucleusDesktopPopupEvent: Sendable, Equatable {
    case configured(
        x: Int32, y: Int32, width: Int32, height: Int32, serial: UInt32)
    case dismissed
}

public enum NucleusDesktopWindowError: Error, Sendable, Equatable {
    case capabilityUnavailable
    case protocolFailure
}

@MainActor
public final class NucleusDesktopCapability {
    public let kind: NucleusDesktopCapabilityKind
    public let generation: UInt64
    public private(set) var isValid: Bool

    public init(
        kind: NucleusDesktopCapabilityKind,
        generation: UInt64
    ) {
        self.kind = kind
        self.generation = generation
        self.isValid = true
    }

    public func invalidate() {
        isValid = false
    }
}

public enum NucleusDesktopLifecycleEvent {
    case capabilityAvailable(NucleusDesktopCapability)
    case capabilityUnavailable(
        kind: NucleusDesktopCapabilityKind,
        generation: UInt64)
    case compositorDisconnected
}
