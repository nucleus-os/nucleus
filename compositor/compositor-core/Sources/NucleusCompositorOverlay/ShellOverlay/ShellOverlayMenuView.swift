public import NucleusUI

/// Window-menu command tags reported back to compositor input policy.
public enum WindowMenuVerb: Int, Sendable {
    case close = 0
    case minimize = 1
    case zoom = 2
    case toggleFullScreen = 3
    case move = 4
    case resize = 5
}

/// Window capabilities cross the overlay boundary as one scalar. The portable
/// menu model owns validation, presentation, input, accessibility, and teardown.
public struct WindowMenuCapabilities: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let closable =
        WindowMenuCapabilities(rawValue: 1 << 0)
    public static let minimizable =
        WindowMenuCapabilities(rawValue: 1 << 1)
    public static let zoomable =
        WindowMenuCapabilities(rawValue: 1 << 2)
    public static let fullScreenable =
        WindowMenuCapabilities(rawValue: 1 << 3)
    public static let movable =
        WindowMenuCapabilities(rawValue: 1 << 4)
    public static let resizable =
        WindowMenuCapabilities(rawValue: 1 << 5)
}

/// Construct the overlay's command data in the foundation menu model.
@MainActor
public func makeWindowMenu(
    capabilities: UInt32,
    perform: @escaping @MainActor (WindowMenuVerb) -> Void
) -> Menu {
    let capabilities = WindowMenuCapabilities(rawValue: capabilities)

    func command(
        _ verb: WindowMenuVerb,
        title: String,
        enabled: Bool
    ) -> MenuItem {
        MenuItem(
            id: verb.rawValue,
            title: title,
            isEnabled: enabled
        ) {
            perform(verb)
        }
    }

    return Menu(items: [
        command(
            .minimize,
            title: "Minimize",
            enabled: capabilities.contains(.minimizable)),
        command(
            .zoom,
            title: "Zoom",
            enabled: capabilities.contains(.zoomable)),
        .separator(id: "window-layout-separator"),
        command(
            .move,
            title: "Move",
            enabled: capabilities.contains(.movable)),
        command(
            .resize,
            title: "Resize",
            enabled: capabilities.contains(.resizable)),
        command(
            .toggleFullScreen,
            title: "Enter Full Screen",
            enabled: capabilities.contains(.fullScreenable)),
        .separator(id: "window-close-separator"),
        command(
            .close,
            title: "Close",
            enabled: capabilities.contains(.closable)),
    ])
}
