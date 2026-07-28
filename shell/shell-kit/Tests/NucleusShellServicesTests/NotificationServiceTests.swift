@testable import NucleusShellServices
import Testing

@MainActor
@Suite struct NotificationServiceTests {
    @Test func replacementAndDismissalPublishShellOwnedState() {
        let service = NotificationService()
        var snapshots: [[ShellNotification]] = []
        service.onChanged = { snapshots.append($0) }

        let first = service.notify(
            applicationName: "Fixture",
            summary: "First")
        let second = service.notify(
            replacesID: first,
            summary: "Replacement")

        #expect(service.notifications.map(\.id) == [second])
        #expect(service.notifications.first?.summary == "Replacement")
        #expect(snapshots.count == 3)
        service.dismiss(id: second)
        #expect(service.notifications.isEmpty)
    }
}
