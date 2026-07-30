import Foundation
import Glibc
@testable import NucleusAndroidRuntimeHostLinux
import Testing

@Test func launchedProcessDoesNotInheritBlockedSignals() throws {
    var blockedMask = sigset_t()
    var inheritedMask = sigset_t()
    #expect(unsafe sigemptyset(&blockedMask) == 0)
    #expect(unsafe sigaddset(&blockedMask, SIGCHLD) == 0)
    #expect(unsafe pthread_sigmask(
        SIG_BLOCK,
        &blockedMask,
        &inheritedMask) == 0)
    defer {
        _ = unsafe pthread_sigmask(
            SIG_SETMASK,
            &inheritedMask,
            nil)
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [
        "-c",
        """
        test "$(awk '$1 == "SigBlk:" { print $2 }' /proc/self/status)" \
          = 0000000000000000
        """,
    ]
    try launchAndroidRuntimeProcess(process)
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
}
