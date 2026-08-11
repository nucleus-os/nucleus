import Foundation
import Glibc
import NucleusAndroidRuntimeCore
import NucleusIPCTransport
import Synchronization

package enum AndroidRuntimeBridgeProtocol {
    package static let maximumPacketBytes = 256 * 1_024
    package static let maximumActivities = 16_384
    package static let androidUserID: UInt32 = 2_900
}

package enum AndroidRuntimeBridgeMessageKind:
    String, Codable, Equatable, Sendable
{
    case bridgeHello
    case brokerHello
    case runtimeState
    case iconAsset
    case replaceActivities
    case replacePackageActivities
    case inputState
    case inputEvent
    case cursorShape
    case launchActivity
    case launchResult
    case closePresentation
    case taskChanged
    case taskVanished
}

package struct AndroidActivityLaunchCommand: Codable, Equatable, Sendable {
    package let requestID: String
    package let presentationID: UInt64
    package let packageName: String
    package let activityName: String
    package let activationToken: String?

    package init(
        requestID: String,
        presentationID: UInt64,
        packageName: String,
        activityName: String,
        activationToken: String?
    ) throws {
        self.requestID = requestID
        self.presentationID = presentationID
        self.packageName = packageName
        self.activityName = activityName
        self.activationToken = activationToken
        try validate()
    }

    package func validate() throws {
        guard AndroidRuntimeBridgeEnvelope.validIdentifier(requestID, maximumBytes: 128),
            presentationID > 0,
            AndroidRuntimeBridgeEnvelope.validActivityField(packageName),
            AndroidRuntimeBridgeEnvelope.validActivityField(activityName),
            activationToken.map({
                AndroidRuntimeBridgeEnvelope.validIdentifier($0, maximumBytes: 4_096)
            }) ?? true
        else {
            throw AndroidRuntimeFailure("invalid Android activity launch command")
        }
    }
}

package enum AndroidActivityLaunchOutcome: String, Codable, Equatable, Sendable {
    case created
    case activatedExistingPresentation
    case failed
}

package struct AndroidActivityLaunchResult: Codable, Equatable, Sendable {
    package let requestID: String
    package let requestedPresentationID: UInt64
    package let presentationID: UInt64?
    package let displayID: Int32?
    package let taskID: Int32?
    package let outcome: AndroidActivityLaunchOutcome
    package let failure: String?

    package init(
        requestID: String,
        requestedPresentationID: UInt64,
        presentationID: UInt64?,
        displayID: Int32?,
        taskID: Int32?,
        outcome: AndroidActivityLaunchOutcome,
        failure: String? = nil
    ) throws {
        self.requestID = requestID
        self.requestedPresentationID = requestedPresentationID
        self.presentationID = presentationID
        self.displayID = displayID
        self.taskID = taskID
        self.outcome = outcome
        self.failure = failure
        try validate()
    }

    package func validate() throws {
        guard AndroidRuntimeBridgeEnvelope.validIdentifier(requestID, maximumBytes: 128),
            requestedPresentationID > 0,
            presentationID.map({ $0 > 0 }) ?? true,
            displayID.map({ $0 >= 0 }) ?? true,
            taskID.map({ $0 >= 0 }) ?? true,
            failure?.utf8.count ?? 0 <= 16_384,
            !(failure?.contains("\0") ?? false)
        else {
            throw AndroidRuntimeFailure("invalid Android activity launch result")
        }
        switch outcome {
        case .created, .activatedExistingPresentation:
            guard presentationID != nil,
                displayID != nil,
                taskID != nil,
                failure == nil
            else {
                throw AndroidRuntimeFailure("invalid successful Android activity launch result")
            }
        case .failed:
            guard presentationID == nil,
                displayID == nil,
                taskID == nil,
                failure?.isEmpty == false
            else {
                throw AndroidRuntimeFailure("invalid failed Android activity launch result")
            }
        }
    }
}

package struct AndroidPresentationCloseCommand: Codable, Equatable, Sendable {
    package let presentationID: UInt64

    package init(presentationID: UInt64) throws {
        self.presentationID = presentationID
        try validate()
    }

    package func validate() throws {
        guard presentationID > 0 else {
            throw AndroidRuntimeFailure("invalid Android presentation close command")
        }
    }
}

package struct AndroidTaskState: Codable, Equatable, Sendable {
    package let presentationID: UInt64
    package let displayID: Int32
    package let taskID: Int32
    package let packageName: String
    package let activityName: String

    package init(
        presentationID: UInt64,
        displayID: Int32,
        taskID: Int32,
        packageName: String,
        activityName: String
    ) throws {
        self.presentationID = presentationID
        self.displayID = displayID
        self.taskID = taskID
        self.packageName = packageName
        self.activityName = activityName
        try validate()
    }

    package func validate() throws {
        guard presentationID > 0,
            displayID >= 0,
            taskID >= 0,
            AndroidRuntimeBridgeEnvelope.validActivityField(packageName),
            AndroidRuntimeBridgeEnvelope.validActivityField(activityName)
        else {
            throw AndroidRuntimeFailure("invalid Android task state")
        }
    }
}

package struct AndroidTaskVanished: Codable, Equatable, Sendable {
    package let presentationID: UInt64
    package let taskID: Int32

    package init(presentationID: UInt64, taskID: Int32) throws {
        self.presentationID = presentationID
        self.taskID = taskID
        try validate()
    }

    package func validate() throws {
        guard presentationID > 0, taskID >= 0 else {
            throw AndroidRuntimeFailure("invalid vanished Android task")
        }
    }
}

package enum AndroidInputAction: String, Codable, Equatable, Sendable {
    case pointerMotion
    case pointerButton
    case pointerScroll
    case key
}

package struct AndroidInputEvent: Codable, Equatable, Sendable {
    package let displayID: Int32
    package let eventTimeNanoseconds: UInt64
    package let x: Double?
    package let y: Double?
    package let button: UInt32?
    package let keyCode: UInt32?
    package let pressed: Bool?
    package let scrollX: Double?
    package let scrollY: Double?
    package let action: AndroidInputAction

    package init(
        displayID: Int32,
        eventTimeNanoseconds: UInt64,
        x: Double? = nil,
        y: Double? = nil,
        button: UInt32? = nil,
        keyCode: UInt32? = nil,
        pressed: Bool? = nil,
        scrollX: Double? = nil,
        scrollY: Double? = nil,
        action: AndroidInputAction
    ) throws {
        self.displayID = displayID
        self.eventTimeNanoseconds = eventTimeNanoseconds
        self.x = x
        self.y = y
        self.button = button
        self.keyCode = keyCode
        self.pressed = pressed
        self.scrollX = scrollX
        self.scrollY = scrollY
        self.action = action
        try validate()
    }

    package func validate() throws {
        guard displayID >= 0,
            x?.isFinite ?? true,
            y?.isFinite ?? true,
            (x ?? 0) >= 0, (y ?? 0) >= 0,
            (x ?? 0) <= 65_536, (y ?? 0) <= 65_536,
            scrollX?.isFinite ?? true,
            scrollY?.isFinite ?? true
        else {
            throw AndroidRuntimeFailure(
                "Android input event is invalid")
        }
        switch action {
        case .pointerMotion:
            guard x != nil, y != nil,
                button == nil, keyCode == nil, pressed == nil,
                scrollX == nil, scrollY == nil
            else {
                throw AndroidRuntimeFailure(
                    "Android pointer motion has invalid fields")
            }
        case .pointerButton:
            guard let button,
                button == 0x110 || button == 0x111
                    || button == 0x112 || button == 0x113
                    || button == 0x114,
                x != nil, y != nil,
                keyCode == nil, pressed != nil,
                scrollX == nil, scrollY == nil
            else {
                throw AndroidRuntimeFailure(
                    "Android pointer button is invalid")
            }
        case .pointerScroll:
            guard x != nil, y != nil,
                button == nil, keyCode == nil, pressed == nil,
                scrollX != nil || scrollY != nil
            else {
                throw AndroidRuntimeFailure(
                    "Android pointer scroll is invalid")
            }
        case .key:
            guard x == nil, y == nil, button == nil,
                let keyCode, keyCode <= 0x2ff,
                pressed != nil,
                scrollX == nil, scrollY == nil
            else {
                throw AndroidRuntimeFailure(
                    "Android keyboard event is invalid")
            }
        }
    }
}

package struct AndroidCursorShapeUpdate: Codable, Equatable, Sendable {
    package let displayID: Int32
    package let pointerIconType: Int32

    package init(displayID: Int32, pointerIconType: Int32) throws {
        self.displayID = displayID
        self.pointerIconType = pointerIconType
        try validate()
    }

    package func validate() throws {
        guard displayID >= 0,
            pointerIconType >= -1,
            pointerIconType <= 10_000
        else {
            throw AndroidRuntimeFailure(
                "Android cursor-shape update is invalid")
        }
    }
}

package struct AndroidRuntimeBridgeActivity:
    Codable, Equatable, Sendable
{
    package let packageName: String
    package let activityName: String
    package let label: String
    package let categories: [String]?
    package let iconDigest: String?

    package init(
        packageName: String,
        activityName: String,
        label: String,
        categories: [String]? = nil,
        iconDigest: String? = nil
    ) {
        self.packageName = packageName
        self.activityName = activityName
        self.label = label
        self.categories = categories
        self.iconDigest = iconDigest
    }
}

package struct AndroidRuntimeBridgeIconAsset:
    Codable, Equatable, Sendable
{
    package let digest: String
    package let bytes: Data

    package init(digest: String, bytes: Data) {
        self.digest = digest
        self.bytes = bytes
    }
}

package struct AndroidRuntimeBridgeEnvelope:
    Codable, Equatable, Sendable
{
    package let kind: AndroidRuntimeBridgeMessageKind
    package let generation: String?
    package let userUnlocked: Bool?
    package let userSerial: Int64?
    package let packageName: String?
    package let activities: [AndroidRuntimeBridgeActivity]?
    package let iconAsset: AndroidRuntimeBridgeIconAsset?
    package let inputReady: Bool?
    package let inputError: String?
    package let inputEvent: AndroidInputEvent?
    package let cursorShape: AndroidCursorShapeUpdate?
    package let activityLaunch: AndroidActivityLaunchCommand?
    package let activityLaunchResult: AndroidActivityLaunchResult?
    package let presentationClose: AndroidPresentationCloseCommand?
    package let taskState: AndroidTaskState?
    package let vanishedTask: AndroidTaskVanished?

    package init(
        kind: AndroidRuntimeBridgeMessageKind,
        generation: String? = nil,
        userUnlocked: Bool? = nil,
        userSerial: Int64? = nil,
        packageName: String? = nil,
        activities: [AndroidRuntimeBridgeActivity]? = nil,
        iconAsset: AndroidRuntimeBridgeIconAsset? = nil,
        inputReady: Bool? = nil,
        inputError: String? = nil,
        inputEvent: AndroidInputEvent? = nil,
        cursorShape: AndroidCursorShapeUpdate? = nil,
        activityLaunch: AndroidActivityLaunchCommand? = nil,
        activityLaunchResult: AndroidActivityLaunchResult? = nil,
        presentationClose: AndroidPresentationCloseCommand? = nil,
        taskState: AndroidTaskState? = nil,
        vanishedTask: AndroidTaskVanished? = nil
    ) throws {
        self.kind = kind
        self.generation = generation
        self.userUnlocked = userUnlocked
        self.userSerial = userSerial
        self.packageName = packageName
        self.activities = activities
        self.iconAsset = iconAsset
        self.inputReady = inputReady
        self.inputError = inputError
        self.inputEvent = inputEvent
        self.cursorShape = cursorShape
        self.activityLaunch = activityLaunch
        self.activityLaunchResult = activityLaunchResult
        self.presentationClose = presentationClose
        self.taskState = taskState
        self.vanishedTask = vanishedTask
        try validate()
    }

    package func validate() throws {
        if let generation {
            guard !generation.isEmpty,
                generation.utf8.count <= 128,
                generation.utf8.allSatisfy({
                    $0 >= Character("a").asciiValue!
                        && $0 <= Character("z").asciiValue!
                        || $0 >= Character("0").asciiValue!
                            && $0 <= Character("9").asciiValue!
                        || $0 == Character("-").asciiValue!
                })
            else {
                throw AndroidRuntimeFailure(
                    "invalid Android bridge generation")
            }
        }
        guard
            (activities?.count ?? 0)
                <= AndroidRuntimeBridgeProtocol.maximumActivities
        else {
            throw AndroidRuntimeFailure(
                "Android bridge activity snapshot is oversized")
        }
        if let packageName, !Self.validActivityField(packageName) {
            throw AndroidRuntimeFailure(
                "Android bridge package identity is invalid")
        }
        guard
            activities?.allSatisfy({
                Self.validActivityField($0.packageName)
                    && Self.validActivityField($0.activityName)
                    && Self.validActivityField($0.label)
            }) ?? true
        else {
            throw AndroidRuntimeFailure(
                "Android bridge activity metadata is invalid")
        }
        guard
            activities.map({ activities in
                Set(
                    activities.map {
                        "\($0.packageName)\u{0}\($0.activityName)"
                    }
                ).count == activities.count
            }) ?? true
        else {
            throw AndroidRuntimeFailure(
                "Android bridge activity snapshot contains duplicate components")
        }
        guard
            activities?.allSatisfy({ activity in
                (activity.categories?.count ?? 0) <= 64
                    && (activity.categories?.allSatisfy({
                        Self.validActivityField($0)
                    }) ?? true)
                    && (activity.iconDigest.map(Self.validDigest) ?? true)
            }) ?? true
        else {
            throw AndroidRuntimeFailure(
                "Android bridge activity catalog metadata is invalid")
        }
        if let iconAsset {
            guard Self.validDigest(iconAsset.digest),
                !iconAsset.bytes.isEmpty,
                iconAsset.bytes.count <= 128 * 1_024,
                iconAsset.bytes.starts(with: [
                    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
                ])
            else {
                throw AndroidRuntimeFailure(
                    "Android bridge icon asset is invalid")
            }
        }
        guard inputError?.utf8.count ?? 0 <= 16_384,
            !(inputError?.contains("\0") ?? false)
        else {
            throw AndroidRuntimeFailure(
                "Android input-service error is invalid")
        }
        switch kind {
        case .bridgeHello:
            guard generation == nil,
                userUnlocked == nil,
                userSerial == nil,
                packageName == nil,
                activities == nil,
                iconAsset == nil,
                inputReady == nil,
                inputError == nil,
                inputEvent == nil,
                cursorShape == nil,
                activityLaunch == nil,
                activityLaunchResult == nil,
                presentationClose == nil,
                taskState == nil,
                vanishedTask == nil
            else {
                throw AndroidRuntimeFailure(
                    "invalid Android bridge hello")
            }
        case .brokerHello:
            guard generation != nil,
                userUnlocked == nil,
                userSerial == nil,
                packageName == nil,
                activities == nil,
                iconAsset == nil,
                inputReady == nil,
                inputError == nil,
                inputEvent == nil,
                cursorShape == nil,
                activityLaunch == nil,
                activityLaunchResult == nil,
                presentationClose == nil,
                taskState == nil,
                vanishedTask == nil
            else {
                throw AndroidRuntimeFailure(
                    "invalid Android broker hello")
            }
        case .runtimeState:
            guard generation != nil,
                userUnlocked != nil,
                userSerial != nil,
                packageName == nil,
                activities == nil,
                iconAsset == nil,
                inputReady == nil,
                inputError == nil,
                inputEvent == nil,
                cursorShape == nil,
                activityLaunch == nil,
                activityLaunchResult == nil,
                presentationClose == nil,
                taskState == nil,
                vanishedTask == nil
            else {
                throw AndroidRuntimeFailure(
                    "invalid Android bridge runtime state")
            }
        case .iconAsset:
            guard generation != nil,
                userUnlocked == true,
                userSerial != nil,
                packageName == nil,
                activities == nil,
                iconAsset != nil,
                inputReady == nil,
                inputError == nil,
                inputEvent == nil,
                cursorShape == nil,
                activityLaunch == nil,
                activityLaunchResult == nil,
                presentationClose == nil,
                taskState == nil,
                vanishedTask == nil
            else {
                throw AndroidRuntimeFailure(
                    "invalid Android icon asset")
            }
        case .replaceActivities:
            guard generation != nil,
                userUnlocked == true,
                userSerial != nil,
                packageName == nil,
                activities != nil,
                iconAsset == nil,
                inputReady == nil,
                inputError == nil,
                inputEvent == nil,
                cursorShape == nil,
                activityLaunch == nil,
                activityLaunchResult == nil,
                presentationClose == nil,
                taskState == nil,
                vanishedTask == nil
            else {
                throw AndroidRuntimeFailure(
                    "invalid Android activity snapshot")
            }
        case .replacePackageActivities:
            guard generation != nil,
                userUnlocked == true,
                userSerial != nil,
                packageName != nil,
                activities != nil,
                iconAsset == nil,
                inputReady == nil,
                inputError == nil,
                inputEvent == nil,
                cursorShape == nil,
                activityLaunch == nil,
                activityLaunchResult == nil,
                presentationClose == nil,
                taskState == nil,
                vanishedTask == nil,
                activities?.allSatisfy({ $0.packageName == packageName }) == true
            else {
                throw AndroidRuntimeFailure(
                    "invalid Android package activity replacement")
            }
        case .inputState:
            guard generation != nil,
                userUnlocked == nil,
                userSerial == nil,
                packageName == nil,
                activities == nil,
                iconAsset == nil,
                let inputReady,
                inputReady ? inputError == nil : inputError?.isEmpty == false,
                inputEvent == nil,
                cursorShape == nil,
                activityLaunch == nil,
                activityLaunchResult == nil,
                presentationClose == nil,
                taskState == nil,
                vanishedTask == nil
            else {
                throw AndroidRuntimeFailure(
                    "invalid Android input-service state")
            }
        case .inputEvent:
            guard generation != nil,
                userUnlocked == nil,
                userSerial == nil,
                packageName == nil,
                activities == nil,
                iconAsset == nil,
                inputReady == nil,
                inputError == nil,
                let inputEvent,
                cursorShape == nil,
                activityLaunch == nil,
                activityLaunchResult == nil,
                presentationClose == nil,
                taskState == nil,
                vanishedTask == nil
            else {
                throw AndroidRuntimeFailure(
                    "invalid Android input event")
            }
            try inputEvent.validate()
        case .cursorShape:
            guard generation != nil,
                userUnlocked == nil,
                userSerial == nil,
                packageName == nil,
                activities == nil,
                iconAsset == nil,
                inputReady == nil,
                inputError == nil,
                inputEvent == nil,
                let cursorShape,
                activityLaunch == nil,
                activityLaunchResult == nil,
                presentationClose == nil,
                taskState == nil,
                vanishedTask == nil
            else {
                throw AndroidRuntimeFailure(
                    "invalid Android cursor-shape update")
            }
            try cursorShape.validate()
        case .launchActivity:
            guard generation != nil,
                userUnlocked == nil,
                userSerial == nil,
                packageName == nil,
                activities == nil,
                iconAsset == nil,
                inputReady == nil,
                inputError == nil,
                inputEvent == nil,
                cursorShape == nil,
                let activityLaunch,
                activityLaunchResult == nil,
                presentationClose == nil,
                taskState == nil,
                vanishedTask == nil
            else {
                throw AndroidRuntimeFailure(
                    "invalid Android activity launch command")
            }
            try activityLaunch.validate()
        case .launchResult:
            guard generation != nil,
                userUnlocked == nil,
                userSerial == nil,
                packageName == nil,
                activities == nil,
                iconAsset == nil,
                inputReady == nil,
                inputError == nil,
                inputEvent == nil,
                cursorShape == nil,
                activityLaunch == nil,
                let activityLaunchResult,
                presentationClose == nil,
                taskState == nil,
                vanishedTask == nil
            else {
                throw AndroidRuntimeFailure(
                    "invalid Android activity launch result")
            }
            try activityLaunchResult.validate()
        case .closePresentation:
            guard generation != nil,
                userUnlocked == nil,
                userSerial == nil,
                packageName == nil,
                activities == nil,
                iconAsset == nil,
                inputReady == nil,
                inputError == nil,
                inputEvent == nil,
                cursorShape == nil,
                activityLaunch == nil,
                activityLaunchResult == nil,
                let presentationClose,
                taskState == nil,
                vanishedTask == nil
            else {
                throw AndroidRuntimeFailure(
                    "invalid Android presentation close command")
            }
            try presentationClose.validate()
        case .taskChanged:
            guard generation != nil,
                userUnlocked == nil,
                userSerial == nil,
                packageName == nil,
                activities == nil,
                iconAsset == nil,
                inputReady == nil,
                inputError == nil,
                inputEvent == nil,
                cursorShape == nil,
                activityLaunch == nil,
                activityLaunchResult == nil,
                presentationClose == nil,
                taskState != nil,
                vanishedTask == nil
            else {
                throw AndroidRuntimeFailure(
                    "invalid Android task-state update")
            }
            try taskState?.validate()
        case .taskVanished:
            guard generation != nil,
                userUnlocked == nil,
                userSerial == nil,
                packageName == nil,
                activities == nil,
                iconAsset == nil,
                inputReady == nil,
                inputError == nil,
                inputEvent == nil,
                cursorShape == nil,
                activityLaunch == nil,
                activityLaunchResult == nil,
                presentationClose == nil,
                taskState == nil,
                vanishedTask != nil
            else {
                throw AndroidRuntimeFailure(
                    "invalid vanished Android task update")
            }
            try vanishedTask?.validate()
        }
    }

    fileprivate static func validActivityField(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 4_096
            && !value.contains("\0")
    }

    fileprivate static func validIdentifier(
        _ value: String,
        maximumBytes: Int
    ) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumBytes
            && !value.contains("\0")
    }

    private static func validDigest(_ value: String) -> Bool {
        value.count == 64
            && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}

package enum AndroidRuntimeBridgeEvent: Equatable, Sendable {
    case connected(generation: String)
    case inputReady(generation: String)
    case inputFailed(generation: String, error: String)
    case userUnlocked(generation: String, userSerial: Int64)
    case userLocked(generation: String, userSerial: Int64)
    case activitiesReplaced(
        generation: String,
        userSerial: Int64,
        activities: [AndroidRuntimeBridgeActivity])
    case packageActivitiesReplaced(
        generation: String,
        userSerial: Int64,
        packageName: String,
        activities: [AndroidRuntimeBridgeActivity])
    case iconAsset(
        generation: String,
        userSerial: Int64,
        asset: AndroidRuntimeBridgeIconAsset)
    case cursorShapeChanged(
        generation: String,
        update: AndroidCursorShapeUpdate)
    case taskChanged(generation: String, task: AndroidTaskState)
    case taskVanished(generation: String, task: AndroidTaskVanished)
    case disconnected(generation: String)
}

package final class AndroidRuntimeBridgeServer: @unchecked Sendable {
    private struct PendingLaunch {
        var presentationID: UInt64
        var continuation: CheckedContinuation<AndroidActivityLaunchResult, Never>
    }

    private struct ConnectionState {
        var connection: PacketConnection?
        var pendingLaunches: [String: PendingLaunch] = [:]
    }

    private let listener: PacketListener
    private let expectedUserID: UInt32
    package let generation: String
    private let state = Mutex(ConnectionState())

    package init(
        socketPath: URL,
        expectedUserID: UInt32,
        generation: String = UUID().uuidString.lowercased()
    ) throws {
        self.expectedUserID = expectedUserID
        self.generation = generation
        listener = try PacketListener(
            path: socketPath.path,
            mode: 0o666,
            nonblocking: true)
    }

    package func send(_ inputEvent: AndroidInputEvent) throws {
        try state.withLock { state in
            guard let connection = state.connection else {
                throw AndroidRuntimeFailure(
                    "Android runtime bridge is not connected")
            }
            try send(
                AndroidRuntimeBridgeEnvelope(
                    kind: .inputEvent,
                    generation: generation,
                    inputEvent: inputEvent),
                over: connection)
        }
    }

    package func close(presentationID: UInt64) throws {
        let command = try AndroidPresentationCloseCommand(
            presentationID: presentationID)
        try state.withLock { state in
            guard let connection = state.connection else {
                throw AndroidRuntimeFailure(
                    "Android runtime bridge is not connected")
            }
            try send(
                AndroidRuntimeBridgeEnvelope(
                    kind: .closePresentation,
                    generation: generation,
                    presentationClose: command),
                over: connection)
        }
    }

    package func launch(
        presentationID: UInt64,
        packageName: String,
        activityName: String,
        activationToken: String?
    ) async -> AndroidActivityLaunchResult {
        let requestID = UUID().uuidString.lowercased()
        let command: AndroidActivityLaunchCommand
        do {
            command = try AndroidActivityLaunchCommand(
                requestID: requestID,
                presentationID: presentationID,
                packageName: packageName,
                activityName: activityName,
                activationToken: activationToken)
        } catch {
            return failedLaunch(
                requestID: requestID,
                presentationID: presentationID,
                message: String(describing: error))
        }
        return await waitForLaunch(command)
    }

    private func waitForLaunch(
        _ command: AndroidActivityLaunchCommand
    ) async -> AndroidActivityLaunchResult {
        await withCheckedContinuation { continuation in
            do {
                try state.withLock { state in
                    guard let connection = state.connection else {
                        throw AndroidRuntimeFailure(
                            "Android runtime bridge is not connected")
                    }
                    state.pendingLaunches[command.requestID] = PendingLaunch(
                        presentationID: command.presentationID,
                        continuation: continuation)
                    do {
                        try send(
                            AndroidRuntimeBridgeEnvelope(
                                kind: .launchActivity,
                                generation: generation,
                                activityLaunch: command),
                            over: connection)
                    } catch {
                        state.pendingLaunches.removeValue(
                            forKey: command.requestID)
                        throw error
                    }
                }
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(20))
                    guard let self else { return }
                    self.completeLaunch(
                        self.failedLaunch(
                            requestID: command.requestID,
                            presentationID: command.presentationID,
                            message: "Android activity launch timed out"))
                }
            } catch {
                continuation.resume(
                    returning: failedLaunch(
                        requestID: command.requestID,
                        presentationID: command.presentationID,
                        message: String(describing: error)))
            }
        }
    }

    @discardableResult
    private func completeLaunch(_ result: AndroidActivityLaunchResult) -> Bool {
        let continuation = state.withLock { state in
            guard
                state.pendingLaunches[result.requestID]?.presentationID
                    == result.requestedPresentationID
            else { return nil }
            state.pendingLaunches.removeValue(forKey: result.requestID)
        }
        continuation?.continuation.resume(returning: result)
        return continuation != nil
    }

    private func failedLaunch(
        requestID: String,
        presentationID: UInt64,
        message: String
    ) -> AndroidActivityLaunchResult {
        try! AndroidActivityLaunchResult(
            requestID: requestID,
            requestedPresentationID: presentationID,
            presentationID: nil,
            displayID: nil,
            taskID: nil,
            outcome: .failed,
            failure: String(message.prefix(16_384)))
    }

    package func run(
        onEvent:
            @escaping @Sendable (
                AndroidRuntimeBridgeEvent
            ) async -> Void
    ) async throws {
        while true {
            try Task.checkCancellation()
            guard try waitUntilReadable(listener.fileDescriptor) else {
                continue
            }
            let connection: PacketConnection
            do {
                connection = try listener.accept(
                    expectedUserID: expectedUserID)
            } catch let error as IPCTransportError {
                if case .systemCall(_, let code) = error,
                    code == EAGAIN || code == EWOULDBLOCK
                {
                    continue
                }
                throw error
            }
            do {
                try await serve(connection, onEvent: onEvent)
            } catch is CancellationError {
                throw CancellationError()
            } catch let failure as AndroidRuntimeFailure {
                throw failure
            } catch {
                await onEvent(.disconnected(generation: generation))
            }
        }
    }

    private func serve(
        _ connection: PacketConnection,
        onEvent:
            @escaping @Sendable (
                AndroidRuntimeBridgeEvent
            ) async -> Void
    ) async throws {
        let hello = try receive(connection)
        guard hello.kind == .bridgeHello else {
            throw AndroidRuntimeFailure(
                "Android bridge did not begin with hello")
        }
        state.withLock { $0.connection = connection }
        defer {
            let pending = state.withLock { state in
                guard state.connection === connection else { return [] }
                state.connection = nil
                let pending = Array(state.pendingLaunches)
                state.pendingLaunches.removeAll()
                return pending
            }
            for (requestID, pendingLaunch) in pending {
                pendingLaunch.continuation.resume(
                    returning: failedLaunch(
                        requestID: requestID,
                        presentationID: pendingLaunch.presentationID,
                        message: "Android runtime bridge disconnected"))
            }
        }
        try send(
            AndroidRuntimeBridgeEnvelope(
                kind: .brokerHello,
                generation: generation),
            over: connection)
        await onEvent(.connected(generation: generation))
        var inputStatePublished = false
        var unlockedUserSerial: Int64?
        while true {
            try Task.checkCancellation()
            guard try waitUntilReadable(connection.fileDescriptor) else {
                continue
            }
            let envelope = try receive(connection)
            guard envelope.generation == generation else {
                throw AndroidRuntimeFailure(
                    "Android bridge sent a stale generation")
            }
            switch envelope.kind {
            case .inputState:
                guard !inputStatePublished,
                    let ready = envelope.inputReady
                else {
                    throw AndroidRuntimeFailure(
                        "Android bridge duplicated input-service state")
                }
                inputStatePublished = true
                if ready {
                    await onEvent(.inputReady(generation: generation))
                } else {
                    let error =
                        envelope.inputError
                        ?? "Android omitted the input-service error"
                    await onEvent(
                        .inputFailed(
                            generation: generation,
                            error: error))
                }
            case .runtimeState:
                guard inputStatePublished else {
                    throw AndroidRuntimeFailure(
                        "Android bridge published runtime state before input")
                }
                if envelope.userUnlocked == true {
                    guard let serial = envelope.userSerial else {
                        throw AndroidRuntimeFailure(
                            "Android bridge omitted unlocked user identity")
                    }
                    if unlockedUserSerial != serial {
                        unlockedUserSerial = serial
                        await onEvent(
                            .userUnlocked(
                                generation: generation,
                                userSerial: serial))
                    }
                } else if let serial = unlockedUserSerial {
                    unlockedUserSerial = nil
                    await onEvent(
                        .userLocked(
                            generation: generation,
                            userSerial: serial))
                }
            case .replaceActivities:
                guard let serial = unlockedUserSerial,
                    envelope.userSerial == serial,
                    let activities = envelope.activities
                else {
                    throw AndroidRuntimeFailure(
                        "Android bridge published activities before unlock")
                }
                await onEvent(
                    .activitiesReplaced(
                        generation: generation,
                        userSerial: serial,
                        activities: activities))
            case .replacePackageActivities:
                guard let serial = unlockedUserSerial,
                    envelope.userSerial == serial,
                    let packageName = envelope.packageName,
                    let activities = envelope.activities
                else {
                    throw AndroidRuntimeFailure(
                        "Android bridge published package activities before unlock")
                }
                await onEvent(
                    .packageActivitiesReplaced(
                        generation: generation,
                        userSerial: serial,
                        packageName: packageName,
                        activities: activities))
            case .iconAsset:
                guard let serial = unlockedUserSerial,
                    envelope.userSerial == serial,
                    let asset = envelope.iconAsset
                else {
                    throw AndroidRuntimeFailure(
                        "Android bridge published an icon before unlock")
                }
                await onEvent(
                    .iconAsset(
                        generation: generation,
                        userSerial: serial,
                        asset: asset))
            case .cursorShape:
                guard let update = envelope.cursorShape else {
                    throw AndroidRuntimeFailure(
                        "Android bridge omitted cursor-shape update")
                }
                await onEvent(
                    .cursorShapeChanged(
                        generation: generation,
                        update: update))
            case .launchResult:
                guard let result = envelope.activityLaunchResult else {
                    throw AndroidRuntimeFailure(
                        "Android bridge omitted activity launch result")
                }
                guard completeLaunch(result) else {
                    throw AndroidRuntimeFailure(
                        "Android bridge replied to an unknown activity launch")
                }
            case .taskChanged:
                guard let task = envelope.taskState else {
                    throw AndroidRuntimeFailure(
                        "Android bridge omitted task state")
                }
                await onEvent(
                    .taskChanged(
                        generation: generation,
                        task: task))
            case .taskVanished:
                guard let task = envelope.vanishedTask else {
                    throw AndroidRuntimeFailure(
                        "Android bridge omitted vanished task")
                }
                await onEvent(
                    .taskVanished(
                        generation: generation,
                        task: task))
            case .bridgeHello, .brokerHello, .inputEvent, .launchActivity,
                .closePresentation:
                throw AndroidRuntimeFailure(
                    "unexpected Android bridge handshake message")
            }
        }
    }

    private func send(
        _ envelope: AndroidRuntimeBridgeEnvelope,
        over connection: PacketConnection
    ) throws {
        let bytes = try JSONEncoder().encode(envelope)
        guard
            bytes.count
                <= AndroidRuntimeBridgeProtocol.maximumPacketBytes
        else {
            throw AndroidRuntimeFailure(
                "Android bridge packet is oversized")
        }
        try connection.send(bytes)
    }

    private func receive(
        _ connection: PacketConnection
    ) throws -> AndroidRuntimeBridgeEnvelope {
        let packet = try connection.receive(
            maximumBytes:
                AndroidRuntimeBridgeProtocol.maximumPacketBytes,
            maximumDescriptors: 0)
        guard packet.descriptors.isEmpty else {
            throw AndroidRuntimeFailure(
                "Android bridge packets cannot carry descriptors")
        }
        let envelope = try JSONDecoder().decode(
            AndroidRuntimeBridgeEnvelope.self,
            from: Data(packet.bytes))
        try envelope.validate()
        return envelope
    }

    private func waitUntilReadable(
        _ descriptor: Int32
    ) throws -> Bool {
        var pollDescriptor = pollfd(
            fd: descriptor,
            events: Int16(POLLIN),
            revents: 0)
        let result = unsafe poll(&pollDescriptor, 1, 250)
        if result < 0, errno != EINTR {
            throw IPCTransportError.systemCall(
                operation: "poll(Android bridge)",
                errno: errno)
        }
        return result > 0
    }
}

private enum AndroidDisplayInteractionKind:
    String, Codable, Sendable
{
    case inputEvent
    case cursorShape
}

private struct AndroidDisplayInteractionEnvelope:
    Codable, Sendable
{
    let kind: AndroidDisplayInteractionKind
    let inputEvent: AndroidInputEvent?
    let cursorShape: AndroidCursorShapeUpdate?

    init(inputEvent: AndroidInputEvent) {
        kind = .inputEvent
        self.inputEvent = inputEvent
        cursorShape = nil
    }

    init(cursorShape: AndroidCursorShapeUpdate) {
        kind = .cursorShape
        inputEvent = nil
        self.cursorShape = cursorShape
    }
}

package enum AndroidDisplayInteractionEvent: Sendable {
    case input(AndroidInputEvent)
}

package final class AndroidDisplayInteractionServer: @unchecked Sendable {
    private struct State {
        var connection: PacketConnection?
        var latestCursorShapeByDisplay: [Int32: AndroidCursorShapeUpdate] = [:]
    }

    private let listener: PacketListener
    private let expectedUserID: UInt32
    private let state = Mutex(State())

    package init(socketPath: URL, expectedUserID: UInt32) throws {
        self.expectedUserID = expectedUserID
        listener = try PacketListener(
            path: socketPath.path,
            mode: 0o600,
            nonblocking: true)
    }

    package func run(
        onEvent:
            @escaping @Sendable (
                AndroidDisplayInteractionEvent
            ) throws -> Void
    ) async throws {
        while true {
            try Task.checkCancellation()
            guard try waitUntilReadable(listener.fileDescriptor) else {
                continue
            }
            let connection: PacketConnection
            do {
                connection = try listener.accept(
                    expectedUserID: expectedUserID)
            } catch let error as IPCTransportError {
                if case .systemCall(_, let code) = error,
                    code == EAGAIN || code == EWOULDBLOCK
                {
                    continue
                }
                throw error
            }
            do {
                try state.withLock { state in
                    state.connection = connection
                    for update in state.latestCursorShapeByDisplay
                        .values.sorted(by: {
                            $0.displayID < $1.displayID
                        })
                    {
                        try connection.send(
                            try Self.encode(cursorShape: update))
                    }
                }
                defer {
                    state.withLock { state in
                        if state.connection === connection {
                            state.connection = nil
                        }
                    }
                }
                while true {
                    try Task.checkCancellation()
                    guard try waitUntilReadable(connection.fileDescriptor) else {
                        continue
                    }
                    do {
                        let packet = try connection.receive(
                            maximumBytes:
                                AndroidRuntimeBridgeProtocol.maximumPacketBytes,
                            maximumDescriptors: 0)
                        guard packet.descriptors.isEmpty else {
                            throw AndroidRuntimeFailure(
                                "Android display interaction packets cannot carry descriptors")
                        }
                        let envelope = try JSONDecoder().decode(
                            AndroidDisplayInteractionEnvelope.self,
                            from: Data(packet.bytes))
                        switch envelope.kind {
                        case .inputEvent:
                            guard let event = envelope.inputEvent,
                                envelope.cursorShape == nil
                            else {
                                throw AndroidRuntimeFailure(
                                    "invalid Android display input")
                            }
                            try event.validate()
                            try onEvent(.input(event))
                        case .cursorShape:
                            throw AndroidRuntimeFailure(
                                "Android display host sent a cursor shape")
                        }
                    } catch let error as IPCTransportError {
                        if case .systemCall(_, let code) = error,
                            code == ECONNRESET || code == EPIPE
                        {
                            break
                        }
                        throw error
                    }
                }
            }
        }
    }

    package func send(_ update: AndroidCursorShapeUpdate) throws {
        try update.validate()
        let bytes = try Self.encode(cursorShape: update)
        try state.withLock { state in
            state.latestCursorShapeByDisplay[update.displayID] = update
            guard let connection = state.connection else { return }
            try connection.send(bytes)
        }
    }

    private static func encode(
        cursorShape update: AndroidCursorShapeUpdate
    ) throws -> Data {
        let bytes = try JSONEncoder().encode(
            AndroidDisplayInteractionEnvelope(cursorShape: update))
        guard
            bytes.count
                <= AndroidRuntimeBridgeProtocol.maximumPacketBytes
        else {
            throw AndroidRuntimeFailure(
                "Android display interaction packet is oversized")
        }
        return bytes
    }

    private func waitUntilReadable(_ descriptor: Int32) throws -> Bool {
        var state = pollfd(
            fd: descriptor,
            events: Int16(POLLIN),
            revents: 0)
        let result = unsafe poll(&state, 1, 50)
        if result < 0, errno != EINTR {
            throw IPCTransportError.systemCall(
                operation: "poll(Android display input)",
                errno: errno)
        }
        return result > 0
    }
}

package final class AndroidDisplayInteractionClient: @unchecked Sendable {
    private let connection: PacketConnection
    package var fileDescriptor: Int32 { connection.fileDescriptor }

    package init(socketPath: String) throws {
        connection = try PacketConnection.connect(path: socketPath)
    }

    package func send(_ event: AndroidInputEvent) throws {
        try send(AndroidDisplayInteractionEnvelope(inputEvent: event))
    }

    private func send(
        _ envelope: AndroidDisplayInteractionEnvelope
    ) throws {
        let bytes = try JSONEncoder().encode(envelope)
        guard
            bytes.count
                <= AndroidRuntimeBridgeProtocol.maximumPacketBytes
        else {
            throw AndroidRuntimeFailure(
                "Android display-input packet is oversized")
        }
        try connection.send(bytes)
    }

    package func receiveCursorShape() throws -> AndroidCursorShapeUpdate {
        let packet = try connection.receive(
            maximumBytes:
                AndroidRuntimeBridgeProtocol.maximumPacketBytes,
            maximumDescriptors: 0)
        guard packet.descriptors.isEmpty else {
            throw AndroidRuntimeFailure(
                "Android display interaction packets cannot carry descriptors")
        }
        let envelope = try JSONDecoder().decode(
            AndroidDisplayInteractionEnvelope.self,
            from: Data(packet.bytes))
        guard envelope.kind == .cursorShape,
            envelope.inputEvent == nil,
            let update = envelope.cursorShape
        else {
            throw AndroidRuntimeFailure(
                "Android display interaction expected cursor shape")
        }
        try update.validate()
        return update
    }
}
