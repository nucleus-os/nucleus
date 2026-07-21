import Testing
import NucleusCompositorRenderSession

@MainActor
@Test func drmSessionOwnsOneSeatDeviceAndClosesItExactlyOnce() {
    DrmSession.close()
    var openedPaths: [String] = []
    var closedFDs: [Int32] = []
    DrmSession.installDeviceSeat(
        open: {
            guard let path = $0 else { return -1 }
            openedPaths.append(String(cString: path))
            return 73
        },
        close: { closedFDs.append($0) })

    #expect(DrmSession.open(path: nil) == -1)
    #expect(openedPaths.isEmpty)
    let fd = "/dev/dri/card-test".withCString {
        DrmSession.open(path: $0)
    }
    #expect(fd == 73)
    #expect(DrmSession.fd == 73)
    #expect(openedPaths == ["/dev/dri/card-test"])

    DrmSession.close()
    DrmSession.close()
    #expect(DrmSession.fd == -1)
    #expect(closedFDs == [73])
}
