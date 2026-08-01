package struct ShellNotification: Sendable, Equatable {
    package var id: UInt32
    package var applicationName: String
    package var summary: String
    package var body: String
    package var expireTimeoutMilliseconds: Int32

    package init(
        id: UInt32,
        applicationName: String,
        summary: String,
        body: String,
        expireTimeoutMilliseconds: Int32
    ) {
        self.id = id
        self.applicationName = applicationName
        self.summary = summary
        self.body = body
        self.expireTimeoutMilliseconds =
            expireTimeoutMilliseconds
    }
}

/// Shell-owned notification state. A D-Bus adapter can feed this service
/// without giving the compositor any notification or UI dependency.
@MainActor
package final class NotificationService {
    package private(set) var notifications: [ShellNotification] = []
    package var onChanged: (([ShellNotification]) -> Void)?
    private var nextID: UInt32 = 1

    package init() {}

    @discardableResult
    package func notify(
        applicationName: String = "",
        replacesID: UInt32 = 0,
        summary: String,
        body: String = "",
        expireTimeoutMilliseconds: Int32 = -1
    ) -> UInt32 {
        if replacesID != 0 {
            dismiss(id: replacesID)
        }
        let id = nextID
        nextID &+= 1
        if nextID == 0 { nextID = 1 }
        notifications.append(
            ShellNotification(
                id: id,
                applicationName: applicationName,
                summary: summary,
                body: body,
                expireTimeoutMilliseconds:
                    expireTimeoutMilliseconds))
        onChanged?(notifications)
        return id
    }

    package func dismiss(id: UInt32) {
        let previousCount = notifications.count
        notifications.removeAll { $0.id == id }
        if notifications.count != previousCount {
            onChanged?(notifications)
        }
    }

    package func reset() {
        guard !notifications.isEmpty else { return }
        notifications.removeAll(keepingCapacity: true)
        onChanged?(notifications)
    }
}
