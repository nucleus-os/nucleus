import FoundationEssentials

/// Where a window goes when tiled.
public enum TileDirection: String, Codable, Sendable, CaseIterable {
    case left, right, top, bottom
    case topLeft = "top-left"
    case topRight = "top-right"
    case bottomLeft = "bottom-left"
    case bottomRight = "bottom-right"
    case maximize
}

/// Everything a key binding can ask the compositor to do.
///
/// This is deliberately one vocabulary rather than a config-only type. The
/// control socket has to name the same operations a binding names — "close the
/// focused window" is one concept whether it arrives from a keypress or a CLI —
/// so defining it twice would guarantee the two drift.
///
/// Encoded as a tagged object: an `action` discriminator plus that case's
/// parameters. A flat shape keeps the file readable and, more importantly,
/// keeps decoding errors anchored to a real coding path, so a bad parameter
/// reports as `binds.[3].index` rather than as an opaque failure.
public enum BindAction: Equatable, Sendable {
    case closeWindow
    case showWindowMenu
    case toggleHotkeyOverlay
    case dismissHotkeyOverlay
    case tile(TileDirection)
    case adjustBackdropIntensity(Double)
    /// Switch the focused output to a 1-based workspace index.
    case activateWorkspace(UInt32)
    /// Move the focused window to a 1-based workspace index on its output.
    case moveWindowToWorkspace(UInt32)
    /// Launch the first available desktop entry, falling back to a command.
    case launch(appIDs: [String], command: [String])

    /// The discriminator written to and read from the file.
    public var name: String {
        switch self {
        case .closeWindow: "close-window"
        case .showWindowMenu: "show-window-menu"
        case .toggleHotkeyOverlay: "toggle-hotkey-overlay"
        case .dismissHotkeyOverlay: "dismiss-hotkey-overlay"
        case .tile: "tile"
        case .adjustBackdropIntensity: "adjust-backdrop-intensity"
        case .activateWorkspace: "activate-workspace"
        case .moveWindowToWorkspace: "move-window-to-workspace"
        case .launch: "launch"
        }
    }

    public static let allNames = [
        "close-window", "show-window-menu", "toggle-hotkey-overlay",
        "dismiss-hotkey-overlay", "tile", "adjust-backdrop-intensity",
        "activate-workspace", "move-window-to-workspace", "launch",
    ]

    public enum RuntimeOwner: Sendable, Equatable {
        case renderServer
        case shell
    }

    /// The one process allowed to execute this action's semantic effect.
    public var runtimeOwner: RuntimeOwner {
        switch self {
        case .launch, .toggleHotkeyOverlay, .dismissHotkeyOverlay,
             .showWindowMenu:
            .shell
        case .closeWindow, .tile, .adjustBackdropIntensity,
             .activateWorkspace, .moveWindowToWorkspace:
            .renderServer
        }
    }
}

extension BindAction: Codable {
    private enum CodingKeys: String, CodingKey {
        case action
        case direction
        case delta
        case index
        // The decoder runs `.convertFromSnakeCase`, so it has already turned
        // the file's `app_ids` into `appIds` before consulting these keys —
        // spelling this `app_ids` would never match anything.
        case appIDs = "appIds"
        case command
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .action)
        switch name {
        case "close-window": self = .closeWindow
        case "show-window-menu": self = .showWindowMenu
        case "toggle-hotkey-overlay": self = .toggleHotkeyOverlay
        case "dismiss-hotkey-overlay": self = .dismissHotkeyOverlay
        case "tile":
            self = .tile(
                try container.decode(TileDirection.self, forKey: .direction))
        case "adjust-backdrop-intensity":
            self = .adjustBackdropIntensity(
                try container.decode(Double.self, forKey: .delta))
        case "activate-workspace":
            self = .activateWorkspace(
                try Self.workspaceIndex(from: container))
        case "move-window-to-workspace":
            self = .moveWindowToWorkspace(
                try Self.workspaceIndex(from: container))
        case "launch":
            let appIDs = try container.decodeIfPresent(
                [String].self, forKey: .appIDs) ?? []
            let command = try container.decodeIfPresent(
                [String].self, forKey: .command) ?? []
            guard !appIDs.isEmpty || !command.isEmpty else {
                throw DecodingError.dataCorrupted(DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription:
                        "launch needs at least one of app_ids or command"))
            }
            self = .launch(appIDs: appIDs, command: command)
        default:
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: container.codingPath + [CodingKeys.action],
                debugDescription: "unknown action '\(name)'; expected one of "
                    + BindAction.allNames.joined(separator: ", ")))
        }
    }

    /// Workspace indices are 1-based everywhere they are user-visible, so 0 is
    /// a mistake worth naming rather than silently treating as the first.
    private static func workspaceIndex(
        from container: KeyedDecodingContainer<CodingKeys>
    ) throws -> UInt32 {
        let index = try container.decode(UInt32.self, forKey: .index)
        guard index >= 1 else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: container.codingPath + [CodingKeys.index],
                debugDescription: "workspace index is 1-based; got 0"))
        }
        return index
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .action)
        switch self {
        case .closeWindow, .showWindowMenu, .toggleHotkeyOverlay,
            .dismissHotkeyOverlay:
            break
        case .tile(let direction):
            try container.encode(direction, forKey: .direction)
        case .adjustBackdropIntensity(let delta):
            try container.encode(delta, forKey: .delta)
        case .activateWorkspace(let index),
            .moveWindowToWorkspace(let index):
            try container.encode(index, forKey: .index)
        case .launch(let appIDs, let command):
            if !appIDs.isEmpty { try container.encode(appIDs, forKey: .appIDs) }
            if !command.isEmpty {
                try container.encode(command, forKey: .command)
            }
        }
    }
}

/// One binding: a chord and what it does.
public struct KeyBind: Codable, Equatable, Sendable {
    public var keys: KeyChord
    public var action: BindAction

    public init(keys: KeyChord, action: BindAction) {
        self.keys = keys
        self.action = action
    }

    private enum CodingKeys: String, CodingKey {
        case keys
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keys = try container.decode(KeyChord.self, forKey: .keys)
        // The action's parameters sit beside `keys` rather than nested, so it
        // decodes from the same container.
        action = try BindAction(from: decoder)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keys, forKey: .keys)
        try action.encode(to: encoder)
    }
}
