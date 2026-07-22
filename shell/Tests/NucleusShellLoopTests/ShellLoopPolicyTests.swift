import Glibc
import NucleusShellSignalC
import Testing
@testable import NucleusShellLoop

@Suite struct ShellLoopPolicyTests {
    @Test func terminalFlagsDoNotRequireReadability() {
        for flag in [POLLHUP, POLLERR, POLLNVAL] {
            let result = ShellPollResult(revents: Int16(flag))
            #expect(result.isTerminal)
            #expect(!result.isReadable)
        }
    }

    @Test func closingASocketPeerProducesTerminalState() {
        var sockets: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &sockets) == 0)
        defer { close(sockets[0]) }
        close(sockets[1])

        var descriptor = pollfd(
            fd: sockets[0],
            events: Int16(POLLIN),
            revents: 0)
        #expect(poll(&descriptor, 1, 100) == 1)
        #expect(ShellPollResult(revents: descriptor.revents).isTerminal)
    }

    @Test func idleHasAnInfiniteTimeout() {
        #expect(ShellDeadlineSet().pollTimeoutMilliseconds == -1)
    }

    @Test func zeroEventSourcesRemainDeadlineDriven() {
        #expect(!ShellPollInterestPolicy.shouldRegister(
            fileDescriptor: 70,
            events: 0))
        #expect(ShellPollInterestPolicy.shouldRegister(
            fileDescriptor: 70,
            events: Int16(POLLIN)))
        #expect(!ShellPollInterestPolicy.shouldRegister(
            fileDescriptor: -1,
            events: Int16(POLLIN)))
    }

    @Test func flushBackpressureAddsWriteInterestWithoutDisconnecting() {
        #expect(ShellFlushDisposition.classify(
            result: -1, error: EAGAIN) == .needsWrite)
        #expect(ShellFlushDisposition.classify(
            result: -1, error: EPIPE) == .disconnected(error: EPIPE))
        #expect(ShellFlushDisposition.classify(
            result: 0, error: EPIPE) == .flushed)
    }

    @Test func earliestDeadlineWinsAndRoundsUp() {
        var deadlines = ShellDeadlineSet()
        deadlines.add(relativeNanoseconds: 8_333_333)
        deadlines.add(relativeMicroseconds: 2_500)
        deadlines.add(relativeNanoseconds: 40_000_000)
        #expect(deadlines.earliestNanoseconds == 2_500_000)
        #expect(deadlines.pollTimeoutMilliseconds == 3)
    }

    @Test func outputRefreshControlsPresentationInterval() {
        let sixty = ShellPresentationTiming.intervalNanoseconds(
            refreshMillihertz: 60_000)
        let oneTwenty = ShellPresentationTiming.intervalNanoseconds(
            refreshMillihertz: 120_000)
        #expect(sixty == 16_666_666)
        #expect(oneTwenty == 8_333_333)
        #expect(oneTwenty! < sixty!)
    }

    @Test func aStalledPresentationDeadlineRebases() {
        #expect(ShellPresentationTiming.nextDeadline(
            previous: 100,
            now: 1_000,
            interval: 10) == 1_010)
        #expect(ShellPresentationTiming.nextDeadline(
            previous: 100,
            now: 105,
            interval: 10) == 110)
    }

    @Test func noDemandMeansNoRenderEvenAtADeadline() {
        #expect(!ShellFrameDecision.shouldRender(
            workPending: false, deadline: 10, now: 10))
        #expect(!ShellFrameDecision.shouldRender(
            workPending: true, deadline: 11, now: 10))
        #expect(ShellFrameDecision.shouldRender(
            workPending: true, deadline: 10, now: 10))
    }

    @Test func rendererWakeWritesCoalesceIntoOnePollTurn() {
        let fd = nucleus_shell_create_render_wake_fd()
        #expect(fd >= 0)
        defer { close(fd) }
        #expect(nucleus_shell_signal_render_wake(fd) != 0)
        #expect(nucleus_shell_signal_render_wake(fd) != 0)
        #expect(nucleus_shell_signal_render_wake(fd) != 0)

        var descriptor = pollfd(
            fd: fd, events: Int16(POLLIN), revents: 0)
        #expect(poll(&descriptor, 1, 0) == 1)
        #expect(nucleus_shell_consume_render_wake(fd) == 1)
        descriptor.revents = 0
        #expect(poll(&descriptor, 1, 0) == 0)
    }
}
