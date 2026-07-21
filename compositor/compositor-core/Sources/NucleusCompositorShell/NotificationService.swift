import NucleusCompositorOverlayTypes
import NucleusCompositorOverlayScene

@MainActor
public final class NotificationService {
    public enum ScreenshotOutcome: UInt32 {
        case saved = 1
        case failed = 2
    }

    public enum ThumbnailUpdate: UInt32 {
        case leaveExisting = 0
        case set = 1
        case clear = 2
    }

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

    @discardableResult
    public func presentScreenshot(
        id: UInt32,
        outcome: ScreenshotOutcome,
        path: String,
        thumbnailUpdate: ThumbnailUpdate,
        thumbnail: UInt64,
        timeoutMs: Int32
    ) -> Bool {
        let summary = outcome == .saved ? "Screenshot saved" : "Screenshot failed"
        let body = URLPath.baseName(path)
        let existing = records[id]
        let desiredThumbnail: UInt64
        switch thumbnailUpdate {
        case .leaveExisting:
            desiredThumbnail = existing?.thumbnailHandle ?? 0
        case .set:
            desiredThumbnail = thumbnail
        case .clear:
            desiredThumbnail = 0
        }
        let showThumbnail = outcome == .saved && desiredThumbnail != 0

        if let existing,
           existing.summary == summary,
           existing.body == body,
           existing.expireTimeoutMs == timeoutMs,
           existing.thumbnailHandle == desiredThumbnail,
           existing.showsThumbnail == showThumbnail {
            return false
        }

        upsert(.init(
            id: id,
            appName: "Nucleus",
            summary: summary,
            body: body,
            thumbnailHandle: desiredThumbnail,
            showsThumbnail: showThumbnail,
            expireTimeoutMs: timeoutMs
        ))
        return true
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
        withStringView(record.appName) { appName in
            withStringView(record.summary) { summary in
                withStringView(record.body) { body in
                    overlayScene.notificationAdded(NucleusCompositorOverlayTypes.NotificationInfo(
                        id: record.id,
                        appName: appName,
                        summary: summary,
                        body: body,
                        thumbnailHandle: record.thumbnailHandle,
                        showThumbnail: record.showsThumbnail,
                        expireTimeoutMs: record.expireTimeoutMs
                    ))
                }
            }
        }
    }
}

private enum URLPath {
    static func baseName(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }
}

func stringFromBytes(_ ptr: UnsafePointer<CChar>?, _ len: Int) -> String {
    guard let ptr, len > 0 else { return "" }
    let raw = UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self)
    return String(decoding: UnsafeBufferPointer(start: raw, count: len), as: UTF8.self)
}

func stringFromBytes(_ ptr: UnsafePointer<UInt8>?, _ len: Int) -> String {
    guard let ptr, len > 0 else { return "" }
    return String(decoding: UnsafeBufferPointer(start: ptr, count: len), as: UTF8.self)
}

func withStringView<R>(_ string: String, _ body: (NucleusCompositorOverlayTypes.StringView) -> R) -> R {
    let bytes = Array(string.utf8)
    return bytes.withUnsafeBufferPointer { buffer in
        body(NucleusCompositorOverlayTypes.StringView(ptr: buffer.baseAddress, len: UInt(buffer.count)))
    }
}
