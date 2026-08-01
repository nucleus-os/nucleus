/// Product-facing window state for the shell taskbar.
///
/// This deliberately does not reuse a Wayland protocol record. The runtime
/// projects whichever compositor protocol supplies the desktop model into this
/// value, and product views remain ordinary Swift/NucleusUI consumers.
package struct ShellWindowSnapshot: Identifiable, Sendable, Equatable {
    package let id: UInt64
    package var title: String
    package var applicationID: String
    package var isActive: Bool
    package var isMinimized: Bool

    package init(
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

    package var displayTitle: String {
        if !title.isEmpty { return title }
        if !applicationID.isEmpty { return applicationID }
        return "Untitled"
    }
}

package enum ShellWindowAction: Sendable, Equatable {
    case activate
    case close
    case setMinimized(Bool)
}
