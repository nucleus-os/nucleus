import Foundation
import NucleusTypes

public struct ScreenshotRequestID: RawRepresentable, Hashable, Sendable {
    public var rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}

public enum ScreenshotMode: UInt32, Sendable {
    case fullDisplay = 1
    case output = 2
    case region = 3
    case window = 4
}

public enum ScreenshotDestination: UInt32, Sendable {
    case file = 1
    case previewOnly = 2
    case clipboard = 3
}

public enum ScreenshotOrigin: UInt32, Sendable {
    case hotkey = 1
    case shellUI = 2
    case portal = 3
    case internalTest = 4
}

public enum ScreenshotLifecycleState: UInt32, Sendable {
    case queued = 1
    case submittedToCompositor = 2
    case readbackComplete = 3
    case saveComplete = 4
    case previewReady = 5
    case failed = 6
    case cancelled = 7
    case awaitingConsent = 8
    case awaitingPicker = 9
}

public enum ScreenshotCompletion: UInt32, Sendable {
    case previewReady = 1
    case saveComplete = 2
    case saveFailed = 3
}

public struct ScreenshotRequest: Sendable, Equatable {
    public var id: ScreenshotRequestID
    public var mode: ScreenshotMode
    public var targetOutput: UInt32
    public var destination: ScreenshotDestination
    public var origin: ScreenshotOrigin
    public var state: ScreenshotLifecycleState
    public var savePath: String
    public var preview: Bool
    public var previewWidth: UInt32
    public var previewHeight: UInt32
    public var previewReady: Bool
    public var saveComplete: Bool
    public var thumbnailHandle: UInt64
}

@MainActor
public final class ScreenshotService {
    public struct EventResult: Sendable, Equatable {
        public enum ThumbnailUpdate: UInt8, Sendable {
            case none = 0
            case set = 1
            case clear = 2
        }

        public var overlayDirty: Bool
        public var thumbnailUpdate: ThumbnailUpdate
        public var thumbnailHandle: UInt64
    }

    private let fileManager: FileManager
    private let environment: [String: String]
    private let clock: @Sendable () -> Date
    private unowned let notifications: NotificationService
    private var nextID: UInt32 = 1
    private var queue: [ScreenshotRequestID] = []
    private var inflight: Set<ScreenshotRequestID> = []
    private var requests: [ScreenshotRequestID: ScreenshotRequest] = [:]

    public init(
        notifications: NotificationService,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.notifications = notifications
        self.fileManager = fileManager
        self.environment = environment
        self.clock = clock
    }

    public func reset() {
        nextID = 1
        queue.removeAll(keepingCapacity: true)
        inflight.removeAll(keepingCapacity: true)
        requests.removeAll(keepingCapacity: true)
    }

    @discardableResult
    public func request(
        origin: ScreenshotOrigin,
        mode: ScreenshotMode = .fullDisplay,
        targetOutput: UInt32 = 0,
        destination: ScreenshotDestination = .file,
        preview: Bool = true,
        previewWidth: UInt32,
        previewHeight: UInt32
    ) -> ScreenshotRequestID {
        let id = allocateID()
        let state: ScreenshotLifecycleState = origin == .portal ? .awaitingConsent : .queued
        let request = ScreenshotRequest(
            id: id,
            mode: mode,
            targetOutput: targetOutput,
            destination: destination,
            origin: origin,
            state: state,
            savePath: makeSavePath(id: id),
            preview: preview,
            previewWidth: previewWidth,
            previewHeight: previewHeight,
            previewReady: false,
            saveComplete: false,
            thumbnailHandle: 0
        )
        requests[id] = request
        if state == .queued {
            queue.append(id)
        }
        return id
    }

    @discardableResult
    public func requestPortal(
        mode: ScreenshotMode = .fullDisplay,
        targetOutput: UInt32 = 0,
        destination: ScreenshotDestination = .file,
        preview: Bool = true,
        previewWidth: UInt32,
        previewHeight: UInt32
    ) -> ScreenshotRequestID {
        request(
            origin: .portal,
            mode: mode,
            targetOutput: targetOutput,
            destination: destination,
            preview: preview,
            previewWidth: previewWidth,
            previewHeight: previewHeight
        )
    }

    public func beginPortalPicker(_ id: ScreenshotRequestID) {
        guard var request = requests[id], request.origin == .portal, request.state == .awaitingConsent else { return }
        request.state = .awaitingPicker
        requests[id] = request
    }

    public func grantPortalConsent(_ id: ScreenshotRequestID) {
        guard var request = requests[id], request.origin == .portal else { return }
        guard request.state == .awaitingConsent || request.state == .awaitingPicker else { return }
        request.state = .queued
        requests[id] = request
        queue.append(id)
    }

    public func cancel(_ id: ScreenshotRequestID) {
        guard var request = requests[id] else { return }
        guard request.state == .queued || request.state == .awaitingConsent || request.state == .awaitingPicker else { return }
        request.state = .cancelled
        requests[id] = request
        queue.removeAll { $0 == id }
    }

    public func pendingCount() -> Int {
        compactQueue()
        return queue.count
    }

    public func hasActiveRequests() -> Bool {
        if pendingCount() > 0 { return true }
        return !inflight.isEmpty
    }

    /// The queued screenshot request at `index`, or `nil` if the index is out
    /// of range / the entry is no longer queued. Paired with `pendingPath`.
    public func pendingRequest(at index: Int) -> NucleusTypes.ScreenshotRequest? {
        compactQueue()
        guard index >= 0, index < queue.count else { return nil }
        let id = queue[index]
        guard let request = requests[id], request.state == .queued else { return nil }
        return NucleusTypes.ScreenshotRequest(
            requestId: request.id.rawValue,
            mode: NucleusTypes.ScreenshotMode(rawValue: request.mode.rawValue)!,
            targetOutput: request.targetOutput,
            destinationKind: NucleusTypes.ScreenshotDestination(rawValue: request.destination.rawValue)!,
            origin: NucleusTypes.ScreenshotOrigin(rawValue: request.origin.rawValue)!,
            previewWidth: request.previewWidth,
            previewHeight: request.previewHeight,
            preview: request.preview,
            reserved0: 0,
            reserved1: 0,
            savePathLen: UInt(request.savePath.utf8.count)
        )
    }

    /// The save path for the queued request at `index`. `capacity` is the
    /// consumer's buffer size (including the NUL terminator); a path that would
    /// overflow it fails the request (notifying the user) and returns `nil`,
    /// preserving the pre-conversion `copyPendingRequest` overflow behaviour.
    public func pendingPath(at index: Int, capacity: Int) -> String? {
        compactQueue()
        guard index >= 0, index < queue.count else { return nil }
        let id = queue[index]
        guard let request = requests[id], request.state == .queued else { return nil }
        guard request.savePath.utf8.count + 1 <= capacity else {
            failBeforeSubmission(id, path: request.savePath)
            return nil
        }
        return request.savePath
    }

    public func markSubmitted(_ id: ScreenshotRequestID) -> Bool {
        guard var request = requests[id], request.state == .queued else { return false }
        request.state = .submittedToCompositor
        requests[id] = request
        queue.removeAll { $0 == id }
        inflight.insert(id)
        return true
    }

    @discardableResult
    public func report(_ event: NucleusTypes.ScreenshotEvent) -> EventResult {
        let id = ScreenshotRequestID(rawValue: event.requestId)
        guard var request = requests[id] else {
            return EventResult(overlayDirty: false, thumbnailUpdate: .none, thumbnailHandle: 0)
        }

        let eventPath = stringFromBytes(event.savedPathPtr, Int(event.savedPathLen))
        let path = eventPath.isEmpty ? request.savePath : eventPath
        let completion = ScreenshotCompletion(rawValue: event.kind.rawValue) ?? .saveFailed

        switch completion {
        case .previewReady:
            request.previewReady = true
            if request.destination == .previewOnly || request.saveComplete {
                request.state = .previewReady
                inflight.remove(id)
            } else {
                request.state = .readbackComplete
            }
            let previous = request.thumbnailHandle
            request.thumbnailHandle = event.thumbnailHandle
            let changed = notifications.presentScreenshot(
                id: id.rawValue,
                outcome: .saved,
                path: path,
                thumbnailUpdate: event.thumbnailHandle == 0 ? .leaveExisting : .set,
                thumbnail: event.thumbnailHandle,
                timeoutMs: 3000
            )
            requests[id] = request
            return EventResult(
                overlayDirty: changed,
                thumbnailUpdate: previous == event.thumbnailHandle || event.thumbnailHandle == 0 ? .none : .set,
                thumbnailHandle: event.thumbnailHandle
            )
        case .saveComplete:
            request.saveComplete = true
            request.state = request.preview && !request.previewReady ? .saveComplete : .previewReady
            if request.state == .previewReady {
                inflight.remove(id)
            }
            let changed = notifications.presentScreenshot(
                id: id.rawValue,
                outcome: .saved,
                path: path,
                thumbnailUpdate: .leaveExisting,
                thumbnail: 0,
                timeoutMs: 3000
            )
            requests[id] = request
            return EventResult(overlayDirty: changed, thumbnailUpdate: .none, thumbnailHandle: 0)
        case .saveFailed:
            request.state = .failed
            inflight.remove(id)
            let previous = request.thumbnailHandle
            request.thumbnailHandle = 0
            let changed = notifications.presentScreenshot(
                id: id.rawValue,
                outcome: .failed,
                path: path,
                thumbnailUpdate: .clear,
                thumbnail: 0,
                timeoutMs: 5000
            )
            requests[id] = request
            return EventResult(
                overlayDirty: changed,
                thumbnailUpdate: previous == 0 ? .none : .clear,
                thumbnailHandle: previous
            )
        }
    }

    public func snapshot(_ id: ScreenshotRequestID) -> ScreenshotRequest? {
        requests[id]
    }

    private func allocateID() -> ScreenshotRequestID {
        let id = nextID
        nextID &+= 1
        if nextID == 0 { nextID = 1 }
        return ScreenshotRequestID(rawValue: id)
    }

    private func makeSavePath(id: ScreenshotRequestID) -> String {
        let date = clock()
        let seconds = UInt64(date.timeIntervalSince1970)
        let millis = UInt32((date.timeIntervalSince1970 - Double(seconds)) * 1000)
        return defaultSaveDirectory()
            .appendingPathComponent("nucleus-\(seconds)-\(millis)-\(id.rawValue).png")
            .path
    }

    private func defaultSaveDirectory() -> URL {
        if let home = environment["HOME"], !home.isEmpty {
            return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("Pictures", isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Pictures", isDirectory: true)
    }

    private func compactQueue() {
        queue.removeAll { id in
            guard let request = requests[id] else { return true }
            return request.state != .queued
        }
    }

    private func failBeforeSubmission(_ id: ScreenshotRequestID, path: String) {
        guard var request = requests[id] else { return }
        request.state = .failed
        requests[id] = request
        queue.removeAll { $0 == id }
        _ = notifications.presentScreenshot(
            id: id.rawValue,
            outcome: .failed,
            path: path,
            thumbnailUpdate: .clear,
            thumbnail: 0,
            timeoutMs: 5000
        )
    }
}
