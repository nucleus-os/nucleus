// Client-buffer KMS import for direct scanout.
//
// A committed client dmabuf is imported for the renderer as a Vulkan texture; the
// core dups the client fds for that import, so the originals stay owned by the
// client's DmabufBuffer. To scan the same buffer out on the primary plane it must
// also become a KMS framebuffer, which is a *separate* import: dup the client fds
// again at commit time (they are only borrowed later), and lazily turn them into a
// GEM handle (`drmPrimeFDToHandle`) + a `DrmFramebuffer` on first scanout need.
//
// LIFETIME: the dup'd fds are held for the buffer's life; the GEM handles are
// reference-counted by the kernel (`drmPrimeFDToHandle` returns the same handle for
// the same buffer), so each imported handle is released with `drmCloseBufferHandle`
// and the fb with `drmModeRmFB` — in that order — on `destroy`. A `ClientScanoutBuffer`
// is replaced when the surface commits a new buffer and dropped at surface teardown.
// A pending flip retains its buffer until KMS reports that the replacement latched.

import NucleusCompositorDrmC
import NucleusRenderer

/// Per-device GEM-handle refcount. `drmPrimeFDToHandle` returns the SAME handle for the
/// same underlying dmabuf on one device fd, and handles are not refcounted across
/// imports — so two `ClientScanoutBuffer`s importing the same buffer (a shared
/// `wl_buffer`, or a re-import before the first retires) share one handle, and a naive
/// per-buffer `drmCloseBufferHandle` would close it out from under the other (and the
/// recycled handle number could then alias a different buffer). This owns the
/// import/close and closes a handle only when its last holder releases it.
final class GemHandleTable {
    let device: DrmDeviceLifetime
    private var refcount: [UInt32: Int] = [:]

    init(device: DrmDeviceLifetime) { self.device = device }

    /// Import a dmabuf fd to a (possibly shared) GEM handle, bumping its refcount.
    /// Returns 0 on failure.
    func importHandle(fd: Int32) -> UInt32 {
        var handle: UInt32 = 0
        guard let deviceFd = device.availableFileDescriptor,
              drmPrimeFDToHandle(deviceFd, fd, &handle) == 0,
              handle != 0
        else { return 0 }
        refcount[handle, default: 0] += 1
        return handle
    }

    /// Drop one reference to `handle`, closing it only at zero.
    func releaseHandle(_ handle: UInt32) {
        guard handle != 0, let count = refcount[handle] else { return }
        if count <= 1 {
            refcount.removeValue(forKey: handle)
            if let deviceFd = device.availableFileDescriptor {
                _ = drmCloseBufferHandle(deviceFd, handle)
            }
        } else {
            refcount[handle] = count - 1
        }
    }
}

final class ClientScanoutBuffer {
    private let device: DrmDeviceLifetime
    private let gemTable: GemHandleTable
    let width: UInt32
    let height: UInt32
    let format: UInt32
    let modifier: UInt64

    /// The unique dup'd source fds (closed on destroy).
    private let dupedFds: [Int32]
    /// Per-plane layout referencing the dup'd fds: (fd, offset, stride).
    private let planes: [(fd: Int32, offset: UInt32, stride: UInt32)]
    private var acquireFenceFd: Int32

    /// Lazily-imported KMS state. `imported` latches the one-shot import attempt so a
    /// buffer that fails to import is not retried every frame.
    private var gemHandles: [UInt32] = []
    private var fbId: UInt32 = 0
    private var imported = false
    private var destroyed = false

    /// Fired once when this buffer is destroyed — used to defer a scanned client
    /// buffer's wl_buffer/syncobj release until the page flip that replaces it on the
    /// plane drops this object (the buffer must not be reused while the kernel scans it).
    var onDestroy: (() -> Void)?

    private init(
        device: DrmDeviceLifetime, gemTable: GemHandleTable,
        width: UInt32, height: UInt32, format: UInt32, modifier: UInt64,
        dupedFds: [Int32], planes: [(fd: Int32, offset: UInt32, stride: UInt32)],
        acquireFenceFd: Int32
    ) {
        self.device = device
        self.gemTable = gemTable
        self.width = width
        self.height = height
        self.format = format
        self.modifier = modifier
        self.dupedFds = dupedFds
        self.planes = planes
        self.acquireFenceFd = acquireFenceFd
    }

    /// Dup the client's dmabuf fds and retain the layout for a later KMS import.
    /// `fd` is the descriptor's primary fd; a plane's own `fd` (>= 0) overrides it, and
    /// planes sharing a source fd share a single dup. Returns nil (closing any dup made)
    /// if a `dup` fails or there are no planes.
    static func retain(
        device: DrmDeviceLifetime, gemTable: GemHandleTable, fd: Int32, width: UInt32, height: UInt32,
        format: UInt32, modifier: UInt64, planes sourcePlanes: [DmaBufPlane],
        acquireFenceFd: Int32 = -1
    ) -> ClientScanoutBuffer? {
        guard !sourcePlanes.isEmpty else { return nil }
        var dupBySource: [Int32: Int32] = [:]
        var duped: [Int32] = []
        var layout: [(fd: Int32, offset: UInt32, stride: UInt32)] = []
        for plane in sourcePlanes {
            let source = plane.fd >= 0 ? plane.fd : fd
            let dupFd: Int32
            if let existing = dupBySource[source] {
                dupFd = existing
            } else {
                let d = dup(source)
                guard d >= 0 else {
                    for fd in duped { close(fd) }
                    return nil
                }
                dupBySource[source] = d
                duped.append(d)
                dupFd = d
            }
            layout.append((fd: dupFd,
                           offset: UInt32(truncatingIfNeeded: plane.offset),
                           stride: UInt32(truncatingIfNeeded: plane.rowPitch)))
        }
        return ClientScanoutBuffer(
            device: device, gemTable: gemTable,
            width: width, height: height, format: format, modifier: modifier,
            dupedFds: duped, planes: layout, acquireFenceFd: acquireFenceFd)
    }

    /// Transfer the one-shot client acquire fence to an atomic KMS commit.
    func takeAcquireFenceFd() -> Int32 {
        let fd = acquireFenceFd
        acquireFenceFd = -1
        return fd
    }

    /// The KMS framebuffer id for this client buffer, importing it once on first call
    /// (`drmPrimeFDToHandle` per unique fd → `DrmFramebuffer`). Returns 0 if the import
    /// failed. Idempotent; the fb is retained until `destroy`.
    func framebufferId() -> UInt32 {
        if imported { return fbId }
        imported = true

        var handleBySource: [Int32: UInt32] = [:]
        var handles: [UInt32] = []
        for plane in planes {
            if let existing = handleBySource[plane.fd] {
                handles.append(existing)
                continue
            }
            let handle = gemTable.importHandle(fd: plane.fd)
            guard handle != 0 else {
                releaseHandles()
                return 0
            }
            handleBySource[plane.fd] = handle
            gemHandles.append(handle)
            handles.append(handle)
        }

        let pitches = planes.map { $0.stride }
        let offsets = planes.map { $0.offset }
        let fb: DrmFramebuffer?
        guard let deviceFd = device.availableFileDescriptor else {
            releaseHandles()
            return 0
        }
        if modifier == drmFormatModInvalid {
            fb = DrmFramebuffer(
                deviceFd: deviceFd, width: width, height: height, pixelFormat: format,
                handles: handles, pitches: pitches, offsets: offsets)
        } else {
            fb = DrmFramebuffer(
                deviceFd: deviceFd, width: width, height: height, pixelFormat: format,
                handles: handles, pitches: pitches, offsets: offsets,
                modifiers: planes.map { _ in modifier })
        }
        guard let fb else { releaseHandles(); return 0 }
        fbId = fb.release()
        return fbId
    }

    /// Whether an import has been attempted and produced a usable fb.
    var hasFramebuffer: Bool { fbId != 0 }

    private func releaseHandles() {
        for handle in gemHandles { gemTable.releaseHandle(handle) }
        gemHandles = []
    }

    /// Remove the fb, release the GEM handles, and close the dup'd fds — in that order
    /// (the fb references the handles; the handles reference the buffer). Idempotent.
    func destroy() {
        guard !destroyed else { return }
        destroyed = true
        if fbId != 0 {
            if let deviceFd = device.availableFileDescriptor {
                _ = drmModeRmFB(deviceFd, fbId)
            }
            fbId = 0
        }
        releaseHandles()
        for fd in dupedFds where fd >= 0 { close(fd) }
        if acquireFenceFd >= 0 { close(acquireFenceFd); acquireFenceFd = -1 }
        let notify = onDestroy
        onDestroy = nil
        notify?()
    }

    deinit { destroy() }
}
