import Dispatch
import Glibc
import NucleusCompositorRuntime
import NucleusCompositorSignalC
import NucleusCompositorWaylandTestSupport

private let nonblockingSocket: Int32 = 0o4000

@main
struct NucleusCompositorThreadSanitizerHarness {
    @MainActor
    static func main() {
        stressRenderWakeCloseAndDescriptorReuse()
        stressWaylandClientAndRouterTeardown()
    }

    private static func stressRenderWakeCloseAndDescriptorReuse() {
        let producerCount = 8
        let requestsPerProducer = 2_048
        var exercisedDescriptorReuse = false

        for _ in 0..<64 {
            guard let sink = CompositorRenderWakeSink() else {
                fatalError("failed to create compositor render wake sink")
            }
            let originalDescriptor = sink.fileDescriptor
            let group = DispatchGroup()
            for _ in 0..<producerCount {
                group.enter()
                DispatchQueue.global().async {
                    for _ in 0..<requestsPerProducer {
                        sink.signalRenderWork()
                    }
                    group.leave()
                }
            }
            group.enter()
            DispatchQueue.global().async {
                sink.shutdown()
                group.leave()
            }
            group.wait()
            sink.shutdown()

            let preReuse = sink.metrics
            let expectedRequests = UInt64(
                producerCount * requestsPerProducer)
            precondition(preReuse.wakeRequests == expectedRequests)
            precondition(
                preReuse.signalsWritten
                    + preReuse.signalFailures
                    + preReuse.signalsDroppedAfterClose
                    == expectedRequests)
            precondition(preReuse.isClosed)

            let replacement = nucleus_compositor_create_render_wake_fd()
            precondition(replacement >= 0)
            exercisedDescriptorReuse = exercisedDescriptorReuse
                || replacement == originalDescriptor
            for _ in 0..<256 { sink.signalRenderWork() }
            precondition(
                nucleus_compositor_consume_render_wake(replacement) == 0,
                "a late render wake targeted a recycled descriptor")
            close(replacement)

            let final = sink.metrics
            precondition(
                final.signalsDroppedAfterClose
                    == preReuse.signalsDroppedAfterClose + 256)
        }
        precondition(
            exercisedDescriptorReuse,
            "render-wake stress did not exercise descriptor-number reuse")
    }

    @MainActor
    private static func stressWaylandClientAndRouterTeardown() {
        for _ in 0..<256 {
            guard let fixture = WaylandRouterTestFixture() else {
                fatalError("failed to construct Wayland router fixture")
            }
            var sockets: [Int32] = [-1, -1]
            precondition(
                socketpair(
                    AF_UNIX,
                    Int32(SOCK_STREAM.rawValue) | nonblockingSocket,
                    0,
                    &sockets) == 0)
            guard fixture.runtime.attachClient(
                fileDescriptor: sockets[0])
            else {
                close(sockets[0])
                close(sockets[1])
                fatalError("failed to attach in-process Wayland client")
            }

            // wl_display.get_registry(new_id=2). This creates a real wl_registry
            // resource, invokes every registered global's advertisement callback,
            // and then destroys the complete client resource graph on disconnect.
            var request: [UInt8] = []
            appendWord(1, to: &request)
            appendWord((12 << 16) | 1, to: &request)
            appendWord(2, to: &request)
            let written = request.withUnsafeBytes {
                write(sockets[1], $0.baseAddress, $0.count)
            }
            precondition(written == request.count)
            fixture.runtime.dispatchClientsNonBlocking()

            var events = [UInt8](repeating: 0, count: 32 * 1_024)
            _ = events.withUnsafeMutableBytes {
                read(sockets[1], $0.baseAddress, $0.count)
            }
            close(sockets[1])
            fixture.runtime.dispatchClientsNonBlocking()
        }
    }

    private static func appendWord(
        _ value: UInt32,
        to bytes: inout [UInt8]
    ) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
    }
}
