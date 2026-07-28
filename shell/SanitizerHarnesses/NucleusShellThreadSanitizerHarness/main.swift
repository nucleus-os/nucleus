@_spi(NucleusShellTesting) import NucleusShellRuntime

@main
struct NucleusShellThreadSanitizerHarness {
    static func main() {
        runShellThreadSanitizerHarness()
    }
}
