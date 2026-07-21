import NucleusTypes
import NucleusCompositorServer

/// Shared failure type for the shell caller-boundary (`*Host`) requirements
/// that surface a success/failure split as a caller-side error. One case: the receiving
/// caller wrapper maps any thrown error to its single `error{HostCallFailed}` tag.
/// translate-swift mirrors `throws(HostCallError)` requirements as
/// `error{HostCallFailed}!T`.
public enum HostCallError: Error {
    case failed
}

// Each shell service owns one host boundary and conforms to it directly. The
// per-domain protocols replace the former aggregate `ShellServiceHost`: there is
// no facade object, and the witness for every requirement is a method on the
// owning service (or a thin conformance adapter onto its natural API).

// MARK: - Screenshots

@MainActor
public protocol ScreenshotHost: AnyObject {
    func screenshotRequest(
        origin: ScreenshotOrigin,
        mode: ScreenshotMode,
        targetOutput: UInt32,
        destinationKind: ScreenshotDestination,
        preview: Bool,
        previewWidth: UInt32,
        previewHeight: UInt32
    ) -> UInt32
    func screenshotPendingCount() -> UInt
    func screenshotHasActive() -> Bool
    func screenshotPendingRequest(index: UInt) throws(HostCallError) -> NucleusTypes.ScreenshotRequest
    func screenshotPendingPath(index: UInt, capacity: UInt) throws(HostCallError) -> String
    func screenshotMarkSubmitted(requestID: UInt32) -> Bool
    func screenshotReportEvent(
        event: NucleusTypes.ScreenshotEvent
    ) throws(HostCallError) -> NucleusTypes.ScreenshotEventResult
}

extension ScreenshotService: ScreenshotHost {
    public func screenshotRequest(
        origin: ScreenshotOrigin,
        mode: ScreenshotMode,
        targetOutput: UInt32,
        destinationKind: ScreenshotDestination,
        preview: Bool,
        previewWidth: UInt32,
        previewHeight: UInt32
    ) -> UInt32 {
        request(
            origin: origin,
            mode: mode,
            targetOutput: targetOutput,
            destination: destinationKind,
            preview: preview,
            previewWidth: previewWidth,
            previewHeight: previewHeight
        ).rawValue
    }

    public func screenshotPendingCount() -> UInt {
        UInt(pendingCount())
    }

    public func screenshotHasActive() -> Bool {
        hasActiveRequests()
    }

    public func screenshotPendingRequest(index: UInt) throws(HostCallError) -> NucleusTypes.ScreenshotRequest {
        guard let pending = pendingRequest(at: Int(index)) else { throw .failed }
        return pending
    }

    public func screenshotPendingPath(index: UInt, capacity: UInt) throws(HostCallError) -> String {
        guard let path = pendingPath(at: Int(index), capacity: Int(capacity)) else { throw .failed }
        return path
    }

    public func screenshotMarkSubmitted(requestID: UInt32) -> Bool {
        markSubmitted(ScreenshotRequestID(rawValue: requestID))
    }

    public func screenshotReportEvent(
        event: NucleusTypes.ScreenshotEvent
    ) throws(HostCallError) -> NucleusTypes.ScreenshotEventResult {
        let result = report(event)
        return NucleusTypes.ScreenshotEventResult(
            overlayDirty: result.overlayDirty,
            thumbnailUpdate: NucleusTypes.ScreenshotThumbnailUpdate(rawValue: result.thumbnailUpdate.rawValue)!,
            reserved0: 0,
            reserved1: 0,
            thumbnailHandle: result.thumbnailHandle
        )
    }
}

// MARK: - Notifications

@MainActor
public protocol NotificationHost: AnyObject {
    func notificationNotify(
        appName: String?,
        replacesID: UInt32,
        summary: String?,
        body: String?,
        expireTimeout: Int32
    ) -> UInt32
    func notificationClose(id: UInt32)
    func notificationClosedFromOverlay(id: UInt32, reason: UInt32)
    func notificationCount() -> UInt
    func notificationTakeFrameRequest() -> Bool
    func notificationReset()
}

extension NotificationService: NotificationHost {
    public func notificationNotify(
        appName: String?,
        replacesID: UInt32,
        summary: String?,
        body: String?,
        expireTimeout: Int32
    ) -> UInt32 {
        notify(
            appName: appName,
            replacesID: replacesID,
            summary: summary,
            body: body,
            expireTimeout: expireTimeout
        )
    }

    public func notificationClose(id: UInt32) {
        dismiss(id: id, reason: 2)
    }

    public func notificationTakeFrameRequest() -> Bool {
        takeFrameRequest()
    }

    /// Tear down all transient shell-service state. Invoked from the shell
    /// teardown; resets the screenshot queue and the data-exchange selection
    /// state alongside notifications.
    public func notificationReset() {
        reset()
    }

    // `notificationClosedFromOverlay(id:reason:)` and `notificationCount() -> UInt`
    // are witnessed directly by NotificationService's own methods.
}
