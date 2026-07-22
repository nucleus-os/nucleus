import Dispatch
import Glibc
import NucleusShellRuntime
import NucleusShellSignalC

@main
struct NucleusShellThreadSanitizerHarness {
    static func main() {
        let producerCount = 8
        let requestsPerProducer = 2_048
        var exercisedDescriptorReuse = false

        for _ in 0..<64 {
            guard let sink = ShellRenderWakeSink() else {
                fatalError("failed to create shell render wake sink")
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

            let replacement = nucleus_shell_create_render_wake_fd()
            precondition(replacement >= 0)
            exercisedDescriptorReuse = exercisedDescriptorReuse
                || replacement == originalDescriptor
            for _ in 0..<256 { sink.signalRenderWork() }
            precondition(
                nucleus_shell_consume_render_wake(replacement) == 0,
                "a late shell render wake targeted a recycled descriptor")
            close(replacement)
        }

        precondition(
            exercisedDescriptorReuse,
            "shell render-wake stress did not exercise descriptor-number reuse")
    }
}
