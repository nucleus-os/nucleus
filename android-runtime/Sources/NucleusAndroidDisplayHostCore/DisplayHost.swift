import Foundation
import Glibc
import NucleusAndroidComposerProtocolC
import NucleusAndroidDrmC
import NucleusAndroidIPCC
import NucleusLinuxReactor
import WaylandClient
import WaylandClientC
import WaylandClientDispatch

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
            return "\(operation) failed: \(String(cString: strerror(code)))"
        case .unauthorizedPeer(let expected, let actual):
            return "unauthorized Composer3 peer uid \(actual), expected \(expected)"
        case .invalidRequest: return "invalid Composer3 display request"
        case .wayland(let message): return "Wayland display failure: \(message)"
        }
    }
}

@MainActor
public final class NucleusAndroidDisplayHost {
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
            nucleus_android_ipc_listen($0, 0o666)
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
            _ = socketPath.withCString { unlink($0) }
            throw error
        }
    }

    public func run() async throws {
        defer {
            _ = close(listener)
            _ = socketPath.withCString { unlink($0) }
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
        guard nucleus_android_ipc_peer_credentials(
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
                    nucleus_android_ipc_receive(
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
                        nucleus_android_ipc_send(
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
private final class AndroidDisplayPresenter:
    @MainActor XdgSurfaceEvents,
    @MainActor XdgToplevelEvents,
    @MainActor WlBufferEvents
{
    private let connection: WaylandConnection
    private let registry: WaylandRegistry
    private let reactor: LinuxHostReactor
    private let wmHandler = DisplayWmBaseHandler()
    private let bridge: OpaquePointer
    private var compositor: OpaquePointer?
    private var dmabuf: OpaquePointer?
    private var wmBase: OpaquePointer?
    private var syncobjManager: OpaquePointer?
    private var surface: OpaquePointer?
    private var xdgSurface: OpaquePointer?
    private var toplevel: OpaquePointer?
    private var syncSurface: OpaquePointer?
    private var acquireTimeline: OpaquePointer?
    private var releaseTimeline: OpaquePointer?
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
            guard nucleus_android_drm_select_display_render_path(
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
                DesiredGlobal(swift_wayland_iface_wl_compositor(), maxVersion: 6),
                DesiredGlobal(swift_wayland_iface_zwp_linux_dmabuf_v1(), maxVersion: 5),
                DesiredGlobal(swift_wayland_iface_xdg_wm_base(), maxVersion: 6),
                DesiredGlobal(
                    swift_wayland_iface_wp_linux_drm_syncobj_manager_v1(),
                    maxVersion: 1),
            ])
        else { throw DisplayHostError.wayland("connection failed") }
        guard let bridge = selectedRenderDevice.withCString({
            nucleus_android_syncobj_bridge_create($0)
        }) else { throw systemError("creating syncobj bridge") }
        self.connection = connection
        self.registry = registry
        self.reactor = reactor
        self.bridge = bridge
        registry.onBind = { [weak self] global in self?.bound(global) }
        guard connection.bootstrapRoundtrip() >= 0 else {
            throw DisplayHostError.wayland("registry roundtrip failed")
        }
        guard compositor != nil, dmabuf != nil, wmBase != nil,
              syncobjManager != nil
        else { throw DisplayHostError.wayland("required protocol is unavailable") }
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
            guard nucleus_android_syncobj_bridge_import_acquire_sync_file(
                bridge, acquirePoint, descriptors[2]) == 0
            else { throw systemError("importing Composer3 acquire fence") }
        } else {
            guard nucleus_android_syncobj_bridge_signal_acquire(
                bridge, acquirePoint) == 0
            else { throw systemError("signaling empty acquire point") }
        }
        let releasePoint = nextReleasePoint
        nextReleasePoint &+= 1
        let releaseFence =
            nucleus_android_syncobj_bridge_export_release_sync_file(
                bridge, releasePoint)
        guard releaseFence >= 0 else {
            throw systemError("exporting Composer3 release fence")
        }
        wp_linux_drm_syncobj_surface_v1_set_acquire_point(
            syncSurface,
            acquireTimeline,
            UInt32(acquirePoint >> 32),
            UInt32(truncatingIfNeeded: acquirePoint))
        wp_linux_drm_syncobj_surface_v1_set_release_point(
            syncSurface,
            releaseTimeline,
            UInt32(releasePoint >> 32),
            UInt32(truncatingIfNeeded: releasePoint))
        wl_surface_attach(surface, buffer.proxy, 0, 0)
        wl_surface_damage_buffer(
            surface,
            request.damage_left,
            request.damage_top,
            request.damage_right - request.damage_left,
            request.damage_bottom - request.damage_top)
        wl_surface_commit(surface)
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
        guard let compositor, let wmBase, let syncobjManager,
              let surface = wl_compositor_create_surface(compositor),
              let xdgSurface = xdg_wm_base_get_xdg_surface(wmBase, surface),
              let toplevel = xdg_surface_get_toplevel(xdgSurface),
              let syncSurface = wp_linux_drm_syncobj_manager_v1_get_surface(
                syncobjManager, surface)
        else { throw DisplayHostError.wayland("surface creation failed") }
        let acquireFD =
            nucleus_android_syncobj_bridge_export_acquire_timeline(bridge)
        let releaseFD =
            nucleus_android_syncobj_bridge_export_release_timeline(bridge)
        guard acquireFD >= 0, releaseFD >= 0,
              let acquireTimeline =
                wp_linux_drm_syncobj_manager_v1_import_timeline(
                    syncobjManager, acquireFD),
              let releaseTimeline =
                wp_linux_drm_syncobj_manager_v1_import_timeline(
                    syncobjManager, releaseFD)
        else {
            if acquireFD >= 0 { _ = Glibc.close(acquireFD) }
            if releaseFD >= 0 { _ = Glibc.close(releaseFD) }
            throw DisplayHostError.wayland("timeline import failed")
        }
        _ = Glibc.close(acquireFD)
        _ = Glibc.close(releaseFD)
        self.surface = surface
        self.xdgSurface = xdgSurface
        self.toplevel = toplevel
        self.syncSurface = syncSurface
        self.acquireTimeline = acquireTimeline
        self.releaseTimeline = releaseTimeline
        XdgSurfaceClient.addListener(xdgSurface, owner: self)
        XdgToplevelClient.addListener(toplevel, owner: self)
        "android.runtime".withCString { xdg_toplevel_set_app_id(toplevel, $0) }
        "Android".withCString { xdg_toplevel_set_title(toplevel, $0) }
        xdg_toplevel_set_min_size(toplevel, Int32(width), Int32(height))
        wl_surface_commit(surface)
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
        guard let dmabuf,
              let params = zwp_linux_dmabuf_v1_create_params(dmabuf)
        else { throw DisplayHostError.wayland("dma-buf params creation failed") }
        defer { zwp_linux_buffer_params_v1_destroy(params) }
        zwp_linux_buffer_params_v1_add(
            params,
            descriptors[0],
            0,
            request.plane_offset,
            request.plane_stride,
            UInt32(request.drm_modifier >> 32),
            UInt32(truncatingIfNeeded: request.drm_modifier))
        guard let proxy = zwp_linux_buffer_params_v1_create_immed(
            params,
            Int32(request.width),
            Int32(request.height),
            request.drm_format,
            0)
        else { throw DisplayHostError.wayland("dma-buf import failed") }
        let lifetime = dup(descriptors[1])
        guard lifetime >= 0 else {
            wl_buffer_destroy(proxy)
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
        WlBufferClient.addListener(proxy, owner: self)
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

    private func bound(_ global: BoundGlobal) {
        switch String(cString: global.interface.pointee.name) {
        case "wl_compositor": compositor = global.proxy
        case "zwp_linux_dmabuf_v1": dmabuf = global.proxy
        case "xdg_wm_base":
            wmBase = global.proxy
            XdgWmBaseClient.addListener(global.proxy, owner: wmHandler)
        case "wp_linux_drm_syncobj_manager_v1": syncobjManager = global.proxy
        default: break
        }
    }

    func configure(_ proxy: OpaquePointer, serial: UInt32) {
        xdg_surface_ack_configure(proxy, serial)
        configured = true
    }

    func configure(
        _ proxy: OpaquePointer,
        width: Int32,
        height: Int32,
        states: UnsafeMutablePointer<wl_array>?
    ) {}

    func close(_ proxy: OpaquePointer) { closed = true }
    func release(_ proxy: OpaquePointer) {
        guard let allocation = buffers.first(where: {
            $0.value.proxy == proxy
        })?.key else {
            return
        }
        buffers.removeValue(forKey: allocation)
        wl_buffer_destroy(proxy)
    }
    func configureBounds(_ proxy: OpaquePointer, width: Int32, height: Int32) {}
    func wmCapabilities(
        _ proxy: OpaquePointer,
        capabilities: UnsafeMutablePointer<wl_array>?
    ) {}

    isolated deinit {
        for buffer in buffers.values {
            wl_buffer_destroy(buffer.proxy)
        }
        if let acquireTimeline {
            wp_linux_drm_syncobj_timeline_v1_destroy(acquireTimeline)
        }
        if let releaseTimeline {
            wp_linux_drm_syncobj_timeline_v1_destroy(releaseTimeline)
        }
        if let syncSurface {
            wp_linux_drm_syncobj_surface_v1_destroy(syncSurface)
        }
        if let toplevel { xdg_toplevel_destroy(toplevel) }
        if let xdgSurface { xdg_surface_destroy(xdgSurface) }
        if let surface { wl_surface_destroy(surface) }
        nucleus_android_syncobj_bridge_destroy(bridge)
    }
}

private final class DisplayBuffer {
    let proxy: OpaquePointer
    let lifetime: Int32
    let width: UInt32
    let height: UInt32
    let format: UInt32
    let modifier: UInt64
    let offset: UInt32
    let stride: UInt32

    init(
        proxy: OpaquePointer,
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

private final class DisplayWmBaseHandler: XdgWmBaseEvents {
    func ping(_ proxy: OpaquePointer, serial: UInt32) {
        xdg_wm_base_pong(proxy, serial)
    }
}

private func systemError(_ operation: String) -> DisplayHostError {
    .systemCall(operation, errno)
}
