import Testing

@testable import NucleusShellServices

@MainActor
@Suite struct NotificationServiceTests {
    @Test func providerStateReplacementDismissalAndActivationAreConsistent() {
        let service = NotificationService()
        var snapshots: [[ShellNotification]] = []
        var commands: [ShellNotificationSourceCommand] = []
        service.onChanged = { snapshots.append($0) }
        service.attachSource("android") { commands.append($0) }

        let first = notification(id: "first", summary: "First")
        let replacement = notification(id: "first", summary: "Replacement")
        let second = notification(id: "second", summary: "Second")
        service.replace(sourceID: "android", with: [first])
        service.upsert(replacement)
        service.upsert(second)

        #expect(service.notifications.map(\.summary) == ["Replacement", "Second"])
        service.activate(
            stableID: replacement.id.stableID,
            actionID: "reply",
            activationToken: "token")
        service.dismiss(stableID: second.id.stableID)
        #expect(
            commands == [
                .activate(
                    notificationID: "first",
                    actionID: "reply",
                    activationToken: "token"),
                .dismiss(notificationID: "second"),
            ])
        #expect(service.notifications == [replacement])

        service.withdrawSource("android")
        #expect(service.notifications.isEmpty)
        #expect(snapshots.count == 5)
    }

    @Test func stableIdentityCannotCollideAcrossProviderBoundaries() {
        let left = ShellNotificationID(
            sourceID: "provider:a",
            notificationID: "notice")
        let right = ShellNotificationID(
            sourceID: "provider",
            notificationID: "a:notice")

        #expect(left.stableID != right.stableID)
    }

    private func notification(
        id: String,
        summary: String
    ) -> ShellNotification {
        ShellNotification(
            id: ShellNotificationID(
                sourceID: "android",
                notificationID: id),
            applicationID: "org.example",
            applicationName: "Example",
            summary: summary,
            body: "Body",
            urgency: .normal,
            actions: [ShellNotificationAction(id: "reply", title: "Reply")])
    }
}
