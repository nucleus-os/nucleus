import NucleusCompositorOverlay
public import NucleusCompositorOverlayScene

@MainActor
public final class NotificationService {
    private struct NotificationRecord {
        var id: UInt32
        var appName: String
        var summary: String
        var body: String
        var thumbnailHandle: UInt64
        var showsThumbnail: Bool
        var expireTimeoutMs: Int32
    }

    private var records: [UInt32: NotificationRecord] = [:]
    private var order: [UInt32] = []
    private var nextID: UInt32 = 1
    private var frameRequested = false
    private unowned let overlayScene: OverlaySceneRuntime

    public init(overlayScene: OverlaySceneRuntime) {
        self.overlayScene = overlayScene
    }

    public func reset() {
        records.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
        nextID = 1
        frameRequested = false
    }

    public func reserveID() -> UInt32 {
        let id = nextID
        nextID &+= 1
        if nextID == 0 { nextID = 1 }
        return id
    }

    public func notify(appName: String?, replacesID: UInt32, summary: String?, body: String?, expireTimeout: Int32) -> UInt32 {
        if replacesID > 0 {
            dismiss(id: replacesID, reason: 2)
        }
        let id = reserveID()
        // The wire boundary now distinguishes an absent field (`nil`) from an
        // empty one; the stored record collapses absent to "" for display.
        upsert(.init(
            id: id,
            appName: appName ?? "",
            summary: summary ?? "",
            body: body ?? "",
            thumbnailHandle: 0,
            showsThumbnail: false,
            expireTimeoutMs: expireTimeout
        ))
        return id
    }

    public func dismiss(id: UInt32, reason: UInt32) {
        guard records[id] != nil else { return }
        overlayScene.notificationDismissed(id: id, reason: reason == 0 ? 2 : reason)
        frameRequested = true
    }

    public func notificationClosedFromOverlay(id: UInt32, reason: UInt32) {
        if records.removeValue(forKey: id) != nil {
            order.removeAll { $0 == id }
            frameRequested = true
        }
    }

    public func notificationCount() -> UInt {
        UInt(records.count)
    }

    public func takeFrameRequest() -> Bool {
        let requested = frameRequested
        frameRequested = false
        return requested
    }

    private func upsert(_ record: NotificationRecord) {
        if records[record.id] == nil {
            order.append(record.id)
        }
        records[record.id] = record
        emit(record)
        frameRequested = true
    }

    private func emit(_ record: NotificationRecord) {
        overlayScene.notificationAdded(ShellOverlayNotificationInfo(
            id: record.id,
            appName: record.appName,
            summary: record.summary,
            body: record.body,
            thumbnailHandle: record.thumbnailHandle,
            showsThumbnail: record.showsThumbnail,
            expireTimeoutMs: record.expireTimeoutMs
        ))
    }
}
