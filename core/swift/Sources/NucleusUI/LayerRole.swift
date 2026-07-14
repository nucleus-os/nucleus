import NucleusLayers

public enum LayerRole: Sendable, Equatable {
    case generic
    case windowRoot
    case windowContentViewport
    case notification
    case hotkeyOverlay
    case wallpaper
    case dock

    package var layersRole: NucleusLayers.LayerRole {
        switch self {
        case .generic:
            .generic
        case .windowRoot:
            .windowRoot
        case .windowContentViewport:
            .windowContentViewport
        case .notification:
            .notification
        case .hotkeyOverlay:
            .hotkeyOverlay
        case .wallpaper:
            .wallpaper
        case .dock:
            .dock
        }
    }
}
