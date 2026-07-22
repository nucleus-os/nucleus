import Testing
import Glibc
@testable import NucleusCompositorRendererLinux
import NucleusRenderer  // DmaBufPlane

// (drmPrimeFDToHandle → DrmFramebuffer) needs a real DRM device and is validated on
// hardware; what is testable headlessly is the fd bookkeeping, whose failure mode —
// accidentally closing the client's dmabuf fd — would corrupt a live client buffer.
@Suite struct DrmClientScanoutTests {
    @Test func retainDupsWithoutConsumingClientFds() {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        let clientFd = fds[0]
        let otherEnd = fds[1]
        defer { close(clientFd); close(otherEnd) }

        let buffer = ClientScanoutBuffer.retain(
            deviceFd: -1, gemTable: GemHandleTable(deviceFd: -1),
            fd: clientFd, width: 1920, height: 1080,
            format: drmFormatXRGB8888, modifier: drmFormatModInvalid,
            planes: [DmaBufPlane(fd: -1, offset: 0, rowPitch: 1920 * 4)])
        #expect(buffer != nil)

        // No real DRM device: the import fails gracefully and returns 0 (not a crash).
        #expect(buffer?.framebufferId() == 0)

        // destroy() is idempotent (deinit also calls it) and must never close the
        // client's fd — only the dup retain made.
        buffer?.destroy()
        buffer?.destroy()
        #expect(fcntl(clientFd, F_GETFD) != -1, "retain/destroy must not close the client's fd")
    }

    @Test func retainSharesOneDupAcrossPlanesWithSameFd() {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        let clientFd = fds[0]
        let otherEnd = fds[1]
        defer { close(clientFd); close(otherEnd) }

        // Two planes sharing the descriptor's primary fd (fd == -1 → primary). Retain
        // must succeed and, on destroy, leave the client's fd open.
        let buffer = ClientScanoutBuffer.retain(
            deviceFd: -1, gemTable: GemHandleTable(deviceFd: -1),
            fd: clientFd, width: 64, height: 64,
            format: drmFormatXRGB8888, modifier: 0,
            planes: [
                DmaBufPlane(fd: -1, offset: 0, rowPitch: 256),
                DmaBufPlane(fd: -1, offset: 4096, rowPitch: 256),
            ])
        #expect(buffer != nil)
        buffer?.destroy()
        #expect(fcntl(clientFd, F_GETFD) != -1)
    }

    @Test func acquireFenceTransfersExactlyOnce() {
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        let ownedFence = dup(fds[0])
        let buffer = ClientScanoutBuffer.retain(
            deviceFd: -1, gemTable: GemHandleTable(deviceFd: -1),
            fd: fds[0], width: 16, height: 16,
            format: drmFormatXRGB8888, modifier: drmFormatModInvalid,
            planes: [DmaBufPlane(fd: -1, offset: 0, rowPitch: 64)],
            acquireFenceFd: ownedFence)
        let transferred = buffer?.takeAcquireFenceFd() ?? -1
        #expect(transferred == ownedFence)
        #expect(buffer?.takeAcquireFenceFd() == -1)
        buffer?.destroy()
        #expect(fcntl(transferred, F_GETFD) != -1, "destroy must not close a transferred fence")
        close(transferred)
    }
}
