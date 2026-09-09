import Glibc
import NucleusShellProcessC
import Testing

@Suite
struct ShellProcessTests {
    @Test func reapStatusPreservesTerminationSignal() throws {
        let child = fork()
        // Between fork and _exit the child holds one thread out of the many
        // this process runs tests on, and every lock the others happened to
        // hold at that instant is inherited locked with no owner to release
        // it. So the child may touch nothing that allocates or enters the
        // testing library. Recording an expectation does both, and a child
        // that deadlocks there never exits: it survives as an orphan holding
        // the runner's standard output open, and the harness waits for an end
        // of file that cannot arrive.
        if child == 0 {
            var signals = sigset_t()
            unsafe sigemptyset(&signals)
            unsafe sigaddset(&signals, SIGTERM)
            _ = unsafe pthread_sigmask(SIG_UNBLOCK, &signals, nil)
            _ = signal(SIGTERM, SIG_DFL)
            _ = raise(SIGTERM)
            _exit(99)
        }
        let pid = try #require(child > 0 ? child : nil)

        var exitCode: Int32 = -1
        var result: Int32 = 0
        let deadline = ContinuousClock.now + .seconds(2)
        while result == 0 && ContinuousClock.now < deadline {
            result = unsafe nucleus_shell_reap_nohang(pid, &exitCode)
            if result == 0 {
                usleep(1_000)
            }
        }
        #expect(result == 1)
        #expect(exitCode == 128 + SIGTERM)
    }
}
