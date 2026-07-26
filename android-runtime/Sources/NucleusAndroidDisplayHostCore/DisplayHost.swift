import Foundation
import Glibc
import NucleusAndroidComposerProtocolC
import NucleusAndroidDrmC
import NucleusAndroidIPCC
import NucleusLinuxReactor
import WaylandClient
import WaylandClientDispatch
import WaylandProtocolTypes

public enum DisplayHostError: Error, CustomStringConvertible {
    case invalidArguments(String)
    case systemCall(String, Int32)
    case unauthorizedPeer(expected: UInt32, actual: UInt32)
    case invalidRequest
    case wayland(String)

    public var description: String {
        switch self {
        case .invalidArguments(let message): return message
        case .systemCall(let operation, let code):
            let reason = unsafe String(cString: strerror(code))
            return "\(operation) failed: \(reason)"
        case .unauthorizedPeer(let expected, let actual):
            return "unauthorized Composer3 peer uid \(actual), expected \(expected)"
        case .invalidRequest: return "invalid Composer3 display request"
        case .wayland(let message): return "Wayland display failure: \(message)"
        }
    }
}

@MainActor
@safe public final class NucleusAndroidDisplayHost {
    private let socketPath: String
    private let expectedUserID: UInt32
    private let parentProcessID: Int32
    private let listener: Int32
    private let reactor: LinuxHostReactor
    private let presenter: AndroidDisplayPresenter

    public init(
        socketPath: String,
        expectedUserID: UInt32,
        renderDevice: String,
        parentProcessID: Int32,
        waylandSocket: String
    ) throws {
        guard nucleus_android_ipc_require_parent_lifetime(
            SIGTERM, parentProcessID) == 0
        else { throw systemError("prctl(PR_SET_PDEATHSIG)") }
        let listener = socketPath.withCString {
            unsafe nucleus_android_ipc_listen($0, 0o666)
        }
        guard listener >= 0 else { throw systemError("bind/listen") }
        self.socketPath = socketPath
        self.expectedUserID = expectedUserID
        self.parentProcessID = parentProcessID
        self.listener = listener
        self.reactor = try LinuxHostReactor()
        do {
            self.presenter = try AndroidDisplayPresenter(
                waylandSocket: waylandSocket,
                renderDevice: renderDevice,
                reactor: reactor)
        } catch {
            _ = close(listener)
            _ = socketPath.withCString { unsafe unlink($0) }
            throw error
        }
    }

    public func run() async throws {
        defer {
            _ = close(listener)
            _ = socketPath.withCString { unsafe unlink($0) }
        }
        while true {
            try await waitForReadable(listener)
            let connection = nucleus_android_ipc_accept(listener)
            guard connection >= 0 else {
                if errno == EINTR { continue }
                throw systemError("accept")
            }
            do {
                try requirePeer(connection)
                try await serve(connection)
            } catch {
                _ = close(connection)
                throw error
            }
            _ = close(connection)
        }
    }

    private func requirePeer(_ connection: Int32) throws {
        var credentials = nucleus_android_peer_credentials()
        guard unsafe nucleus_android_ipc_peer_credentials(
            connection, &credentials) == 0
        else { throw systemError("getsockopt(SO_PEERCRED)") }
        guard credentials.uid == expectedUserID else {
            throw DisplayHostError.unauthorizedPeer(
                expected: expectedUserID,
                actual: credentials.uid)
        }
    }

    private func serve(_ connection: Int32) async throws {
        while true {
            try await presenter.dispatchUntilReadable(connection)
            var request = nucleus_composer_present_request()
            var descriptors = [Int32](
                repeating: -1,
                count: Int(NUCLEUS_COMPOSER_MAX_FDS))
            var descriptorCount = 0
            let requestSize = MemoryLayout.size(ofValue: request)
            let received = descriptors.withUnsafeMutableBufferPointer { fds in
                withUnsafeMutablePointer(to: &request) { bytes in
                    unsafe nucleus_android_ipc_receive(
                        connection,
                        bytes,
                        requestSize,
                        fds.baseAddress,
                        fds.count,
                        &descriptorCount)
                }
            }
            if received < 0 {
                if errno == ECONNRESET { return }
                throw systemError("recvmsg")
            }
            descriptors.removeSubrange(descriptorCount..<descriptors.count)
            do {
                try validate(request, descriptorCount: descriptorCount)
                let releaseFence = try await presenter.present(
                    request, descriptors: descriptors)
                defer { _ = close(releaseFence) }
                var reply = nucleus_composer_present_reply()
                reply.magic = NUCLEUS_COMPOSER_PROTOCOL_MAGIC
                reply.version = NUCLEUS_COMPOSER_PROTOCOL_VERSION
                reply.operation = UInt16(NUCLEUS_COMPOSER_PRESENT.rawValue)
                reply.byte_count = UInt32(MemoryLayout.size(ofValue: reply))
                reply.fd_count = 1
                reply.request_id = request.request_id
                reply.status = UInt32(NUCLEUS_COMPOSER_STATUS_OK.rawValue)
                let replySize = MemoryLayout.size(ofValue: reply)
                let sent = withUnsafePointer(to: &reply) { bytes in
                    var descriptor = releaseFence
                    return withUnsafePointer(to: &descriptor) { fd in
                        unsafe nucleus_android_ipc_send(
                            connection,
                            bytes,
                            replySize,
                            fd,
                            1)
                    }
                }
                guard sent == 0 else { throw systemError("sendmsg") }
            } catch {
                for descriptor in descriptors where descriptor >= 0 {
                    _ = close(descriptor)
                }
                throw error
            }
            for descriptor in descriptors where descriptor >= 0 {
                _ = close(descriptor)
            }
        }
    }

    private func validate(
        _ request: nucleus_composer_present_request,
        descriptorCount: Int
    ) throws {
        let expectedDescriptors = request.has_acquire_fence == 1 ? 3 : 2
        guard request.magic == NUCLEUS_COMPOSER_PROTOCOL_MAGIC,
              request.version == NUCLEUS_COMPOSER_PROTOCOL_VERSION,
              request.operation == UInt16(NUCLEUS_COMPOSER_PRESENT.rawValue),
              request.byte_count == UInt32(MemoryLayout.size(ofValue: request)),
              request.fd_count == expectedDescriptors,
              descriptorCount == Int(expectedDescriptors),
              request.display_id == 0,
              request.allocation_id != 0,
              request.frame_number != 0,
              request.width > 0,
              request.height > 0,
              request.plane_stride > 0,
              request.damage_right > request.damage_left,
              request.damage_bottom > request.damage_top
        else { throw DisplayHostError.invalidRequest }
    }

    private func waitForReadable(_ descriptor: Int32) async throws {
        while true {
            let batch = try await reactor.wait(
                interests: [LinuxReactorInterest(
                    token: 1,
                    fileDescriptor: descriptor,
                    events: Int16(POLLIN))],
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
}

@MainActor
@safe private final class AndroidDisplayPresenter:
    @MainActor XdgSurfaceEvents,
    @MainActor XdgToplevelEvents,
    @MainActor WlBufferEvents
{
    private let connection: WaylandConnection
    private let registry: WaylandRegistry
    private let reactor: LinuxHostReactor
    private let wmHandler = DisplayWmBaseHandler()
    private let bridge: OpaquePointer
    private let compositor: WaylandProxy<WlCompositorClient>
    private let dmabuf: WaylandProxy<ZwpLinuxDmabufV1Client>
    private let wmBase: WaylandProxy<XdgWmBaseClient>
    private let syncobjManager:
        WaylandProxy<WpLinuxDrmSyncobjManagerV1Client>
    private var surface: WaylandProxy<WlSurfaceClient>?
    private var xdgSurface: WaylandProxy<XdgSurfaceClient>?
    private var toplevel: WaylandProxy<XdgToplevelClient>?
    private var syncSurface:
        WaylandProxy<WpLinuxDrmSyncobjSurfaceV1Client>?
    private var acquireTimeline:
        WaylandProxy<WpLinuxDrmSyncobjTimelineV1Client>?
    private var releaseTimeline:
        WaylandProxy<WpLinuxDrmSyncobjTimelineV1Client>?
    private var buffers: [UInt64: DisplayBuffer] = [:]
    private var configured = false
    private var closed = false
    private var nextAcquirePoint: UInt64 = 1
    private var nextReleasePoint: UInt64 = 1

    init(
        waylandSocket: String,
        renderDevice: String,
        reactor: LinuxHostReactor
    ) throws {
        let selectedRenderDevice: String
        if renderDevice == "auto" {
            var path = [CChar](
                repeating: 0,
                count: Int(NUCLEUS_ANDROID_DRM_PATH_MAX))
            guard unsafe nucleus_android_drm_select_display_render_path(
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
              let registry = WaylandRegistry(connection, wanting: [
                DesiredGlobal<WlCompositorClient>(maximumVersion: 6),
                DesiredGlobal<ZwpLinuxDmabufV1Client>(maximumVersion: 5),
                DesiredGlobal<XdgWmBaseClient>(maximumVersion: 6),
                DesiredGlobal<WpLinuxDrmSyncobjManagerV1Client>(
                    maximumVersion: 1),
            ])
        else { throw DisplayHostError.wayland("connection failed") }
        guard connection.bootstrapRoundtrip() >= 0 else {
            throw DisplayHostError.wayland("registry roundtrip failed")
        }
        guard let compositor = registry.singleton(WlCompositorClient.self),
              let dmabuf = registry.singleton(ZwpLinuxDmabufV1Client.self),
              let wmBase = registry.singleton(XdgWmBaseClient.self),
              let syncobjManager = registry.singleton(
                WpLinuxDrmSyncobjManagerV1Client.self)
        else { throw DisplayHostError.wayland("required protocol is unavailable") }
        guard let bridge = selectedRenderDevice.withCString({
            unsafe nucleus_android_syncobj_bridge_create($0)
        }) else { throw systemError("creating syncobj bridge") }
        self.connection = connection
        self.registry = registry
        self.reactor = reactor
        unsafe self.bridge = bridge
        self.compositor = compositor
        self.dmabuf = dmabuf
        self.wmBase = wmBase
        self.syncobjManager = syncobjManager
        wmHandler.proxy = wmBase
        try wmBase.installListener(wmHandler)
    }

    func present(
        _ request: nucleus_composer_present_request,
        descriptors: [Int32]
    ) async throws -> Int32 {
        if surface == nil {
            try await createSurface(width: request.width, height: request.height)
        }
        guard !closed,
              let surface,
              let syncSurface,
              let acquireTimeline,
              let releaseTimeline
        else { throw DisplayHostError.wayland("surface closed") }
        let buffer = try importBuffer(request, descriptors: descriptors)
        let acquirePoint = nextAcquirePoint
        nextAcquirePoint &+= 1
        if request.has_acquire_fence == 1 {
            guard unsafe nucleus_android_syncobj_bridge_import_acquire_sync_file(
                bridge, acquirePoint, descriptors[2]) == 0
            else { throw systemError("importing Composer3 acquire fence") }
        } else {
            guard unsafe nucleus_android_syncobj_bridge_signal_acquire(
                bridge, acquirePoint) == 0
            else { throw systemError("signaling empty acquire point") }
        }
        let releasePoint = nextReleasePoint
        nextReleasePoint &+= 1
        let releaseFence =
            unsafe nucleus_android_syncobj_bridge_export_release_sync_file(
                bridge, releasePoint)
        guard releaseFence >= 0 else {
            throw systemError("exporting Composer3 release fence")
        }
        try syncSurface.setAcquirePoint(
            timeline: acquireTimeline,
            point_hi: UInt32(acquirePoint >> 32),
            point_lo: UInt32(truncatingIfNeeded: acquirePoint))
        try syncSurface.setReleasePoint(
            timeline: releaseTimeline,
            point_hi: UInt32(releasePoint >> 32),
            point_lo: UInt32(truncatingIfNeeded: releasePoint))
        try surface.attach(buffer: buffer.proxy, x: 0, y: 0)
        try surface.damageBuffer(
            x: request.damage_left,
            y: request.damage_top,
            width: request.damage_right - request.damage_left,
            height: request.damage_bottom - request.damage_top)
        try surface.commit()
        guard connection.flush() >= 0 || errno == EAGAIN else {
            _ = Glibc.close(releaseFence)
            throw DisplayHostError.wayland("commit flush failed")
        }
        return releaseFence
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
            let displayEvents = Int16(POLLIN)
                | (flushResult < 0 ? Int16(POLLOUT) : 0)
            let batch: LinuxReactorBatch
            do {
                batch = try await reactor.wait(interests: [
                    LinuxReactorInterest(
                        token: 1,
                        fileDescriptor: connection.fd,
                        events: displayEvents),
                    LinuxReactorInterest(
                        token: 2,
                        fileDescriptor: descriptor,
                        events: Int16(POLLIN)),
                ], timeoutNanoseconds: nil)
            } catch {
                preparation.read.cancel()
                throw error
            }
            let displayEvent = batch.events.first { $0.token == 1 }
            let socketEvent = batch.events.first { $0.token == 2 }
            if let failure = displayEvent?.failureCode ?? socketEvent?.failureCode {
                preparation.read.cancel()
                throw DisplayHostError.systemCall("io_uring poll", failure)
            }
            let displayReadable = displayEvent.map {
                LinuxPollResult(returnedEvents: $0.returnedEvents).isReadable
            } ?? false
            guard preparation.read.complete(readable: displayReadable) >= 0 else {
                throw DisplayHostError.wayland("event dispatch failed")
            }
            if closed { throw DisplayHostError.wayland("surface closed") }
            if let socketEvent,
               LinuxPollResult(
                returnedEvents: socketEvent.returnedEvents).isReadable {
                return
            }
            if let socketEvent,
               LinuxPollResult(
                returnedEvents: socketEvent.returnedEvents).isTerminal {
                throw DisplayHostError.invalidRequest
            }
        }
    }

    private func createSurface(width: UInt32, height: UInt32) async throws {
        let surface: WaylandProxy<WlSurfaceClient>
        let xdgSurface: WaylandProxy<XdgSurfaceClient>
        let toplevel: WaylandProxy<XdgToplevelClient>
        let syncSurface: WaylandProxy<WpLinuxDrmSyncobjSurfaceV1Client>
        do {
            surface = try compositor.createSurface()
            xdgSurface = try wmBase.getXdgSurface(surface: surface)
            toplevel = try xdgSurface.getToplevel()
            syncSurface = try syncobjManager.getSurface(surface: surface)
        } catch {
            throw DisplayHostError.wayland("surface creation failed")
        }
        let acquireFD =
            unsafe nucleus_android_syncobj_bridge_export_acquire_timeline(bridge)
        let releaseFD =
            unsafe nucleus_android_syncobj_bridge_export_release_timeline(bridge)
        guard acquireFD >= 0, releaseFD >= 0 else {
            if acquireFD >= 0 { _ = Glibc.close(acquireFD) }
            if releaseFD >= 0 { _ = Glibc.close(releaseFD) }
            throw DisplayHostError.wayland("timeline import failed")
        }
        let acquireTimeline: WaylandProxy<WpLinuxDrmSyncobjTimelineV1Client>
        let releaseTimeline: WaylandProxy<WpLinuxDrmSyncobjTimelineV1Client>
        do {
            acquireTimeline = try syncobjManager.importTimeline(
                fd: WaylandClientOwnedFileDescriptor(acquireFD))
            releaseTimeline = try syncobjManager.importTimeline(
                fd: WaylandClientOwnedFileDescriptor(releaseFD))
        } catch {
            throw DisplayHostError.wayland("timeline import failed")
        }
        self.surface = surface
        self.xdgSurface = xdgSurface
        self.toplevel = toplevel
        self.syncSurface = syncSurface
        self.acquireTimeline = acquireTimeline
        self.releaseTimeline = releaseTimeline
        try xdgSurface.installListener(self)
        try toplevel.installListener(self)
        try toplevel.setAppId(app_id: "android.runtime")
        try toplevel.setTitle(title: "Android")
        try toplevel.setMinSize(
            width: Int32(width),
            height: Int32(height))
        try surface.commit()
        guard connection.flush() >= 0 else {
            throw DisplayHostError.wayland("initial commit failed")
        }
        while !configured {
            try await dispatchWaylandOnce()
        }
    }

    private func importBuffer(
        _ request: nucleus_composer_present_request,
        descriptors: [Int32]
    ) throws -> DisplayBuffer {
        if let existing = buffers[request.allocation_id] {
            guard existing.width == request.width,
                  existing.height == request.height,
                  existing.format == request.drm_format,
                  existing.modifier == request.drm_modifier,
                  existing.offset == request.plane_offset,
                  existing.stride == request.plane_stride
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
            offset: request.plane_offset,
            stride: request.plane_stride,
            modifier_hi: UInt32(request.drm_modifier >> 32),
            modifier_lo: UInt32(truncatingIfNeeded: request.drm_modifier))
        let proxy = try params.createImmed(
            width: Int32(request.width),
            height: Int32(request.height),
            format: request.drm_format,
            flags: ZwpLinuxBufferParamsV1Flags(rawValue: 0))
        let lifetime = dup(descriptors[1])
        guard lifetime >= 0 else {
            try? proxy.destroy()
            throw systemError("duplicating allocation lifetime")
        }
        let buffer = DisplayBuffer(
            proxy: proxy,
            lifetime: lifetime,
            width: request.width,
            height: request.height,
            format: request.drm_format,
            modifier: request.drm_modifier,
            offset: request.plane_offset,
            stride: request.plane_stride)
        try proxy.installListener(self)
        buffers[request.allocation_id] = buffer
        return buffer
    }

    private func dispatchWaylandOnce() async throws {
        guard let preparation = connection.prepareRead() else {
            throw DisplayHostError.wayland("prepare-read failed")
        }
        guard connection.flush() >= 0 else {
            preparation.read.cancel()
            throw DisplayHostError.wayland("flush failed")
        }
        let batch = try await reactor.wait(interests: [
            LinuxReactorInterest(
                token: 1,
                fileDescriptor: connection.fd,
                events: Int16(POLLIN)),
        ], timeoutNanoseconds: nil)
        let readable = batch.events.contains {
            $0.token == 1
                && LinuxPollResult(
                    returnedEvents: $0.returnedEvents).isReadable
        }
        guard preparation.read.complete(readable: readable) >= 0 else {
            throw DisplayHostError.wayland("event dispatch failed")
        }
        if closed { throw DisplayHostError.wayland("surface closed") }
    }

    func configure(
        _ proxy: WaylandBorrowedProxy<XdgSurfaceClient>, serial: UInt32
    ) {
        try? xdgSurface?.ackConfigure(serial: serial)
        configured = true
    }

    func configure(
        _ proxy: WaylandBorrowedProxy<XdgToplevelClient>,
        width: Int32,
        height: Int32,
        states: WaylandClientArrayView
    ) {}

    func close(_ proxy: WaylandBorrowedProxy<XdgToplevelClient>) {
        closed = true
    }
    func release(_ proxy: WaylandBorrowedProxy<WlBufferClient>) {
        guard let allocation = buffers.first(where: {
            $0.value.proxy.identity == proxy.identity
        })?.key else {
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
        if let acquireTimeline {
            try? acquireTimeline.destroy()
        }
        if let releaseTimeline {
            try? releaseTimeline.destroy()
        }
        if let syncSurface {
            try? syncSurface.destroy()
        }
        if let toplevel {
            try? toplevel.destroy()
        }
        if let xdgSurface {
            try? xdgSurface.destroy()
        }
        if let surface {
            try? surface.destroy()
        }
        unsafe nucleus_android_syncobj_bridge_destroy(bridge)
    }
}

@safe private final class DisplayBuffer {
    let proxy: WaylandProxy<WlBufferClient>
    let lifetime: Int32
    let width: UInt32
    let height: UInt32
    let format: UInt32
    let modifier: UInt64
    let offset: UInt32
    let stride: UInt32

    init(
        proxy: WaylandProxy<WlBufferClient>,
        lifetime: Int32,
        width: UInt32,
        height: UInt32,
        format: UInt32,
        modifier: UInt64,
        offset: UInt32,
        stride: UInt32
    ) {
        self.proxy = proxy
        self.lifetime = lifetime
        self.width = width
        self.height = height
        self.format = format
        self.modifier = modifier
        self.offset = offset
        self.stride = stride
    }

    deinit { _ = close(lifetime) }
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
