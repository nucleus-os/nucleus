import Testing
import NucleusCompositorRenderSession

@MainActor
@Test func drmSessionOwnsOneSeatDeviceAndClosesItExactlyOnce() {
    let session = DrmSession()
    var openedPaths: [String] = []
    var closedFDs: [Int32] = []
    unsafe session.installDeviceSeat(
        open: {
            guard let path = unsafe $0 else { return -1 }
            openedPaths.append(unsafe String(cString: path))
            return 73
        },
        close: { closedFDs.append($0) })

    let nilOpenResult = unsafe session.open(path: nil)
    #expect(nilOpenResult == -1)
    #expect(session.generation == 0)
    #expect(openedPaths.isEmpty)
    let fd = "/dev/dri/card-test".withCString {
        unsafe session.open(path: $0)
    }
    #expect(fd == 73)
    #expect(session.fd == 73)
    #expect(session.generation == 1)
    #expect(openedPaths == ["/dev/dri/card-test"])

    session.close()
    session.close()
    #expect(session.fd == -1)
    #expect(closedFDs == [73])

    let reopenedFD = "/dev/dri/card-test".withCString {
        unsafe session.open(path: $0)
    }
    #expect(reopenedFD == 73)
    #expect(session.generation == 2)
    session.close()
    #expect(closedFDs == [73, 73])
}
