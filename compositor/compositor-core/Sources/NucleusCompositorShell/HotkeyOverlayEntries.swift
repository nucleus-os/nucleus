public import NucleusCompositorOverlay
public import NucleusConfig

/// Renders the live binding table as shortcut-overlay rows.
///
/// The overlay used to carry a hand-written list, which drifted the moment
/// anything changed — by the time bindings became configurable it was
/// advertising a screenshot shortcut that no longer existed and omitting every
/// workspace bind. Deriving the rows means the overlay cannot be wrong.
public enum HotkeyOverlayEntries {
    /// Group order. Bindings appear under the first group their action
    /// matches, so related shortcuts stay together no matter how the file
    /// orders them.
    private enum Group: Int, CaseIterable {
        case applications
        case window
        case workspaces
        case appearance
        case session

        static func of(_ action: BindAction) -> Group {
            switch action {
            case .launch: .applications
            case .closeWindow, .showWindowMenu, .tile: .window
            case .activateWorkspace, .moveWindowToWorkspace: .workspaces
            case .adjustBackdropIntensity: .appearance
            case .toggleHotkeyOverlay, .dismissHotkeyOverlay: .session
            }
        }
    }

    public static func rows(for binds: [KeyBind]) -> [ShellOverlayHotkeyEntry] {
        var grouped: [Group: [ShellOverlayHotkeyEntry]] = [:]
        for bind in binds {
            grouped[Group.of(bind.action), default: []].append(
                ShellOverlayHotkeyEntry(
                    key: bind.keys.text,
                    description: describe(bind.action)))
        }

        var rows: [ShellOverlayHotkeyEntry] = []
        for group in Group.allCases {
            guard let entries = grouped[group], !entries.isEmpty else {
                continue
            }
            if !rows.isEmpty { rows.append(.separator) }
            rows.append(contentsOf: entries)
        }
        return rows
    }

    /// A short human description. Kept beside the grouping rather than on
    /// `BindAction` itself, because this is presentation: the configuration
    /// model has no business owning display strings.
    static func describe(_ action: BindAction) -> String {
        switch action {
        case .closeWindow: "Close window"
        case .showWindowMenu: "Window menu"
        case .toggleHotkeyOverlay: "Toggle this overlay"
        case .dismissHotkeyOverlay: "Dismiss overlay"
        case .tile(let direction): "Tile \(describe(direction))"
        case .adjustBackdropIntensity(let delta):
            delta < 0 ? "Dim backdrop" : "Brighten backdrop"
        case .activateWorkspace(let index): "Switch to workspace \(index)"
        case .moveWindowToWorkspace(let index):
            "Move window to workspace \(index)"
        case .launch(let appIDs, let command):
            "Launch \(launchName(appIDs: appIDs, command: command))"
        }
    }

    private static func describe(_ direction: TileDirection) -> String {
        switch direction {
        case .left: "left"
        case .right: "right"
        case .top: "top"
        case .bottom: "bottom"
        case .topLeft: "top left"
        case .topRight: "top right"
        case .bottomLeft: "bottom left"
        case .bottomRight: "bottom right"
        case .maximize: "maximized"
        }
    }

    /// Name a launch by its first desktop entry, stripped of the `.desktop`
    /// suffix and any reverse-DNS prefix, falling back to the command. The
    /// desktop file is not read here — this runs on every overlay rebuild, and
    /// an unresolvable name is better than filesystem work on that path.
    static func launchName(appIDs: [String], command: [String]) -> String {
        if let first = appIDs.first {
            var name = first
            if name.hasSuffix(".desktop") {
                name = String(name.dropLast(".desktop".count))
            }
            if let lastDot = name.lastIndex(of: "."),
                lastDot != name.startIndex
            {
                name = String(name[name.index(after: lastDot)...])
            }
            if !name.isEmpty { return capitalizedFirst(name) }
        }
        return capitalizedFirst(command.first ?? "application")
    }

    private static func capitalizedFirst(_ value: String) -> String {
        guard let first = value.first else { return value }
        return String(first).uppercased() + value.dropFirst()
    }
}
