package struct ShellNotificationID: Hashable, Sendable {
    package var sourceID: String
    package var notificationID: String

    package init(sourceID: String, notificationID: String) {
        precondition(!sourceID.isEmpty)
        precondition(!notificationID.isEmpty)
        self.sourceID = sourceID
        self.notificationID = notificationID
    }

    package var stableID: String {
        "\(sourceID.utf8.count):\(sourceID)\(notificationID)"
    }
}

package struct ShellNotificationAction: Sendable, Equatable {
    package var id: String
    package var title: String

    package init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

package struct ShellNotification: Sendable, Equatable {
    package var id: ShellNotificationID
    package var applicationID: String
    package var applicationName: String
    package var summary: String
    package var body: String
    package var iconDigest: String?
    package var urgency: ShellNotificationUrgency
    package var progress: ShellNotificationProgress?
    package var hasDefaultAction: Bool
    package var actions: [ShellNotificationAction]

    package init(
        id: ShellNotificationID,
        applicationID: String,
        applicationName: String,
        summary: String,
        body: String,
        iconDigest: String? = nil,
        urgency: ShellNotificationUrgency = .normal,
        progress: ShellNotificationProgress? = nil,
        hasDefaultAction: Bool = false,
        actions: [ShellNotificationAction] = []
    ) {
        self.id = id
        self.applicationID = applicationID
        self.applicationName = applicationName
        self.summary = summary
        self.body = body
        self.iconDigest = iconDigest
        self.urgency = urgency
        self.progress = progress
        self.hasDefaultAction = hasDefaultAction
        self.actions = actions
    }
}

package enum ShellNotificationUrgency: Sendable, Equatable {
    case low
    case normal
    case critical
}

package struct ShellNotificationProgress: Sendable, Equatable {
    package var value: UInt64
    package var total: UInt64

    package init(value: UInt64, total: UInt64) {
        precondition(total > 0 && value <= total)
        self.value = value
        self.total = total
    }
}

package enum ShellNotificationSourceCommand: Sendable, Equatable {
    case dismiss(notificationID: String)
    case activate(
        notificationID: String,
        actionID: String?,
        activationToken: String?)
}

/// Provider-neutral notification state owned and presented by the shell.
@MainActor
package final class NotificationService {
    package private(set) var notifications: [ShellNotification] = []
    package var onChanged: (([ShellNotification]) -> Void)?

    private var records: [ShellNotificationID: ShellNotification] = [:]
    private var sourceHandlers: [String: @MainActor (ShellNotificationSourceCommand) -> Void] = [:]

    package init() {}

    package func attachSource(
        _ sourceID: String,
        commandHandler:
            @escaping @MainActor (
                ShellNotificationSourceCommand
            ) -> Void
    ) {
        precondition(!sourceID.isEmpty)
        sourceHandlers[sourceID] = commandHandler
    }

    package func replace(
        sourceID: String,
        with replacement: [ShellNotification]
    ) {
        records = records.filter { $0.key.sourceID != sourceID }
        for notification in replacement {
            precondition(notification.id.sourceID == sourceID)
            records[notification.id] = notification
        }
        publish()
    }

    package func upsert(_ notification: ShellNotification) {
        records[notification.id] = notification
        publish()
    }

    package func remove(_ id: ShellNotificationID) {
        guard records.removeValue(forKey: id) != nil else { return }
        publish()
    }

    package func withdrawSource(_ sourceID: String) {
        let previousCount = records.count
        records = records.filter { $0.key.sourceID != sourceID }
        if records.count != previousCount {
            publish()
        }
    }

    package func detachSource(_ sourceID: String) {
        sourceHandlers.removeValue(forKey: sourceID)
        withdrawSource(sourceID)
    }

    package func dismiss(stableID: String) {
        guard let notification = notification(stableID: stableID) else { return }
        sourceHandlers[notification.id.sourceID]?(
            .dismiss(notificationID: notification.id.notificationID))
        remove(notification.id)
    }

    package func activate(
        stableID: String,
        actionID: String? = nil,
        activationToken: String? = nil
    ) {
        guard let notification = notification(stableID: stableID) else { return }
        sourceHandlers[notification.id.sourceID]?(
            .activate(
                notificationID: notification.id.notificationID,
                actionID: actionID,
                activationToken: activationToken))
    }

    package func reset() {
        guard !records.isEmpty else { return }
        records.removeAll(keepingCapacity: true)
        publish()
    }

    private func notification(stableID: String) -> ShellNotification? {
        records.values.first { $0.id.stableID == stableID }
    }

    private func publish() {
        notifications = records.values.sorted {
            if $0.id.sourceID == $1.id.sourceID {
                return $0.id.notificationID < $1.id.notificationID
            }
            return $0.id.sourceID < $1.id.sourceID
        }
        onChanged?(notifications)
    }
}
