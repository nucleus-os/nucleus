import Glibc
import NucleusShellProcessC
import Testing

@Suite
struct ShellProcessTests {
    @Test func reapStatusPreservesTerminationSignal() throws {
        let child = fork()
        let pid = try #require(child >= 0 ? child : nil)
        if pid == 0 {
            var signals = sigset_t()
            unsafe sigemptyset(&signals)
            unsafe sigaddset(&signals, SIGTERM)
            _ = unsafe pthread_sigmask(SIG_UNBLOCK, &signals, nil)
            _ = signal(SIGTERM, SIG_DFL)
            _ = raise(SIGTERM)
            _exit(99)
        }

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
