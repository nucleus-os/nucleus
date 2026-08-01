package import WaylandClientDispatch

/// One standard `ext_idle_notification_v1` subscription.
///
/// The compositor owns the authoritative input clock and inhibitor state. The
/// client owns only its timeout preference and reaction to the standard
/// idled/resumed events.
@MainActor
package final class NucleusDesktopIdleNotification:
    ExtIdleNotificationV1Events
{
    private let proxy:
        WaylandProxy<ExtIdleNotificationV1Client>
    package var onIdled: (() -> Void)?
    package var onResumed: (() -> Void)?

    package init?(
        client: NucleusDesktopConnection,
        timeoutMilliseconds: UInt32
    ) {
        guard timeoutMilliseconds > 0,
              let notifier = client.idleNotifier,
              let seat = client.seat,
              let proxy = try? notifier.getIdleNotification(
                timeout: timeoutMilliseconds,
                seat: seat)
        else { return nil }
        self.proxy = proxy
        do {
            try proxy.installListener(self)
        } catch {
            try? proxy.destroy()
            return nil
        }
    }

    package func destroy() {
        try? proxy.destroy()
    }

    package func idled(
        _ proxy:
            WaylandBorrowedProxy<ExtIdleNotificationV1Client>
    ) {
        onIdled?()
    }

    package func resumed(
        _ proxy:
            WaylandBorrowedProxy<ExtIdleNotificationV1Client>
    ) {
        onResumed?()
    }

    isolated deinit {
        try? proxy.destroy()
    }
}
