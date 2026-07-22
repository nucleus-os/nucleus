@_spi(NucleusCompositor) import NucleusReactRuntime
import NucleusUI
import NucleusTextBackend
import NucleusUIEmbedder
import NucleusLayers
import NucleusRenderModel
import NucleusRenderHost
import NucleusAppHostBundle
import NucleusShellWayland
import NucleusShellPasteboard
import NucleusShellInput
import NucleusShellAuth
import NucleusLinuxDBus
import NucleusLinuxAccessibility
import NucleusShellServices
import NucleusLinuxEnvironment
import NucleusLinuxReactor
import NucleusShellProduct
import NucleusShellRender
import NucleusShellLoop
import NucleusRenderer
import NucleusShellSignalC
import Foundation
import Synchronization
import Tracy
#if canImport(Glibc)
import Glibc
#endif

/// Thread-safe hand-off from the JS thread (the facade's command callback) to the main-actor
/// frame loop. The Wayland client is single-threaded, so commands are queued here and applied
/// on the loop rather than touched from the JS thread.
final class CommandInbox: Sendable {
    private let pending = Mutex<[(String, String)]>([])
    private let wakeSink: any AsyncRenderWakeSink

    init(wakeSink: any AsyncRenderWakeSink) {
        self.wakeSink = wakeSink
    }

    func push(_ command: String, _ argsJson: String) {
        let shouldWake = pending.withLock {
            let wasEmpty = $0.isEmpty
            $0.append((command, argsJson))
            return wasEmpty
        }
        if shouldWake { wakeSink.signalRenderWork() }
    }
    func drain() -> [(String, String)] {
        pending.withLock {
            let output = $0
            $0.removeAll(keepingCapacity: true)
            return output
        }
    }
}

struct ShellLoopCounters {
    private var pollWakeCount: UInt64 = 0
    private var pollTimeoutCount: UInt64 = 0
    private var completionBudgetExhaustionCount: UInt64 = 0
    private var idlePollWakeCount: UInt64 = 0
    private var renderedFrameCount: UInt64 = 0

    mutating func record(_ batch: LinuxReactorBatch) {
        pollWakeCount &+= 1
        if batch.didReachDeadline { pollTimeoutCount &+= 1 }
        if batch.didExhaustCompletionBudget {
            completionBudgetExhaustionCount &+= 1
        }
        Trace.plot("swift.shell.loop.poll_wakes", pollWakeCount)
        Trace.plot("swift.shell.loop.poll_timeouts", pollTimeoutCount)
        Trace.plot(
            "swift.shell.loop.completion_budget_exhaustions",
            completionBudgetExhaustionCount)
        if let latency = batch.executorResumeLatencyNanoseconds {
            Trace.plot(
                "swift.shell.loop.main_actor_resume_ms",
                Double(latency) / 1_000_000.0)
        }
    }

    mutating func recordIdleWake() {
        idlePollWakeCount &+= 1
        Trace.plot("swift.shell.loop.idle_poll_wakes", idlePollWakeCount)
    }

    mutating func recordRenderedFrame() {
        renderedFrameCount &+= 1
        Trace.plot("swift.shell.loop.rendered_frames", renderedFrameCount)
    }
}

struct ShellReactorWaitPlan {
    var interests: [LinuxReactorInterest]
    var timeoutNanoseconds: UInt64?
}

struct ShellReactorBatchOutcome {
    var hadHostEvent = false
    var shouldStop = false
    var processedSystemBus = false
    var processedAccessibility = false
    var processedEnvironment = false
}

func monotonicNowNs() -> UInt64 {
    var ts = timespec()
    clock_gettime(CLOCK_MONOTONIC, &ts)
    return UInt64(ts.tv_sec) &* 1_000_000_000 &+ UInt64(ts.tv_nsec)
}

func clampedAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    let result = lhs.addingReportingOverflow(rhs)
    return result.overflow ? .max : result.partialValue
}
