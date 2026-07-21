import Testing
import NucleusCompositorRenderSession

@MainActor
@Test func drmSessionOwnsOneSeatDeviceAndClosesItExactlyOnce() {
    let session = DrmSession()
    var openedPaths: [String] = []
    var closedFDs: [Int32] = []
    session.installDeviceSeat(
        open: {
            guard let path = $0 else { return -1 }
            openedPaths.append(String(cString: path))
            return 73
        },
        close: { closedFDs.append($0) })

    #expect(session.open(path: nil) == -1)
    #expect(session.generation == 0)
    #expect(openedPaths.isEmpty)
    let fd = "/dev/dri/card-test".withCString {
        session.open(path: $0)
    }
    #expect(fd == 73)
    #expect(session.fd == 73)
    #expect(session.generation == 1)
    #expect(openedPaths == ["/dev/dri/card-test"])

    session.close()
    session.close()
    #expect(session.fd == -1)
    #expect(closedFDs == [73])

    #expect("/dev/dri/card-test".withCString { session.open(path: $0) } == 73)
    #expect(session.generation == 2)
    session.close()
    #expect(closedFDs == [73, 73])
}
