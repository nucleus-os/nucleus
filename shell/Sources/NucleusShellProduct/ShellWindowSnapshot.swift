/// Product-facing window state for the shell taskbar.
///
/// This deliberately does not reuse a Wayland protocol record. The runtime
/// projects whichever compositor protocol supplies the desktop model into this
/// value, and product views remain ordinary Swift/NucleusUI consumers.
public struct ShellWindowSnapshot: Identifiable, Sendable, Equatable {
    public let id: UInt64
    public var title: String
    public var applicationID: String
    public var isActive: Bool
    public var isMinimized: Bool

    public init(
        id: UInt64,
        title: String = "",
        applicationID: String = "",
        isActive: Bool = false,
        isMinimized: Bool = false
    ) {
        self.id = id
        self.title = title
        self.applicationID = applicationID
        self.isActive = isActive
        self.isMinimized = isMinimized
    }

    public var displayTitle: String {
        if !title.isEmpty { return title }
        if !applicationID.isEmpty { return applicationID }
        return "Untitled"
    }
}

public enum ShellWindowAction: Sendable, Equatable {
    case activate
    case close
    case setMinimized(Bool)
}
