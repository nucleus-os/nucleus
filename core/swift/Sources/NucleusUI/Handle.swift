public struct Handle: Hashable, Sendable {
    package let identity: ObjectIdentifier

    package init(view: View) {
        self.identity = ObjectIdentifier(view)
    }

    package init(window: Window) {
        self.identity = ObjectIdentifier(window)
    }
}
