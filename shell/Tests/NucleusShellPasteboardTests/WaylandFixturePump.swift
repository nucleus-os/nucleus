import Glibc
import NucleusShellWayland

@MainActor
@discardableResult
func pumpWaylandFixtureClient(_ client: ShellWaylandClient) -> Int32 {
    guard let preparation = client.prepareRead() else { return -1 }
    let flushResult = client.flush()
    if flushResult < 0, errno != EAGAIN {
        preparation.read.cancel()
        return -1
    }

    var descriptor = pollfd(
        fd: client.fd,
        events: Int16(POLLIN),
        revents: 0)
    let pollResult = poll(&descriptor, 1, 0)
    let readable = pollResult > 0
        && descriptor.revents & Int16(POLLIN) != 0
    return preparation.read.complete(readable: readable)
}
