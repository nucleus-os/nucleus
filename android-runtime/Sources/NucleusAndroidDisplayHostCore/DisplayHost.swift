import Foundation
import Glibc
import NucleusAndroidComposerProtocolC
import NucleusAndroidDisplayControlProtocolC
import NucleusAndroidDrmC
import NucleusAndroidPresentationProtocolC
import NucleusAndroidProcessLifecycleC
internal import NucleusAndroidRuntimeBridgeProtocol
import NucleusIPCTransportC
import NucleusLinuxPrimitives
import NucleusLinuxReactor
import WaylandClient
import WaylandClientDispatch
import WaylandProtocolTypes
import WaylandProtocolsC

/// Converts the millihertz unit used by `wl_output.mode` to the exact nearest
/// integral nanosecond period used by Composer3.
package func composerRefreshPeriodNanoseconds(
    refreshMillihertz: Int32
) -> UInt64? {
    guard refreshMillihertz > 0 else { return nil }
    let divisor = UInt64(refreshMillihertz)
    return (1_000_000_000_000 + divisor / 2) / divisor
}

let initialAndroidPresentationWidth: Int32 = 1_280
let initialAndroidPresentationHeight: Int32 = 720

struct AndroidPresentationMode: Equatable {
    let width: Int32
    let height: Int32
}

struct AndroidPresentationResizeRequest: Equatable {
    let generation: UInt64
    let mode: AndroidPresentationMode
}

struct AndroidPresentationResizePipeline: Equatable {
    private(set) var requestedGeneration: UInt64
    private(set) var requestedMode: AndroidPresentationMode
    private(set) var pendingMode: AndroidPresentationMode?
    private(set) var resizeInFlight = false

    init(
        generation: UInt64,
        mode: AndroidPresentationMode
    ) {
        requestedGeneration = generation
        requestedMode = mode
    }

    mutating func configure(
        _ mode: AndroidPresentationMode
    ) -> AndroidPresentationResizeRequest? {
        if resizeInFlight {
            pendingMode = mode == requestedMode ? nil : mode
            return nil
        }
        guard mode != requestedMode else { return nil }
        return begin(mode)
    }

    mutating func committedFrame(
        generation: UInt64,
        mode: AndroidPresentationMode
    ) -> AndroidPresentationResizeRequest? {
        guard generation == requestedGeneration,
            mode == requestedMode
        else { return nil }
        resizeInFlight = false
        guard let pendingMode else { return nil }
        self.pendingMode = nil
        guard pendingMode != requestedMode else { return nil }
        return begin(pendingMode)
    }

    private mutating func begin(
        _ mode: AndroidPresentationMode
    ) -> AndroidPresentationResizeRequest {
        requestedGeneration &+= 1
        requestedMode = mode
        resizeInFlight = true
        return AndroidPresentationResizeRequest(
            generation: requestedGeneration,
            mode: mode)
    }
}

private struct AndroidPresentedFrame {
    let presentationID: UInt64
    let configurationGeneration: UInt64
    let allocationID: UInt64
    let frameNumber: UInt64
    let drmModifier: UInt64
    let width: UInt32
    let height: UInt32
    let drmFormat: UInt32
    let planeOffset: UInt32
    let planeStride: UInt32
    let damageLeft: Int32
    let damageTop: Int32
    let damageRight: Int32
    let damageBottom: Int32
    let androidDisplayID: Int32
    let hasAcquireFence: Bool

    init(_ request: nucleus_android_presentation_frame) {
        presentationID = request.presentation_id
        configurationGeneration = request.configuration_generation
        allocationID = request.allocation_id
        frameNumber = request.frame_number
        drmModifier = request.drm_modifier
        width = request.width
        height = request.height
        drmFormat = request.drm_format
        planeOffset = request.plane_offset
        planeStride = request.plane_stride
        damageLeft = request.damage_left
        damageTop = request.damage_top
        damageRight = request.damage_right
        damageBottom = request.damage_bottom
        androidDisplayID = request.android_display_id
        hasAcquireFence = request.has_acquire_fence == 1
    }

}

func androidPresentationMode(
    configuredWidth: Int32?,
    configuredHeight: Int32?
) -> AndroidPresentationMode {
    guard let configuredWidth,
        let configuredHeight,
        configuredWidth > 0,
        configuredHeight > 0
    else {
        return AndroidPresentationMode(
            width: initialAndroidPresentationWidth,
            height: initialAndroidPresentationHeight)
    }
    return AndroidPresentationMode(
        width: configuredWidth,
        height: configuredHeight)
}

package func androidDisplayCoordinate(
    hostCoordinate: Double,
    bufferExtent: UInt32,
    destinationExtent: Int32
) -> Double? {
    guard hostCoordinate.isFinite,
        bufferExtent > 0,
        destinationExtent > 0
    else { return nil }
    return min(
        max(hostCoordinate, 0)
            * Double(bufferExtent)
            / Double(destinationExtent),
        Double(bufferExtent - 1))
}

private func androidInputEventTimeNanoseconds() -> UInt64 {
    var time = timespec()
    guard unsafe clock_gettime(CLOCK_MONOTONIC, &time) == 0,
        time.tv_sec >= 0,
        time.tv_nsec >= 0
    else { return 0 }
    return UInt64(time.tv_sec) * 1_000_000_000
        + UInt64(time.tv_nsec)
}

package func waylandCursorShape(
    androidPointerIconType: Int32
) -> UInt32? {
    switch androidPointerIconType {
    case 0: return nil
    case 1, 1_000: return 1
    case 1_001: return 2
    case 1_002: return 4
    case 1_003: return 3
    case 1_004: return 6
    case 1_006: return 7
    case 1_007: return 8
    case 1_008: return 9
    case 1_009: return 10
    case 1_010: return 11
    case 1_011: return 12
    case 1_012: return 14
    case 1_013: return 32
    case 1_014: return 26
    case 1_015: return 27
    case 1_016: return 28
    case 1_017: return 29
    case 1_018: return 33
    case 1_019: return 34
    case 1_020: return 16
    case 1_021: return 17
    default: return 1
    }
}

package enum DisplayHostError: Error, CustomStringConvertible {
    case invalidArguments(String)
    case systemCall(String, Int32)
    case unauthorizedPeer(expected: UInt32, actual: UInt32)
    case invalidRequest
    case wayland(String)

    package var description: String {
        switch self {
        case .invalidArguments(let message): return message
        case .systemCall(let operation, let code):
            let reason = unsafe String(cString: strerror(code))
            return "\(operation) failed: \(reason)"
        case .unauthorizedPeer(let expected, let actual):
            return "unauthorized Android display peer uid \(actual), expected \(expected)"
        case .invalidRequest: return "invalid Android display request"
        case .wayland(let message): return "Wayland display failure: \(message)"
        }
    }
}

@MainActor
func waitForDisplayHostReadable(
    _ descriptor: Int32,
    reactor: LinuxHostReactor
) async throws {
    while true {
        let batch = try await reactor.wait(
            interests: [
                LinuxReactorInterest(
                    token: 1,
                    fileDescriptor: descriptor,
                    events: Int16(POLLIN))
            ],
            timeoutNanoseconds: nil)
        guard let event = batch.events.first else { continue }
        if let failure = event.failureCode {
            throw DisplayHostError.systemCall("io_uring poll", failure)
        }
        let result = LinuxPollResult(returnedEvents: event.returnedEvents)
        if result.isReadable { return }
        if result.isTerminal { throw DisplayHostError.invalidRequest }
    }
}

@MainActor
@safe private final class SyncobjBridge {
    @unsafe private let native: OpaquePointer

    init(renderNode: String) throws {
        var error = [CChar](repeating: 0, count: 1_024)
        guard
            let native = renderNode.withCString({
                unsafe nucleus_android_syncobj_bridge_create(
                    $0, &error, error.count)
            })
        else {
            throw DisplayHostError.wayland(
                error.withUnsafeBufferPointer {
                    unsafe String(cString: $0.baseAddress!)
                })
        }
        unsafe self.native = native
    }

    func importAcquireSyncFile(point: UInt64, fileDescriptor: Int32) -> Bool {
        unsafe nucleus_android_syncobj_bridge_import_acquire_sync_file(
            native, point, fileDescriptor) == 0
    }

    func signalAcquire(point: UInt64) -> Bool {
        unsafe nucleus_android_syncobj_bridge_signal_acquire(native, point) == 0
    }

    func exportAcquireTimeline() -> Int32 {
        unsafe nucleus_android_syncobj_bridge_export_acquire_timeline(native)
    }

    func createReleaseTimeline(
        manager: WaylandProxy<WpLinuxDrmSyncobjManagerV1Client>
    ) throws -> BufferReleaseTimeline {
        guard
            let timeline =
                unsafe nucleus_android_syncobj_bridge_create_timeline(native)
        else {
            throw systemError("creating per-buffer release timeline")
        }
        let descriptor =
            unsafe nucleus_android_syncobj_timeline_export_fd(timeline)
        guard descriptor >= 0 else {
            unsafe nucleus_android_syncobj_timeline_destroy(timeline)
            throw systemError("exporting per-buffer release timeline")
        }
        do {
            let proxy = try manager.importTimeline(
                fd: WaylandClientOwnedFileDescriptor(descriptor))
            return unsafe BufferReleaseTimeline(
                native: timeline,
                proxy: proxy)
        } catch {
            unsafe nucleus_android_syncobj_timeline_destroy(timeline)
            throw error
        }
    }

    func createNativeReleaseFence()
        throws -> (fence: NativeReleaseFence, fileDescriptor: Int32)
    {
        var descriptor: Int32 = -1
        var error = [CChar](repeating: 0, count: 1_024)
        guard
            let fence =
                unsafe nucleus_android_syncobj_bridge_create_native_fence(
                    native,
                    &descriptor,
                    &error,
                    error.count),
            descriptor >= 0
        else {
            if descriptor >= 0 { _ = close(descriptor) }
            throw DisplayHostError.wayland(
                error.withUnsafeBufferPointer {
                    unsafe String(cString: $0.baseAddress!)
                })
        }
        return unsafe (
            NativeReleaseFence(native: fence),
            descriptor
        )
    }

    isolated deinit {
        unsafe nucleus_android_syncobj_bridge_destroy(native)
    }
}

@MainActor
@safe private final class NativeReleaseFence {
    @unsafe private let native: OpaquePointer
    private var completed = false

    init(native: OpaquePointer) {
        unsafe self.native = native
    }

    func signal() -> String? {
        guard !completed else { return nil }
        var error = [CChar](repeating: 0, count: 1_024)
        guard
            unsafe nucleus_android_native_fence_signal(
                native, &error, error.count) == 0
        else {
            return error.withUnsafeBufferPointer {
                unsafe String(cString: $0.baseAddress!)
            }
        }
        completed = true
        return nil
    }

    isolated deinit {
        unsafe nucleus_android_native_fence_destroy(native)
    }
}

@MainActor
@safe private final class BufferReleaseTimeline {
    @unsafe private let native: OpaquePointer
    let proxy: WaylandProxy<WpLinuxDrmSyncobjTimelineV1Client>

    init(
        native: OpaquePointer,
        proxy: WaylandProxy<WpLinuxDrmSyncobjTimelineV1Client>
    ) {
        unsafe self.native = native
        self.proxy = proxy
    }

    func armAvailability(point: UInt64) -> Bool {
        unsafe nucleus_android_syncobj_timeline_arm_available(
            native, point) == 0
    }

    var availabilityFileDescriptor: Int32 {
        unsafe nucleus_android_syncobj_timeline_availability_fd(native)
    }

    func drainAvailability() -> Bool {
        unsafe nucleus_android_syncobj_timeline_drain_available(native) == 0
    }

    func exportSyncFile(point: UInt64) -> Int32 {
        unsafe nucleus_android_syncobj_timeline_export_sync_file(
            native, point)
    }

    isolated deinit {
        try? proxy.destroy()
        unsafe nucleus_android_syncobj_timeline_destroy(native)
    }
}

@MainActor
@safe private final class ReleaseFenceCoordinator {
    @MainActor private struct PendingRelease {
        let timeline: BufferReleaseTimeline
        let point: UInt64
        let fence: NativeReleaseFence
        var compositorFence: Int32?

        var fileDescriptor: Int32 {
            if let compositorFence {
                return compositorFence
            }
            return timeline.availabilityFileDescriptor
        }
    }

    private let reactor: LinuxHostReactor
    private var releases: [UInt64: PendingRelease] = [:]
    private var nextToken: UInt64 = 1
    private var task: Task<Void, Never>?

    init() throws {
        reactor = try LinuxHostReactor()
    }

    func track(
        timeline: BufferReleaseTimeline,
        point: UInt64,
        fence: NativeReleaseFence
    ) {
        let token = nextToken
        nextToken &+= 1
        releases[token] = PendingRelease(
            timeline: timeline,
            point: point,
            fence: fence,
            compositorFence: nil)
        if task == nil {
            task = Task { @MainActor [weak self] in
                await self?.run()
            }
        } else {
            reactor.wake()
        }
    }

    private func run() async {
        while !releases.isEmpty {
            do {
                let interests = releases.map {
                    LinuxReactorInterest(
                        token: $0.key,
                        fileDescriptor: $0.value.fileDescriptor,
                        events: Int16(POLLIN))
                }
                let batch = try await reactor.wait(
                    interests: interests,
                    timeoutNanoseconds: nil)
                for event in batch.events {
                    handle(event)
                }
            } catch {
                failAll("release-fence reactor failed: \(error)")
            }
        }
        task = nil
    }

    private func handle(_ event: LinuxReactorEvent) {
        guard var release = releases[event.token] else { return }
        if let failure = event.failureCode {
            finish(
                token: event.token,
                release: release,
                error: "release-fence poll failed: \(failure)")
            return
        }
        let result = LinuxPollResult(
            returnedEvents: event.returnedEvents)
        guard result.isReadable else {
            if result.isTerminal {
                finish(
                    token: event.token,
                    release: release,
                    error: "release-fence descriptor closed")
            }
            return
        }
        if let compositorFence = release.compositorFence {
            _ = close(compositorFence)
            release.compositorFence = nil
            finish(
                token: event.token,
                release: release,
                error: nil)
            return
        }
        guard release.timeline.drainAvailability() else {
            finish(
                token: event.token,
                release: release,
                error: "release point availability could not be drained")
            return
        }
        let compositorFence = release.timeline.exportSyncFile(
            point: release.point)
        guard compositorFence >= 0 else {
            finish(
                token: event.token,
                release: release,
                error: "compositor release fence could not be exported")
            return
        }
        release.compositorFence = compositorFence
        releases[event.token] = release
    }

    private func finish(
        token: UInt64,
        release: PendingRelease,
        error: String?
    ) {
        if let compositorFence = release.compositorFence {
            _ = close(compositorFence)
        }
        let signalError = release.fence.signal()
        releases[token] = nil
        if let error = error ?? signalError {
            let diagnostic =
                "{\"component\":\"nucleus-android-display-host\","
                + "\"stage\":\"release.fence.failed\","
                + "\"error\":\"\(error)\"}\n"
            FileHandle.standardError.write(Data(diagnostic.utf8))
        }
    }

    private func failAll(_ error: String) {
        let pending = releases
        releases.removeAll(keepingCapacity: true)
        for release in pending.values {
            if let compositorFence = release.compositorFence {
                _ = close(compositorFence)
            }
            _ = release.fence.signal()
        }
        let diagnostic =
            "{\"component\":\"nucleus-android-display-host\","
            + "\"stage\":\"release.fence.failed\","
            + "\"error\":\"\(error)\"}\n"
        FileHandle.standardError.write(Data(diagnostic.utf8))
    }
}

func receiveComposerTopologySubscription(
    _ connection: Int32
) throws -> nucleus_composer_topology_subscribe_request {
    var bytes = [UInt8](
        repeating: 0,
        count: Int(NUCLEUS_COMPOSER_MAX_MESSAGE_BYTES))
    var descriptorCount = 0
    let received = bytes.withUnsafeMutableBytes { message in
        unsafe nucleus_ipc_receive(
            connection,
            message.baseAddress,
            message.count,
            nil,
            0,
            &descriptorCount)
    }
    guard received >= MemoryLayout<nucleus_composer_message_header>.size else {
        throw DisplayHostError.invalidRequest
    }
    let header = bytes.withUnsafeBytes {
        unsafe $0.loadUnaligned(
            as: nucleus_composer_message_header.self)
    }
    guard header.byte_count == received,
        header.fd_count == 0,
        descriptorCount == 0,
        header.operation
            == UInt32(NUCLEUS_COMPOSER_SUBSCRIBE_TOPOLOGY.rawValue),
        received
            == MemoryLayout<nucleus_composer_topology_subscribe_request>.size
    else { throw DisplayHostError.invalidRequest }
    return bytes.withUnsafeBytes {
        unsafe $0.loadUnaligned(
            as: nucleus_composer_topology_subscribe_request.self)
    }
}

@MainActor
@safe package final class NucleusAndroidDisplayHost {
    private let socketPath: String
    private let composerExpectedUserID: UInt32
    private let presentationSocketPath: String
    private let displayControlSocketPath: String
    private let presentationExpectedUserID: UInt32
    private let parentProcessID: Int32
    private let listener: Int32
    private let acceptReactor: LinuxHostReactor
    private let presentationListener: Int32
    private let displayControlListener: Int32
    private let presenter: AndroidDisplayPresenter
    private var topologySubscriber: Int32?
    private var displayControlConnection: Int32?
    private var displayConfigurationGeneration: UInt64 = 1
    private var displayConfigurationMode = AndroidPresentationMode(
        width: initialAndroidPresentationWidth,
        height: initialAndroidPresentationHeight)

    package init(
        socketPath: String,
        expectedUserID: UInt32,
        renderDevice: String,
        parentProcessID: Int32,
        waylandSocket: String,
        inputSocketPath: String,
        presentationSocketPath: String,
        displayControlSocketPath: String,
        presentationExpectedUserID: UInt32
    ) throws {
        guard
            nucleus_android_require_parent_lifetime(
                SIGTERM, parentProcessID) == 0
        else { throw systemError("prctl(PR_SET_PDEATHSIG)") }
        let listener = socketPath.withCString {
            unsafe nucleus_ipc_listen($0, 0o666)
        }
        guard listener >= 0 else { throw systemError("bind/listen") }
        self.socketPath = socketPath
        self.composerExpectedUserID = expectedUserID
        self.presentationSocketPath = presentationSocketPath
        self.displayControlSocketPath = displayControlSocketPath
        self.presentationExpectedUserID = presentationExpectedUserID
        self.parentProcessID = parentProcessID
        self.listener = listener
        self.acceptReactor = try LinuxHostReactor()
        let presentationListener = presentationSocketPath.withCString {
            unsafe nucleus_ipc_listen($0, 0o666)
        }
        guard presentationListener >= 0 else {
            _ = close(listener)
            _ = socketPath.withCString { unsafe unlink($0) }
            throw systemError("binding Android presentation listener")
        }
        self.presentationListener = presentationListener
        let displayControlListener = displayControlSocketPath.withCString {
            unsafe nucleus_ipc_listen($0, 0o666)
        }
        guard displayControlListener >= 0 else {
            _ = close(listener)
            _ = close(presentationListener)
            _ = socketPath.withCString { unsafe unlink($0) }
            _ = presentationSocketPath.withCString { unsafe unlink($0) }
            throw systemError("binding Android display-control listener")
        }
        self.displayControlListener = displayControlListener
        do {
            let inputClient = try AndroidDisplayInteractionClient(
                socketPath: inputSocketPath)
            self.presenter = try AndroidDisplayPresenter(
                waylandSocket: waylandSocket,
                renderDevice: renderDevice,
                reactor: LinuxHostReactor(),
                inputClient: inputClient)
        } catch {
            _ = close(listener)
            _ = close(presentationListener)
            _ = close(displayControlListener)
            _ = socketPath.withCString { unsafe unlink($0) }
            _ = presentationSocketPath.withCString {
                unsafe unlink($0)
            }
            _ = displayControlSocketPath.withCString {
                unsafe unlink($0)
            }
            throw error
        }
        presenter.topologySink = { [weak self] update in
            self?.publishTopology(update)
        }
        presenter.resizeSink = {
            [weak self] presentationID, generation, mode in
            self?.sendDisplayConfiguration(
                presentationID: presentationID,
                generation: generation,
                mode: mode)
        }
    }

    package func run() async throws {
        defer {
            _ = close(listener)
            _ = close(presentationListener)
            _ = close(displayControlListener)
            if let displayControlConnection {
                _ = close(displayControlConnection)
            }
            _ = socketPath.withCString { unsafe unlink($0) }
            _ = presentationSocketPath.withCString {
                unsafe unlink($0)
            }
            _ = displayControlSocketPath.withCString {
                unsafe unlink($0)
            }
        }
        while true {
            let batch = try await acceptReactor.wait(
                interests: [
                    LinuxReactorInterest(
                        token: 1,
                        fileDescriptor: listener,
                        events: Int16(POLLIN)),
                    LinuxReactorInterest(
                        token: 2,
                        fileDescriptor: presentationListener,
                        events: Int16(POLLIN)),
                    LinuxReactorInterest(
                        token: 3,
                        fileDescriptor: displayControlListener,
                        events: Int16(POLLIN)),
                ], timeoutNanoseconds: nil)
            for event in batch.events {
                if let failure = event.failureCode {
                    throw DisplayHostError.systemCall(
                        "accept io_uring poll",
                        failure)
                }
                let result = LinuxPollResult(
                    returnedEvents: event.returnedEvents)
                if result.isTerminal {
                    throw DisplayHostError.invalidRequest
                }
                guard result.isReadable else { continue }
                if event.token == 1 {
                    try acceptComposerConnection()
                } else if event.token == 2 {
                    try acceptPresentationConnection()
                } else if event.token == 3 {
                    try acceptDisplayControlConnection()
                }
            }
        }
    }

    private func acceptDisplayControlConnection() throws {
        let connection = nucleus_ipc_accept(displayControlListener)
        guard connection >= 0 else {
            if errno == EINTR || errno == EAGAIN { return }
            throw systemError("accepting Android display control")
        }
        do {
            try requirePeer(connection, expected: composerExpectedUserID)
            var request = nucleus_android_display_control_register()
            var descriptorCount = 0
            let requestSize = MemoryLayout.size(ofValue: request)
            let received = withUnsafeMutablePointer(to: &request) { bytes in
                unsafe nucleus_ipc_receive(
                    connection,
                    bytes,
                    requestSize,
                    nil,
                    0,
                    &descriptorCount)
            }
            guard received == MemoryLayout.size(ofValue: request),
                request.operation
                    == UInt32(NUCLEUS_ANDROID_DISPLAY_CONTROL_REGISTER.rawValue),
                request.byte_count == received,
                request.fd_count == 0,
                descriptorCount == 0,
                request.presentation_id == 0
            else { throw DisplayHostError.invalidRequest }
            if let previous = displayControlConnection {
                _ = close(previous)
            }
            displayControlConnection = connection
            try sendDisplayConfiguration(
                connection: connection,
                operation: UInt32(
                    NUCLEUS_ANDROID_DISPLAY_CONTROL_CONFIGURE.rawValue),
                presentationID: request.presentation_id,
                mode: displayConfigurationMode)
        } catch {
            _ = close(connection)
            throw error
        }
    }

    private func sendDisplayConfiguration(
        presentationID: UInt64,
        generation: UInt64,
        mode: AndroidPresentationMode
    ) {
        displayConfigurationGeneration = generation
        displayConfigurationMode = mode
        guard let connection = displayControlConnection else { return }
        do {
            try sendDisplayConfiguration(
                connection: connection,
                operation: UInt32(
                    NUCLEUS_ANDROID_DISPLAY_CONTROL_RESIZE.rawValue),
                presentationID: presentationID,
                mode: mode)
        } catch {
            _ = close(connection)
            displayControlConnection = nil
        }
    }

    private func sendDisplayConfiguration(
        connection: Int32,
        operation: UInt32,
        presentationID: UInt64,
        mode: AndroidPresentationMode
    ) throws {
        guard let width = UInt32(exactly: mode.width),
            let height = UInt32(exactly: mode.height)
        else { throw DisplayHostError.invalidRequest }
        var configuration = nucleus_android_display_control_configuration()
        configuration.operation = operation
        configuration.byte_count = UInt32(
            MemoryLayout.size(ofValue: configuration))
        configuration.fd_count = 0
        configuration.presentation_id = presentationID
        configuration.generation = displayConfigurationGeneration
        configuration.width = width
        configuration.height = height
        configuration.density_dpi = 160
        configuration.refresh_millihertz = 60_000
        let configurationSize = MemoryLayout.size(ofValue: configuration)
        let sent = withUnsafePointer(to: &configuration) { bytes in
            unsafe nucleus_ipc_send(
                connection,
                bytes,
                configurationSize,
                nil,
                0)
        }
        guard sent == 0 else {
            throw systemError("sending Android display configuration")
        }
    }

    private func acceptComposerConnection() throws {
        let connection = nucleus_ipc_accept(listener)
        guard connection >= 0 else {
            if errno == EINTR || errno == EAGAIN { return }
            throw systemError("accept")
        }
        do {
            try requirePeer(
                connection,
                expected: composerExpectedUserID)
            let diagnostic =
                "{\"component\":\"nucleus-android-display-host\","
                + "\"stage\":\"composer.connection.accepted\"}\n"
            FileHandle.standardError.write(Data(diagnostic.utf8))
            Task { @MainActor [weak self] in
                guard let self else {
                    _ = close(connection)
                    return
                }
                defer {
                    _ = close(connection)
                }
                do {
                    try await self.serve(connection)
                } catch {
                    let diagnostic =
                        "{\"component\":\"nucleus-android-display-host\","
                        + "\"stage\":\"composer.connection.failed\","
                        + "\"error\":\"\(String(describing: error))\"}\n"
                    FileHandle.standardError.write(Data(diagnostic.utf8))
                }
            }
        } catch {
            _ = close(connection)
            throw error
        }
    }

    private func requirePeer(
        _ connection: Int32,
        expected: UInt32
    ) throws {
        var credentials = nucleus_ipc_peer_credentials()
        guard
            unsafe nucleus_ipc_peer_credentials(
                connection, &credentials) == 0
        else { throw systemError("getsockopt(SO_PEERCRED)") }
        guard credentials.uid == expected else {
            throw DisplayHostError.unauthorizedPeer(
                expected: expected,
                actual: credentials.uid)
        }
    }

    private func acceptPresentationConnection() throws {
        let connection = nucleus_ipc_accept(presentationListener)
        guard connection >= 0 else {
            if errno == EINTR || errno == EAGAIN { return }
            throw systemError("accepting Android presentation")
        }
        do {
            try requirePeer(
                connection,
                expected: presentationExpectedUserID)
            Task { @MainActor [weak self] in
                guard let self else {
                    _ = close(connection)
                    return
                }
                defer { _ = close(connection) }
                do {
                    try await self.servePresentation(connection)
                } catch {
                    let diagnostic =
                        "{\"component\":\"nucleus-android-display-host\","
                        + "\"stage\":\"presentation.connection.failed\","
                        + "\"error\":\"\(String(describing: error))\"}\n"
                    FileHandle.standardError.write(
                        Data(diagnostic.utf8))
                }
            }
        } catch {
            _ = close(connection)
            throw error
        }
    }

    private func servePresentation(_ connection: Int32) async throws {
        while true {
            try await presenter.dispatchUntilReadable(connection)
            var request = nucleus_android_presentation_frame()
            var descriptors = [Int32](
                repeating: -1,
                count: Int(NUCLEUS_ANDROID_PRESENTATION_MAX_FDS))
            var descriptorCount = 0
            let requestSize = MemoryLayout.size(ofValue: request)
            let received = descriptors.withUnsafeMutableBufferPointer { fds in
                withUnsafeMutablePointer(to: &request) { bytes in
                    unsafe nucleus_ipc_receive(
                        connection,
                        bytes,
                        requestSize,
                        fds.baseAddress,
                        fds.count,
                        &descriptorCount)
                }
            }
            if received < 0, errno == ECONNRESET { return }
            descriptors.removeSubrange(
                descriptorCount..<descriptors.count)
            defer {
                for descriptor in descriptors where descriptor >= 0 {
                    _ = close(descriptor)
                }
            }
            guard received == MemoryLayout.size(ofValue: request),
                request.operation
                    == UInt32(
                        NUCLEUS_ANDROID_PRESENTATION_PRESENT.rawValue),
                request.byte_count == received,
                request.fd_count == descriptorCount,
                descriptorCount
                    == (request.has_acquire_fence == 1 ? 3 : 2),
                request.allocation_id > 0,
                request.frame_number > 0,
                request.configuration_generation > 0,
                request.width > 0,
                request.height > 0,
                request.plane_stride > 0,
                request.android_display_id >= 0
            else {
                throw DisplayHostError.invalidRequest
            }
            let releaseFence = try await presenter.present(
                request,
                descriptors: descriptors)
            defer { _ = close(releaseFence) }
            var reply = nucleus_android_presentation_frame_reply()
            reply.operation = UInt32(
                NUCLEUS_ANDROID_PRESENTATION_PRESENT.rawValue)
            reply.byte_count = UInt32(
                MemoryLayout.size(ofValue: reply))
            reply.fd_count = 1
            reply.request_id = request.request_id
            reply.status = UInt32(
                NUCLEUS_ANDROID_PRESENTATION_STATUS_OK.rawValue)
            let replySize = MemoryLayout.size(ofValue: reply)
            let sent = withUnsafePointer(to: &reply) { bytes in
                var descriptor = releaseFence
                return withUnsafePointer(to: &descriptor) { fd in
                    unsafe nucleus_ipc_send(
                        connection,
                        bytes,
                        replySize,
                        fd,
                        1)
                }
            }
            guard sent == 0 else {
                throw systemError("sending Android presentation reply")
            }
        }
    }

    private func serve(_ connection: Int32) async throws {
        let handshakeReactor = try LinuxHostReactor()
        try await waitForDisplayHostReadable(
            connection,
            reactor: handshakeReactor)
        let request = try receiveComposerTopologySubscription(connection)
        try subscribeTopology(connection, request: request)
    }

    private func subscribeTopology(
        _ connection: Int32,
        request: nucleus_composer_topology_subscribe_request
    ) throws {
        let subscriptionDiagnostic =
            "{\"component\":\"nucleus-android-display-host\","
            + "\"stage\":\"topology.subscription.received\","
            + "\"lastGeneration\":\(request.last_generation)}\n"
        FileHandle.standardError.write(
            Data(subscriptionDiagnostic.utf8))
        if let existing = topologySubscriber {
            var state = pollfd(
                fd: existing,
                events: Int16(POLLIN),
                revents: 0)
            if unsafe poll(&state, 1, 0) > 0,
                LinuxPollResult(
                    returnedEvents: state.revents
                ).isTerminal
            {
                _ = close(existing)
                topologySubscriber = nil
            }
        }
        if topologySubscriber != nil {
            try sendTopologyStatus(
                connection,
                status: NUCLEUS_COMPOSER_STATUS_DUPLICATE_SUBSCRIBER)
            return
        }
        let generation = presenter.topologyGeneration
        guard request.last_generation <= generation else {
            try sendTopologyStatus(
                connection,
                status: NUCLEUS_COMPOSER_STATUS_STALE_GENERATION)
            return
        }
        let retained = dup(connection)
        guard retained >= 0 else { throw systemError("dup") }
        topologySubscriber = retained
        do {
            let outputs = presenter.connectedOutputs
            for output in outputs {
                try sendTopology(
                    output,
                    operation: NUCLEUS_COMPOSER_TOPOLOGY_SNAPSHOT,
                    to: retained)
            }
            try sendTopologyStatus(
                retained,
                status: NUCLEUS_COMPOSER_STATUS_OK)
            let snapshotDiagnostic =
                "{\"component\":\"nucleus-android-display-host\","
                + "\"stage\":\"topology.snapshot.sent\","
                + "\"generation\":\(presenter.topologyGeneration),"
                + "\"displays\":\(outputs.count)}\n"
            FileHandle.standardError.write(
                Data(snapshotDiagnostic.utf8))
        } catch {
            _ = close(retained)
            topologySubscriber = nil
            throw error
        }
    }

    private func publishTopology(_ update: AndroidOutputTopology.Update) {
        guard let subscriber = topologySubscriber else { return }
        do {
            try sendTopology(
                update.output,
                operation: update.operation,
                to: subscriber)
        } catch {
            _ = close(subscriber)
            topologySubscriber = nil
        }
    }

    private func sendTopology(
        _ output: AndroidOutputTopology.Output,
        operation: nucleus_composer_operation,
        to connection: Int32
    ) throws {
        var event = nucleus_composer_topology_event()
        event.operation = UInt32(operation.rawValue)
        event.byte_count = UInt32(MemoryLayout.size(ofValue: event))
        event.generation = output.generation
        event.display_id = output.displayID
        event.refresh_period_ns = output.refreshPeriodNanoseconds
        event.mode_width = output.width
        event.mode_height = output.height
        event.refresh_millihertz = output.refreshMillihertz
        event.status = UInt32(NUCLEUS_COMPOSER_STATUS_OK.rawValue)
        event.connected = output.connected ? 1 : 0
        withUnsafeMutableBytes(of: &event.output_name) { destination in
            let utf8 = output.name.utf8.prefix(destination.count - 1)
            unsafe destination.copyBytes(from: utf8)
            unsafe destination[utf8.count] = 0
        }
        let eventSize = MemoryLayout.size(ofValue: event)
        let sent = withUnsafePointer(to: &event) {
            unsafe nucleus_ipc_send(
                connection,
                $0,
                eventSize,
                nil,
                0)
        }
        guard sent == 0 else { throw systemError("sending topology event") }
    }

    private func sendTopologyStatus(
        _ connection: Int32,
        status: nucleus_composer_status
    ) throws {
        var event = nucleus_composer_topology_event()
        event.operation = UInt32(
            NUCLEUS_COMPOSER_TOPOLOGY_SNAPSHOT.rawValue)
        event.byte_count = UInt32(MemoryLayout.size(ofValue: event))
        event.generation = presenter.topologyGeneration
        event.display_id = UInt64.max
        event.status = UInt32(status.rawValue)
        let eventSize = MemoryLayout.size(ofValue: event)
        let sent = withUnsafePointer(to: &event) {
            unsafe nucleus_ipc_send(
                connection,
                $0,
                eventSize,
                nil,
                0)
        }
        guard sent == 0 else { throw systemError("sending topology status") }
    }

}

@MainActor
@safe private final class AndroidOutputTopology: WlOutputEvents {
    typealias Output = ComposerOutputTopologyState.Output
    typealias Update = ComposerOutputTopologyState.Update

    private struct Pending {
        let globalName: UInt32
        let proxy: WaylandProxy<WlOutputClient>
        var name: String?
        var width: Int32?
        var height: Int32?
        var refreshMillihertz: Int32?
        var published: Output?
        var presentationWidth: Int32?
        var presentationHeight: Int32?
    }

    var sink: ((Update) -> Void)?
    private var pendingByProxy: [UInt: Pending] = [:]
    private var proxyByGlobal: [UInt32: UInt] = [:]
    private var state = ComposerOutputTopologyState()
    var generation: UInt64 { state.generation }

    var connectedOutputs: [Output] {
        state.connectedOutputs
    }

    func bind(_ global: BoundGlobal<WlOutputClient>) {
        let identity = global.proxy.identity
        pendingByProxy[identity] = Pending(
            globalName: global.name,
            proxy: global.proxy)
        proxyByGlobal[global.name] = identity
        try? global.proxy.installListener(self)
    }

    func remove(globalName: UInt32) {
        guard let identity = proxyByGlobal.removeValue(forKey: globalName),
            let pending = pendingByProxy.removeValue(forKey: identity),
            let published = pending.published
        else { return }
        if let update = state.disconnect(name: published.name) {
            sink?(update)
        }
        try? pending.proxy.release()
    }

    func geometry(
        _ proxy: WaylandBorrowedProxy<WlOutputClient>,
        x: Int32, y: Int32,
        physical_width: Int32, physical_height: Int32,
        subpixel: WlOutputSubpixel,
        make: String, model: String,
        transform: WlOutputTransform
    ) {}

    func mode(
        _ proxy: WaylandBorrowedProxy<WlOutputClient>,
        flags: WlOutputMode,
        width: Int32,
        height: Int32,
        refresh: Int32
    ) {
        guard flags.contains(.current),
            var pending = pendingByProxy[proxy.identity]
        else { return }
        pending.width = width
        pending.height = height
        pending.refreshMillihertz = refresh
        pendingByProxy[proxy.identity] = pending
    }

    func done(_ proxy: WaylandBorrowedProxy<WlOutputClient>) {
        publish(proxy.identity)
    }

    func scale(
        _ proxy: WaylandBorrowedProxy<WlOutputClient>,
        factor: Int32
    ) {}

    func name(
        _ proxy: WaylandBorrowedProxy<WlOutputClient>,
        name: String
    ) {
        guard var pending = pendingByProxy[proxy.identity] else { return }
        pending.name = name
        pendingByProxy[proxy.identity] = pending
    }

    func description(
        _ proxy: WaylandBorrowedProxy<WlOutputClient>,
        description: String
    ) {}

    private func publish(_ identity: UInt) {
        guard var pending = pendingByProxy[identity],
            let name = pending.name,
            pending.width != nil,
            pending.height != nil,
            let refreshMillihertz = pending.refreshMillihertz,
            let period = composerRefreshPeriodNanoseconds(
                refreshMillihertz: refreshMillihertz)
        else { return }
        let presentationMode = androidPresentationMode(
            configuredWidth: pending.presentationWidth,
            configuredHeight: pending.presentationHeight)
        guard period > 0,
            let update = state.publish(
                name: name,
                width: presentationMode.width,
                height: presentationMode.height,
                refreshMillihertz: refreshMillihertz)
        else { return }
        pending.published = update.output
        pendingByProxy[identity] = pending
        sink?(update)
    }

    func setPresentationMode(
        displayID: UInt64,
        width: Int32,
        height: Int32
    ) {
        guard width > 0, height > 0,
            let identity = pendingByProxy.first(where: {
                $0.value.published?.displayID == displayID
            })?.key,
            var pending = pendingByProxy[identity]
        else { return }
        pending.presentationWidth = width
        pending.presentationHeight = height
        pendingByProxy[identity] = pending
        publish(identity)
    }
}

@MainActor
private final class DisplaySeatHandler:
    WlSeatEvents, WlPointerEvents, WlKeyboardEvents
{
    enum Event {
        case move(
            surfaceIdentity: UInt,
            time: UInt32,
            x: Double,
            y: Double)
        case button(
            surfaceIdentity: UInt,
            time: UInt32,
            x: Double,
            y: Double,
            button: UInt32,
            pressed: Bool)
        case scroll(
            surfaceIdentity: UInt,
            time: UInt32,
            x: Double,
            y: Double,
            horizontal: Double,
            vertical: Double)
        case key(
            surfaceIdentity: UInt,
            time: UInt32,
            keyCode: UInt32,
            pressed: Bool)
    }

    var sink: ((Event) -> Void)?
    private var seat: WaylandProxy<WlSeatClient>?
    private var pointer: WaylandProxy<WlPointerClient>?
    private var cursorShapeManager: WaylandProxy<WpCursorShapeManagerV1Client>?
    private var cursorShapeDevice: WaylandProxy<WpCursorShapeDeviceV1Client>?
    private var keyboard: WaylandProxy<WlKeyboardClient>?
    private var pointerSurfaceIdentity: UInt?
    private var pointerEnterSerial: UInt32 = 0
    private var cursorShapeBySurface: [UInt: UInt32] = [:]
    private var cursorHiddenSurfaces: Set<UInt> = []
    private var keyboardSurfaceIdentity: UInt?
    private var pressedKeys: Set<UInt32> = []
    private var x = 0.0
    private var y = 0.0
    private var pendingHorizontalScroll: Double?
    private var pendingVerticalScroll: Double?

    func bind(_ global: BoundGlobal<WlSeatClient>) {
        seat = global.proxy
        try? global.proxy.installListener(self)
    }

    func bindCursorShapeManager(
        _ global: BoundGlobal<WpCursorShapeManagerV1Client>
    ) {
        cursorShapeManager = global.proxy
        bindCursorShapeDeviceIfPossible()
    }

    func setCursorShape(_ rawShape: UInt32?, for surfaceIdentity: UInt) {
        if let rawShape {
            cursorShapeBySurface[surfaceIdentity] = rawShape
            cursorHiddenSurfaces.remove(surfaceIdentity)
        } else {
            cursorShapeBySurface.removeValue(forKey: surfaceIdentity)
            cursorHiddenSurfaces.insert(surfaceIdentity)
        }
        guard pointerSurfaceIdentity == surfaceIdentity else { return }
        applyCursorShape(rawShape)
    }

    func removeCursorState(for surfaceIdentity: UInt) {
        cursorShapeBySurface.removeValue(forKey: surfaceIdentity)
        cursorHiddenSurfaces.remove(surfaceIdentity)
        if pointerSurfaceIdentity == surfaceIdentity {
            pointerSurfaceIdentity = nil
            pointerEnterSerial = 0
        }
    }

    private func bindCursorShapeDeviceIfPossible() {
        guard cursorShapeDevice == nil,
            let cursorShapeManager,
            let pointer
        else { return }
        cursorShapeDevice = try? cursorShapeManager.getPointer(
            pointer: pointer)
    }

    private func applyCursorShape(_ rawShape: UInt32?) {
        guard pointerEnterSerial != 0 else { return }
        if let rawShape, let cursorShapeDevice {
            try? cursorShapeDevice.setShape(
                serial: pointerEnterSerial,
                shape: WpCursorShapeDeviceV1Shape(rawValue: rawShape))
        } else if rawShape == nil, let pointer {
            try? pointer.setCursor(
                serial: pointerEnterSerial,
                surface: nil,
                hotspot_x: 0,
                hotspot_y: 0)
        }
    }

    func capabilities(
        _ proxy: WaylandBorrowedProxy<WlSeatClient>,
        capabilities: WlSeatCapability
    ) {
        if capabilities.contains(.pointer), pointer == nil,
            let seat
        {
            do {
                let pointer = try seat.getPointer()
                try pointer.installListener(self)
                self.pointer = pointer
                bindCursorShapeDeviceIfPossible()
            } catch {}
        } else if !capabilities.contains(.pointer), let pointer {
            try? cursorShapeDevice?.destroy()
            cursorShapeDevice = nil
            try? pointer.release()
            self.pointer = nil
            pointerSurfaceIdentity = nil
            pointerEnterSerial = 0
        }
        if capabilities.contains(.keyboard), keyboard == nil,
            let seat
        {
            do {
                let keyboard = try seat.getKeyboard()
                try keyboard.installListener(self)
                self.keyboard = keyboard
            } catch {}
        } else if !capabilities.contains(.keyboard), let keyboard {
            releasePressedKeys()
            try? keyboard.release()
            self.keyboard = nil
            keyboardSurfaceIdentity = nil
        }
    }

    func name(
        _ proxy: WaylandBorrowedProxy<WlSeatClient>,
        name: String
    ) {}

    func enter(
        _ proxy: WaylandBorrowedProxy<WlPointerClient>,
        serial: UInt32,
        surface: WaylandBorrowedProxy<WlSurfaceClient>,
        surface_x: Double,
        surface_y: Double
    ) {
        pointerSurfaceIdentity = surface.identity
        pointerEnterSerial = serial
        x = surface_x
        y = surface_y
        applyCursorShape(
            cursorHiddenSurfaces.contains(surface.identity)
                ? nil
                : cursorShapeBySurface[surface.identity] ?? 1)
        sink?(
            .move(
                surfaceIdentity: surface.identity,
                time: 0,
                x: surface_x,
                y: surface_y))
    }

    func leave(
        _ proxy: WaylandBorrowedProxy<WlPointerClient>,
        serial: UInt32,
        surface: WaylandBorrowedProxy<WlSurfaceClient>
    ) {
        pointerSurfaceIdentity = nil
        pointerEnterSerial = 0
    }

    func motion(
        _ proxy: WaylandBorrowedProxy<WlPointerClient>,
        time: UInt32,
        surface_x: Double,
        surface_y: Double
    ) {
        guard let surfaceIdentity = pointerSurfaceIdentity else { return }
        x = surface_x
        y = surface_y
        sink?(
            .move(
                surfaceIdentity: surfaceIdentity,
                time: time,
                x: x,
                y: y))
    }

    func button(
        _ proxy: WaylandBorrowedProxy<WlPointerClient>,
        serial: UInt32,
        time: UInt32,
        button: UInt32,
        state: WlPointerButtonState
    ) {
        guard let surfaceIdentity = pointerSurfaceIdentity else { return }
        sink?(
            .button(
                surfaceIdentity: surfaceIdentity,
                time: time,
                x: x,
                y: y,
                button: button,
                pressed: state == .pressed))
    }

    func axis(
        _ proxy: WaylandBorrowedProxy<WlPointerClient>,
        time: UInt32,
        axis: WlPointerAxis,
        value: Double
    ) {
        guard let surfaceIdentity = pointerSurfaceIdentity else { return }
        let normalized: Double
        if axis == .horizontalScroll,
            let pendingHorizontalScroll
        {
            normalized = pendingHorizontalScroll
            self.pendingHorizontalScroll = nil
        } else if axis == .verticalScroll,
            let pendingVerticalScroll
        {
            normalized = pendingVerticalScroll
            self.pendingVerticalScroll = nil
        } else {
            normalized = value / 10
        }
        sink?(
            .scroll(
                surfaceIdentity: surfaceIdentity,
                time: time,
                x: x,
                y: y,
                horizontal: axis == .horizontalScroll ? normalized : 0,
                vertical: axis == .verticalScroll ? normalized : 0))
    }

    func frame(_ proxy: WaylandBorrowedProxy<WlPointerClient>) {
        pendingHorizontalScroll = nil
        pendingVerticalScroll = nil
    }
    func axisSource(
        _ proxy: WaylandBorrowedProxy<WlPointerClient>,
        axis_source: WlPointerAxisSource
    ) {}
    func axisStop(
        _ proxy: WaylandBorrowedProxy<WlPointerClient>,
        time: UInt32,
        axis: WlPointerAxis
    ) {
        recordScrollDetents(axis: axis, detents: 0)
    }
    func axisDiscrete(
        _ proxy: WaylandBorrowedProxy<WlPointerClient>,
        axis: WlPointerAxis,
        discrete: Int32
    ) {
        recordScrollDetents(axis: axis, detents: Double(discrete))
    }
    func axisValue120(
        _ proxy: WaylandBorrowedProxy<WlPointerClient>,
        axis: WlPointerAxis,
        value120: Int32
    ) {
        recordScrollDetents(
            axis: axis,
            detents: Double(value120) / 120)
    }
    func axisRelativeDirection(
        _ proxy: WaylandBorrowedProxy<WlPointerClient>,
        axis: WlPointerAxis,
        direction: WlPointerAxisRelativeDirection
    ) {}

    private func recordScrollDetents(
        axis: WlPointerAxis,
        detents: Double
    ) {
        if axis == .horizontalScroll {
            pendingHorizontalScroll = detents
        } else if axis == .verticalScroll {
            pendingVerticalScroll = detents
        }
    }

    func keymap(
        _ proxy: WaylandBorrowedProxy<WlKeyboardClient>,
        format: WlKeyboardKeymapFormat,
        fd: consuming WaylandClientOwnedFileDescriptor,
        size: UInt32
    ) {}

    func enter(
        _ proxy: WaylandBorrowedProxy<WlKeyboardClient>,
        serial: UInt32,
        surface: WaylandBorrowedProxy<WlSurfaceClient>,
        keys: WaylandClientArrayView
    ) {
        releasePressedKeys()
        keyboardSurfaceIdentity = surface.identity
        guard let enteredKeys = keys.copiedElements(of: UInt32.self)
        else { return }
        for keyCode in enteredKeys {
            pressedKeys.insert(keyCode)
            sink?(
                .key(
                    surfaceIdentity: surface.identity,
                    time: 0,
                    keyCode: keyCode,
                    pressed: true))
        }
    }

    func leave(
        _ proxy: WaylandBorrowedProxy<WlKeyboardClient>,
        serial: UInt32,
        surface: WaylandBorrowedProxy<WlSurfaceClient>
    ) {
        releasePressedKeys()
        keyboardSurfaceIdentity = nil
    }

    func key(
        _ proxy: WaylandBorrowedProxy<WlKeyboardClient>,
        serial: UInt32,
        time: UInt32,
        key: UInt32,
        state: WlKeyboardKeyState
    ) {
        guard let keyboardSurfaceIdentity else { return }
        let pressed = state == .pressed
        if pressed {
            pressedKeys.insert(key)
        } else {
            pressedKeys.remove(key)
        }
        sink?(
            .key(
                surfaceIdentity: keyboardSurfaceIdentity,
                time: time,
                keyCode: key,
                pressed: pressed))
    }

    func modifiers(
        _ proxy: WaylandBorrowedProxy<WlKeyboardClient>,
        serial: UInt32,
        mods_depressed: UInt32,
        mods_latched: UInt32,
        mods_locked: UInt32,
        group: UInt32
    ) {}

    func repeatInfo(
        _ proxy: WaylandBorrowedProxy<WlKeyboardClient>,
        rate: Int32,
        delay: Int32
    ) {}

    private func releasePressedKeys() {
        guard let keyboardSurfaceIdentity else {
            pressedKeys.removeAll()
            return
        }
        for keyCode in pressedKeys.sorted() {
            sink?(
                .key(
                    surfaceIdentity: keyboardSurfaceIdentity,
                    time: 0,
                    keyCode: keyCode,
                    pressed: false))
        }
        pressedKeys.removeAll()
    }
}

@MainActor
@safe
private final class AndroidDisplayPresenter:
    @MainActor XdgSurfaceEvents,
    @MainActor XdgToplevelEvents,
    @MainActor WlBufferEvents
{
    private final class DisplaySurface {
        let displayID: UInt64
        let surface: WaylandProxy<WlSurfaceClient>
        let xdgSurface: WaylandProxy<XdgSurfaceClient>
        let toplevel: WaylandProxy<XdgToplevelClient>
        let viewport: WaylandProxy<WpViewportClient>
        let syncSurface: WaylandProxy<WpLinuxDrmSyncobjSurfaceV1Client>
        let acquireTimeline: WaylandProxy<WpLinuxDrmSyncobjTimelineV1Client>
        var configured = false
        var closed = false
        var bufferWidth: UInt32
        var bufferHeight: UInt32
        var destinationWidth: Int32
        var destinationHeight: Int32
        var resizePipeline: AndroidPresentationResizePipeline
        var androidDisplayID: Int32 = -1

        init(
            displayID: UInt64,
            surface: WaylandProxy<WlSurfaceClient>,
            xdgSurface: WaylandProxy<XdgSurfaceClient>,
            toplevel: WaylandProxy<XdgToplevelClient>,
            viewport: WaylandProxy<WpViewportClient>,
            syncSurface:
                WaylandProxy<WpLinuxDrmSyncobjSurfaceV1Client>,
            acquireTimeline:
                WaylandProxy<WpLinuxDrmSyncobjTimelineV1Client>,
            bufferWidth: UInt32,
            bufferHeight: UInt32
        ) {
            self.displayID = displayID
            self.surface = surface
            self.xdgSurface = xdgSurface
            self.toplevel = toplevel
            self.viewport = viewport
            self.syncSurface = syncSurface
            self.acquireTimeline = acquireTimeline
            self.bufferWidth = bufferWidth
            self.bufferHeight = bufferHeight
            destinationWidth = Int32(bufferWidth)
            destinationHeight = Int32(bufferHeight)
            resizePipeline = AndroidPresentationResizePipeline(
                generation: 1,
                mode: AndroidPresentationMode(
                    width: Int32(bufferWidth),
                    height: Int32(bufferHeight)))
        }
    }

    private let connection: WaylandConnection
    private let registry: WaylandRegistry
    private let reactor: LinuxHostReactor
    private let releaseFenceCoordinator: ReleaseFenceCoordinator
    private let wmHandler = DisplayWmBaseHandler()
    private let bridge: SyncobjBridge
    private let compositor: WaylandProxy<WlCompositorClient>
    private let dmabuf: WaylandProxy<ZwpLinuxDmabufV1Client>
    private let wmBase: WaylandProxy<XdgWmBaseClient>
    private let viewporter: WaylandProxy<WpViewporterClient>
    private let syncobjManager: WaylandProxy<WpLinuxDrmSyncobjManagerV1Client>
    private let seatHandler: DisplaySeatHandler
    private let inputClient: AndroidDisplayInteractionClient
    private let outputTopology: AndroidOutputTopology
    var topologySink: ((AndroidOutputTopology.Update) -> Void)? {
        didSet {
            outputTopology.sink = { [weak self] update in
                self?.topologySink?(update)
            }
        }
    }
    var topologyGeneration: UInt64 { outputTopology.generation }
    var connectedOutputs: [AndroidOutputTopology.Output] {
        outputTopology.connectedOutputs
    }
    var resizeSink: ((UInt64, UInt64, AndroidPresentationMode) -> Void)?
    private var surfaces: [UInt64: DisplaySurface] = [:]
    private var displayIDByXdgSurface: [UInt: UInt64] = [:]
    private var displayIDByToplevel: [UInt: UInt64] = [:]
    private var displayIDBySurface: [UInt: UInt64] = [:]
    private var buffers: [UInt64: DisplayBuffer] = [:]
    private var reportedInputForwardingFailure = false
    private var nextAcquirePoint: UInt64 = 1
    private var nextReleasePoint: UInt64 = 1
    private var deferredFailure: DisplayHostError?

    init(
        waylandSocket: String,
        renderDevice: String,
        reactor: LinuxHostReactor,
        inputClient: AndroidDisplayInteractionClient
    ) throws {
        let selectedRenderDevice: String
        if renderDevice == "auto" {
            var path = [CChar](
                repeating: 0,
                count: Int(NUCLEUS_ANDROID_DRM_PATH_MAX))
            guard
                unsafe nucleus_android_drm_select_display_render_path(
                    &path, path.count) == 0
            else { throw systemError("selecting display GPU") }
            let end = path.firstIndex(of: 0) ?? path.endIndex
            selectedRenderDevice = String(
                decoding: path[..<end].map {
                    UInt8(bitPattern: $0)
                },
                as: UTF8.self)
        } else {
            selectedRenderDevice = renderDevice
        }
        guard let connection = WaylandConnection(socket: waylandSocket),
            true
        else { throw DisplayHostError.wayland("connection failed") }
        let outputTopology = AndroidOutputTopology()
        let seatHandler = DisplaySeatHandler()
        let releaseFenceCoordinator = try ReleaseFenceCoordinator()
        guard
            let registry = WaylandRegistry(
                connection,
                wanting: [
                    DesiredGlobal<WlCompositorClient>(maximumVersion: 6),
                    DesiredGlobal<ZwpLinuxDmabufV1Client>(maximumVersion: 5),
                    DesiredGlobal<XdgWmBaseClient>(maximumVersion: 6),
                    DesiredGlobal<WpViewporterClient>(maximumVersion: 1),
                    DesiredGlobal<WpLinuxDrmSyncobjManagerV1Client>(
                        maximumVersion: 1),
                    DesiredGlobal<WlSeatClient>(
                        maximumVersion: 10,
                        onBind: { seatHandler.bind($0) }),
                    DesiredGlobal<WpCursorShapeManagerV1Client>(
                        maximumVersion: 1,
                        onBind: {
                            seatHandler.bindCursorShapeManager($0)
                        }),
                    DesiredGlobal<WlOutputClient>(
                        maximumVersion: 4,
                        allowsMultiple: true,
                        onBind: { outputTopology.bind($0) },
                        onRemove: {
                            outputTopology.remove(globalName: $0.name)
                        }),
                ])
        else { throw DisplayHostError.wayland("registry creation failed") }
        guard connection.bootstrapRoundtrip() >= 0 else {
            throw DisplayHostError.wayland("registry roundtrip failed")
        }
        guard connection.bootstrapRoundtrip() >= 0 else {
            throw DisplayHostError.wayland("output-state roundtrip failed")
        }
        guard let compositor = registry.singleton(WlCompositorClient.self),
            let dmabuf = registry.singleton(ZwpLinuxDmabufV1Client.self),
            let wmBase = registry.singleton(XdgWmBaseClient.self),
            let viewporter = registry.singleton(
                WpViewporterClient.self),
            let syncobjManager = registry.singleton(
                WpLinuxDrmSyncobjManagerV1Client.self)
        else { throw DisplayHostError.wayland("required protocol is unavailable") }
        try validateDisplayFormatContract(
            connection: connection,
            dmabuf: dmabuf,
            renderDevice: selectedRenderDevice)
        let bridge = try SyncobjBridge(renderNode: selectedRenderDevice)
        self.connection = connection
        self.registry = registry
        self.reactor = reactor
        self.releaseFenceCoordinator = releaseFenceCoordinator
        self.bridge = bridge
        self.compositor = compositor
        self.dmabuf = dmabuf
        self.wmBase = wmBase
        self.viewporter = viewporter
        self.syncobjManager = syncobjManager
        self.seatHandler = seatHandler
        self.inputClient = inputClient
        self.outputTopology = outputTopology
        wmHandler.proxy = wmBase
        try wmBase.installListener(wmHandler)
        seatHandler.sink = { [weak self] event in
            self?.sendInputEvent(event)
        }
        try createSurface(
            displayID: 0,
            width: UInt32(initialAndroidPresentationWidth),
            height: UInt32(initialAndroidPresentationHeight))
        guard connection.bootstrapRoundtrip() >= 0,
            connection.bootstrapRoundtrip() >= 0,
            surfaces.values.allSatisfy(\.configured)
        else {
            throw DisplayHostError.wayland(
                "initial Android presentation configure failed")
        }
    }

    private func retireSurface(displayID: UInt64) {
        guard
            let displaySurface = surfaces.removeValue(
                forKey: displayID)
        else { return }
        displayIDByXdgSurface.removeValue(
            forKey: displaySurface.xdgSurface.identity)
        displayIDByToplevel.removeValue(
            forKey: displaySurface.toplevel.identity)
        displayIDBySurface.removeValue(
            forKey: displaySurface.surface.identity)
        seatHandler.removeCursorState(
            for: displaySurface.surface.identity)
        try? displaySurface.acquireTimeline.destroy()
        try? displaySurface.syncSurface.destroy()
        try? displaySurface.viewport.destroy()
        try? displaySurface.toplevel.destroy()
        try? displaySurface.xdgSurface.destroy()
        try? displaySurface.surface.destroy()
    }

    func present(
        _ request: nucleus_android_presentation_frame,
        descriptors: [Int32]
    ) async throws -> Int32 {
        try await present(
            AndroidPresentedFrame(request),
            descriptors: descriptors)
    }

    func present(
        _ frame: AndroidPresentedFrame,
        descriptors: [Int32]
    ) async throws -> Int32 {
        guard let displaySurface = surfaces[frame.presentationID],
            !displaySurface.closed,
            displaySurface.configured
        else {
            throw DisplayHostError.wayland(
                "Android presented before its host window was configured")
        }
        let surface = displaySurface.surface
        let syncSurface = displaySurface.syncSurface
        let acquireTimeline = displaySurface.acquireTimeline
        guard let bufferWidth = Int32(exactly: frame.width),
            let bufferHeight = Int32(exactly: frame.height)
        else { throw DisplayHostError.invalidRequest }
        let bufferMode = AndroidPresentationMode(
            width: bufferWidth,
            height: bufferHeight)
        if frame.configurationGeneration
            != displaySurface.resizePipeline.requestedGeneration
            || bufferMode != displaySurface.resizePipeline.requestedMode
        {
            if frame.hasAcquireFence {
                let descriptor = dup(descriptors[2])
                guard descriptor >= 0 else {
                    throw systemError("duplicating stale-frame acquire fence")
                }
                return descriptor
            }
            let release = try bridge.createNativeReleaseFence()
            guard release.fence.signal() == nil else {
                _ = Glibc.close(release.fileDescriptor)
                throw DisplayHostError.wayland(
                    "signaling stale-frame release fence failed")
            }
            return release.fileDescriptor
        }
        let buffer = try importBuffer(frame, descriptors: descriptors)
        displaySurface.bufferWidth = frame.width
        displaySurface.bufferHeight = frame.height
        displaySurface.androidDisplayID = frame.androidDisplayID
        let acquirePoint = nextAcquirePoint
        nextAcquirePoint &+= 1
        if frame.hasAcquireFence {
            guard
                bridge.importAcquireSyncFile(
                    point: acquirePoint,
                    fileDescriptor: descriptors[2])
            else { throw systemError("importing Android acquire fence") }
        } else {
            guard bridge.signalAcquire(point: acquirePoint)
            else { throw systemError("signaling empty acquire point") }
        }
        let releasePoint = nextReleasePoint
        nextReleasePoint &+= 1
        try syncSurface.setAcquirePoint(
            timeline: acquireTimeline,
            point_hi: UInt32(acquirePoint >> 32),
            point_lo: UInt32(truncatingIfNeeded: acquirePoint))
        try syncSurface.setReleasePoint(
            timeline: buffer.releaseTimeline.proxy,
            point_hi: UInt32(releasePoint >> 32),
            point_lo: UInt32(truncatingIfNeeded: releasePoint))
        guard
            buffer.releaseTimeline.armAvailability(
                point: releasePoint)
        else {
            throw systemError(
                "arming compositor release-point availability")
        }
        // Materialize the fence returned to Android before the Wayland commit.
        // Once the commit is flushed there must be no fallible gap before the
        // retirement coordinator owns that fence.
        let nativeRelease = try bridge.createNativeReleaseFence()
        try applyPresentationGeometry(
            displaySurface,
            mode: bufferMode)
        try surface.attach(buffer: buffer.proxy, x: 0, y: 0)
        try surface.damageBuffer(
            x: frame.damageLeft,
            y: frame.damageTop,
            width: frame.damageRight - frame.damageLeft,
            height: frame.damageBottom - frame.damageTop)
        try surface.commit()
        guard connection.flush() >= 0 || errno == EAGAIN else {
            throw DisplayHostError.wayland("commit flush failed")
        }
        releaseFenceCoordinator.track(
            timeline: buffer.releaseTimeline,
            point: releasePoint,
            fence: nativeRelease.fence)
        if let next = displaySurface.resizePipeline.committedFrame(
            generation: frame.configurationGeneration,
            mode: bufferMode)
        {
            resizeSink?(
                displaySurface.displayID,
                next.generation,
                next.mode)
        }
        return nativeRelease.fileDescriptor
    }

    func dispatchUntilReadable(_ descriptor: Int32) async throws {
        while true {
            guard let preparation = connection.prepareRead() else {
                throw DisplayHostError.wayland("prepare-read failed")
            }
            let flushResult = connection.flush()
            let flushError = errno
            if flushResult < 0 && flushError != EAGAIN {
                preparation.read.cancel()
                throw DisplayHostError.wayland("flush failed")
            }
            let displayEvents =
                Int16(POLLIN)
                | (flushResult < 0 ? Int16(POLLOUT) : 0)
            let batch: LinuxReactorBatch
            do {
                batch = try await reactor.wait(
                    interests: [
                        LinuxReactorInterest(
                            token: 1,
                            fileDescriptor: connection.fd,
                            events: displayEvents),
                        LinuxReactorInterest(
                            token: 2,
                            fileDescriptor: descriptor,
                            events: Int16(POLLIN)),
                        LinuxReactorInterest(
                            token: 3,
                            fileDescriptor: inputClient.fileDescriptor,
                            events: Int16(POLLIN)),
                    ], timeoutNanoseconds: nil)
            } catch {
                preparation.read.cancel()
                throw error
            }
            let displayEvent = batch.events.first { $0.token == 1 }
            let socketEvent = batch.events.first { $0.token == 2 }
            let interactionEvent = batch.events.first { $0.token == 3 }
            if let failure = displayEvent?.failureCode
                ?? socketEvent?.failureCode
                ?? interactionEvent?.failureCode
            {
                preparation.read.cancel()
                throw DisplayHostError.systemCall("io_uring poll", failure)
            }
            let displayReadable =
                displayEvent.map {
                    LinuxPollResult(returnedEvents: $0.returnedEvents).isReadable
                } ?? false
            guard preparation.read.complete(readable: displayReadable) >= 0 else {
                throw DisplayHostError.wayland("event dispatch failed")
            }
            if let deferredFailure {
                throw deferredFailure
            }
            if surfaces.values.contains(where: \.closed) {
                throw DisplayHostError.wayland("surface closed")
            }
            if let interactionEvent,
                LinuxPollResult(
                    returnedEvents: interactionEvent.returnedEvents
                ).isReadable
            {
                let update = try inputClient.receiveCursorShape()
                if let surfaceIdentity = surfaces.values.first(where: {
                    $0.androidDisplayID == update.displayID
                })?.surface.identity {
                    seatHandler.setCursorShape(
                        waylandCursorShape(
                            androidPointerIconType:
                                update.pointerIconType),
                        for: surfaceIdentity)
                }
            }
            if let interactionEvent,
                LinuxPollResult(
                    returnedEvents: interactionEvent.returnedEvents
                ).isTerminal
            {
                throw DisplayHostError.wayland(
                    "Android display interaction disconnected")
            }
            if let socketEvent,
                LinuxPollResult(
                    returnedEvents: socketEvent.returnedEvents
                ).isReadable
            {
                return
            }
            if let socketEvent,
                LinuxPollResult(
                    returnedEvents: socketEvent.returnedEvents
                ).isTerminal
            {
                throw DisplayHostError.invalidRequest
            }
        }
    }

    private func createSurface(
        displayID: UInt64,
        width: UInt32,
        height: UInt32
    ) throws {
        guard surfaces[displayID] == nil
        else {
            throw DisplayHostError.wayland(
                "presentation \(displayID) already has a Wayland surface")
        }
        let surface: WaylandProxy<WlSurfaceClient>
        let xdgSurface: WaylandProxy<XdgSurfaceClient>
        let toplevel: WaylandProxy<XdgToplevelClient>
        let viewport: WaylandProxy<WpViewportClient>
        let syncSurface: WaylandProxy<WpLinuxDrmSyncobjSurfaceV1Client>
        do {
            surface = try compositor.createSurface()
            xdgSurface = try wmBase.getXdgSurface(surface: surface)
            toplevel = try xdgSurface.getToplevel()
            viewport = try viewporter.getViewport(surface: surface)
            syncSurface = try syncobjManager.getSurface(surface: surface)
        } catch {
            throw DisplayHostError.wayland("surface creation failed")
        }
        let acquireFD = bridge.exportAcquireTimeline()
        guard acquireFD >= 0 else {
            if acquireFD >= 0 { _ = Glibc.close(acquireFD) }
            throw DisplayHostError.wayland("timeline import failed")
        }
        let acquireTimeline: WaylandProxy<WpLinuxDrmSyncobjTimelineV1Client>
        do {
            acquireTimeline = try syncobjManager.importTimeline(
                fd: WaylandClientOwnedFileDescriptor(acquireFD))
        } catch {
            throw DisplayHostError.wayland("timeline import failed")
        }
        let displaySurface = DisplaySurface(
            displayID: displayID,
            surface: surface,
            xdgSurface: xdgSurface,
            toplevel: toplevel,
            viewport: viewport,
            syncSurface: syncSurface,
            acquireTimeline: acquireTimeline,
            bufferWidth: width,
            bufferHeight: height)
        surfaces[displayID] = displaySurface
        displayIDBySurface[surface.identity] = displayID
        displayIDByXdgSurface[xdgSurface.identity] = displayID
        displayIDByToplevel[toplevel.identity] = displayID
        try xdgSurface.installListener(self)
        try toplevel.installListener(self)
        try toplevel.setAppId(app_id: "nucleus.android.desktop")
        try toplevel.setTitle(title: "Android")
        try toplevel.setMinSize(width: 320, height: 320)
        try viewport.setDestination(
            width: Int32(width),
            height: Int32(height))
        try xdgSurface.setWindowGeometry(
            x: 0,
            y: 0,
            width: Int32(width),
            height: Int32(height))
        try surface.commit()
        guard connection.flush() >= 0 else {
            throw DisplayHostError.wayland("initial commit failed")
        }
    }

    private func importBuffer(
        _ request: AndroidPresentedFrame,
        descriptors: [Int32]
    ) throws -> DisplayBuffer {
        if let existing = buffers[request.allocationID] {
            guard existing.width == request.width,
                existing.height == request.height,
                existing.format == request.drmFormat,
                existing.modifier == request.drmModifier,
                existing.offset == request.planeOffset,
                existing.stride == request.planeStride
            else { throw DisplayHostError.invalidRequest }
            return existing
        }
        let params: WaylandProxy<ZwpLinuxBufferParamsV1Client>
        do {
            params = try dmabuf.createParams()
        } catch {
            throw DisplayHostError.wayland("dma-buf params creation failed")
        }
        defer { try? params.destroy() }
        try params.add(
            fd: try duplicateDisplayDescriptor(descriptors[0]),
            plane_idx: 0,
            offset: request.planeOffset,
            stride: request.planeStride,
            modifier_hi: UInt32(request.drmModifier >> 32),
            modifier_lo: UInt32(truncatingIfNeeded: request.drmModifier))
        let proxy = try params.createImmed(
            width: Int32(request.width),
            height: Int32(request.height),
            format: request.drmFormat,
            flags: ZwpLinuxBufferParamsV1Flags(rawValue: 0))
        let lifetime = dup(descriptors[1])
        guard lifetime >= 0 else {
            try? proxy.destroy()
            throw systemError("duplicating allocation lifetime")
        }
        let ownedLifetime = LinuxOwnedFileDescriptor(adopting: lifetime)
        let releaseTimeline: BufferReleaseTimeline
        do {
            releaseTimeline = try bridge.createReleaseTimeline(
                manager: syncobjManager)
        } catch {
            try? proxy.destroy()
            throw error
        }
        let buffer = DisplayBuffer(
            proxy: proxy,
            lifetime: consume ownedLifetime,
            releaseTimeline: releaseTimeline,
            width: request.width,
            height: request.height,
            format: request.drmFormat,
            modifier: request.drmModifier,
            offset: request.planeOffset,
            stride: request.planeStride)
        try proxy.installListener(self)
        buffers[request.allocationID] = buffer
        return buffer
    }

    private func applyPresentationGeometry(
        _ displaySurface: DisplaySurface,
        mode: AndroidPresentationMode
    ) throws {
        try displaySurface.viewport.setDestination(
            width: mode.width,
            height: mode.height)
        try displaySurface.xdgSurface.setWindowGeometry(
            x: 0,
            y: 0,
            width: mode.width,
            height: mode.height)
        let opaqueRegion = try compositor.createRegion()
        defer { try? opaqueRegion.destroy() }
        try opaqueRegion.add(
            x: 0,
            y: 0,
            width: mode.width,
            height: mode.height)
        try displaySurface.surface.setOpaqueRegion(region: opaqueRegion)
        displaySurface.destinationWidth = mode.width
        displaySurface.destinationHeight = mode.height
    }

    func configure(
        _ proxy: WaylandBorrowedProxy<XdgSurfaceClient>, serial: UInt32
    ) {
        guard let displayID = displayIDByXdgSurface[proxy.identity],
            let displaySurface = surfaces[displayID]
        else { return }
        try? displaySurface.xdgSurface.ackConfigure(serial: serial)
        displaySurface.configured = true
        try? displaySurface.surface.commit()
    }

    func configure(
        _ proxy: WaylandBorrowedProxy<XdgToplevelClient>,
        width: Int32,
        height: Int32,
        states: WaylandClientArrayView
    ) {
        guard let displayID = displayIDByToplevel[proxy.identity],
            let displaySurface = surfaces[displayID]
        else { return }
        if width > 0, height > 0 {
            let mode = AndroidPresentationMode(
                width: width,
                height: height)
            if let request =
                displaySurface.resizePipeline.configure(mode)
            {
                resizeSink?(
                    displayID,
                    request.generation,
                    request.mode)
            }
        }
    }

    private func sendInputEvent(_ event: DisplaySeatHandler.Event) {
        if case .key(
            let surfaceIdentity,
            _,
            let keyCode,
            let pressed
        ) = event {
            guard
                let presentationID =
                    displayIDBySurface[surfaceIdentity],
                let surface = surfaces[presentationID],
                surface.androidDisplayID >= 0
            else { return }
            forwardInputEvent {
                try inputClient.send(
                    AndroidInputEvent(
                        displayID: surface.androidDisplayID,
                        eventTimeNanoseconds:
                            androidInputEventTimeNanoseconds(),
                        keyCode: keyCode,
                        pressed: pressed,
                        action: .key))
            }
            return
        }

        let surfaceIdentity: UInt
        let hostX: Double
        let hostY: Double
        let action: AndroidInputAction
        let button: UInt32?
        let pressed: Bool?
        let scrollX: Double?
        let scrollY: Double?
        switch event {
        case .move(let identity, _, let x, let y):
            surfaceIdentity = identity
            hostX = x
            hostY = y
            action = .pointerMotion
            button = nil
            pressed = nil
            scrollX = nil
            scrollY = nil
        case .button(
            let identity,
            _,
            let x,
            let y,
            let code,
            let isPressed
        ):
            surfaceIdentity = identity
            hostX = x
            hostY = y
            action = .pointerButton
            button = code
            pressed = isPressed
            scrollX = nil
            scrollY = nil
        case .scroll(
            let identity,
            _,
            let x,
            let y,
            let horizontal,
            let vertical
        ):
            surfaceIdentity = identity
            hostX = x
            hostY = y
            action = .pointerScroll
            button = nil
            pressed = nil
            scrollX = horizontal
            scrollY = vertical
        case .key:
            return
        }
        guard
            let presentationID =
                displayIDBySurface[surfaceIdentity],
            let surface = surfaces[presentationID],
            surface.androidDisplayID >= 0,
            surface.destinationWidth > 0,
            surface.destinationHeight > 0
        else { return }
        guard
            let x = androidDisplayCoordinate(
                hostCoordinate: hostX,
                bufferExtent: surface.bufferWidth,
                destinationExtent: surface.destinationWidth),
            let y = androidDisplayCoordinate(
                hostCoordinate: hostY,
                bufferExtent: surface.bufferHeight,
                destinationExtent: surface.destinationHeight)
        else { return }
        forwardInputEvent {
            try inputClient.send(
                AndroidInputEvent(
                    displayID: surface.androidDisplayID,
                    eventTimeNanoseconds:
                        androidInputEventTimeNanoseconds(),
                    x: x,
                    y: y,
                    button: button,
                    pressed: pressed,
                    scrollX: scrollX,
                    scrollY: scrollY,
                    action: action))
        }
    }

    private func forwardInputEvent(
        _ operation: () throws -> Void
    ) {
        do {
            try operation()
        } catch {
            guard !reportedInputForwardingFailure else { return }
            reportedInputForwardingFailure = true
            let diagnostic =
                "{\"component\":\"nucleus-android-display-host\","
                + "\"stage\":\"input.forwarding.failed\","
                + "\"error\":\"\(String(describing: error))\"}\n"
            FileHandle.standardError.write(Data(diagnostic.utf8))
        }
    }

    func close(_ proxy: WaylandBorrowedProxy<XdgToplevelClient>) {
        guard let displayID = displayIDByToplevel[proxy.identity] else {
            return
        }
        surfaces[displayID]?.closed = true
        retireSurface(displayID: displayID)
    }
    func release(_ proxy: WaylandBorrowedProxy<WlBufferClient>) {
        guard
            let allocation = buffers.first(where: {
                $0.value.proxy.identity == proxy.identity
            })?.key
        else {
            return
        }
        if let removed = buffers.removeValue(forKey: allocation) {
            try? removed.proxy.destroy()
        }
    }
    func configureBounds(
        _ proxy: WaylandBorrowedProxy<XdgToplevelClient>,
        width: Int32, height: Int32
    ) {}
    func wmCapabilities(
        _ proxy: WaylandBorrowedProxy<XdgToplevelClient>,
        capabilities: WaylandClientArrayView
    ) {}

    isolated deinit {
        for buffer in buffers.values {
            try? buffer.proxy.destroy()
        }
        for displaySurface in surfaces.values {
            try? displaySurface.acquireTimeline.destroy()
            try? displaySurface.syncSurface.destroy()
            try? displaySurface.viewport.destroy()
            try? displaySurface.toplevel.destroy()
            try? displaySurface.xdgSurface.destroy()
            try? displaySurface.surface.destroy()
        }
    }
}

@MainActor
@safe private final class DisplayBuffer {
    let proxy: WaylandProxy<WlBufferClient>
    let lifetime: LinuxOwnedFileDescriptor
    let releaseTimeline: BufferReleaseTimeline
    let width: UInt32
    let height: UInt32
    let format: UInt32
    let modifier: UInt64
    let offset: UInt32
    let stride: UInt32

    init(
        proxy: WaylandProxy<WlBufferClient>,
        lifetime: consuming LinuxOwnedFileDescriptor,
        releaseTimeline: BufferReleaseTimeline,
        width: UInt32,
        height: UInt32,
        format: UInt32,
        modifier: UInt64,
        offset: UInt32,
        stride: UInt32
    ) {
        self.proxy = proxy
        self.lifetime = consume lifetime
        self.releaseTimeline = releaseTimeline
        self.width = width
        self.height = height
        self.format = format
        self.modifier = modifier
        self.offset = offset
        self.stride = stride
    }
}

@MainActor
private final class DisplayWmBaseHandler: XdgWmBaseEvents {
    weak var proxy: WaylandProxy<XdgWmBaseClient>?

    func ping(
        _ proxy: WaylandBorrowedProxy<XdgWmBaseClient>, serial: UInt32
    ) {
        try? self.proxy?.pong(serial: serial)
    }
}

private func duplicateDisplayDescriptor(
    _ descriptor: Int32
) throws -> WaylandClientOwnedFileDescriptor {
    let duplicate = dup(descriptor)
    guard duplicate >= 0 else {
        throw systemError("duplicating dma-buf plane")
    }
    return WaylandClientOwnedFileDescriptor(duplicate)
}

private func systemError(_ operation: String) -> DisplayHostError {
    .systemCall(operation, errno)
}
