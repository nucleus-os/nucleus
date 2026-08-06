#if os(Linux)
import Foundation
import Testing

@testable import ColliderWorkspaceCommands
import NucleusSessionProtocol
@testable import ColliderLinuxOperations

@Test
func plainRunBuildsTheDebugSessionWithoutInstrumentation() throws {
    let options = try parsedRunOptions([])

    #expect(options.build)
    #expect(options.effectiveOptimization == .debug)
    #expect(!options.tracy)
    #expect(!options.android)
    #expect(options.sanitizer == nil)
    #expect(options.compositorArguments.isEmpty)
    #expect(options.buildOptions.identity == "debug-plain-unsanitized")
}

@Test
func runParsesAUnifiedInstrumentedCapture() throws {
    let options = try parsedRunOptions([
        "--tracy",
        "--seconds", "20",
        "--scale", "1.25",
        "--sanitize", "address",
        "--android",
        "--vk-validation",
        "--present-mode", "mailbox_latest_wins",
        "--optimize", "release",
        "--", "--fixture-output", "DP-1",
    ])

    #expect(options.tracy)
    #expect(options.seconds == 20)
    #expect(options.scale == 1.25)
    #expect(options.sanitizer == .address)
    #expect(options.android)
    #expect(options.validation)
    #expect(options.presentMode == .mailboxLatestWins)
    #expect(options.effectiveOptimization == .release)
    #expect(options.compositorArguments == ["--fixture-output", "DP-1"])
    #expect(options.buildOptions.identity == "release-tracy-address")
}

@Test
func androidRuntimeLogWindowFollowsTheProductionDiagnostics() {
    let invocation = AndroidRuntimeLogWindowInvocation(
        diagnosticsDirectory: URL(
            fileURLWithPath: "/runs/current/android-runtime",
            isDirectory: true))

    #expect(invocation.executable == "kitty")
    #expect(
        invocation.arguments == [
            "--class", "nucleus.android.runtime-log",
            "--title", "Nucleus Android Runtime",
            "--", "tail", "--lines=200", "--follow=name", "--retry",
            "/runs/current/android-runtime/android-kmsg.log",
            "/runs/current/android-runtime/android-logcat.log",
            "/runs/current/android-runtime/android-gfxstream-broker.log",
            "/runs/current/android-runtime/android-display-host.log",
            "/runs/current/android-runtime/android-progress.jsonl",
        ])
}

@Test
func runProducesOneTypedConfigurationForBothSessionChildren() throws {
    let options = try parsedRunOptions([
        "--tracy",
        "--scale", "1.5",
        "--present-mode", "mailbox_latest_wins",
        "--vk-validation",
        "--trace-diagnostics",
        "--drm-device", "/dev/dri/renderD129",
        "--wallpaper", "~/Pictures/typed.jpeg",
    ])
    var configuredOptions = options
    configuredOptions.xwaylandExecutablePath = "/usr/bin/Xwayland"
    let configuration = try configuredOptions.sessionConfiguration

    #expect(configuration.outputScale == 1.5)
    #expect(configuration.presentMode == .mailboxLatestWins)
    #expect(configuration.enableVulkanValidation)
    #expect(configuration.traceProtocol)
    #expect(configuration.traceDrmDemand)
    #expect(configuration.drmDevicePath == "/dev/dri/renderD129")
    #expect(configuration.wallpaperPath == "~/Pictures/typed.jpeg")
    #expect(configuration.xwaylandExecutablePath == "/usr/bin/Xwayland")
    #expect(
        try SessionConfiguration(encoded: configuration.encoded)
            == configuration)
}

@Test
func scaleIsAvailableInEveryRunModeAndRejectsInvalidValues() throws {
    #expect(try parsedRunOptions(["--scale", "2"]).scale == 2)
    #expect(
        try parsedRunOptions([
            "--tracy", "--scale", "1.5",
        ]).scale == 1.5)
    #expect(
        try parsedRunOptions([
            "--sanitize", "thread", "--scale", "1.25",
        ]).scale == 1.25)

    for invalid in [0.0, -1.0, .nan, .infinity] {
        var options = try RunOptions.parse([])
        options.scale = invalid
        #expect(throws: WorkspaceFailure.self) {
            try options.validated()
        }
    }
    #expect(throws: (any Error).self) {
        try RunOptions.parse(["--scale", "not-a-number"])
    }
}

@Test
func tracyDefaultsToAReleaseRuntime() throws {
    let options = try parsedRunOptions(["--tracy"])

    #expect(options.effectiveOptimization == .release)
    #expect(options.buildOptions.identity == "release-tracy-unsanitized")
}

@Test
func durationIsAvailableWithoutTracy() throws {
    let options = try parsedRunOptions(["--seconds", "5"])
    #expect(options.seconds == 5)
    #expect(!options.tracy)
    #expect(options.effectiveOptimization == .debug)

    #expect(
        try parsedRunOptions([
            "--sanitize", "address", "--seconds", "5",
        ]).seconds == 5)
    #expect(
        try parsedRunOptions([
            "--valgrind", "--seconds", "5",
        ]).seconds == 5)

    var invalid = try RunOptions.parse([])
    invalid.seconds = 0
    #expect(throws: WorkspaceFailure.self) {
        try invalid.validated()
    }
}

@Test
func tracyCaptureOptionsRequireTracy() throws {
    var options = try RunOptions.parse([])
    options.host = "192.0.2.10"
    options.valgrind = true
    #expect(throws: WorkspaceFailure.self) {
        try options.validated()
    }
}

@Test
func valgrindRejectsCompilerSanitizersAndTracy() throws {
    var sanitizer = try RunOptions.parse([])
    sanitizer.valgrind = true
    sanitizer.sanitizer = .thread
    #expect(throws: WorkspaceFailure.self) {
        try sanitizer.validated()
    }

    var tracy = try RunOptions.parse([])
    tracy.valgrind = true
    tracy.tracy = true
    #expect(throws: WorkspaceFailure.self) {
        try tracy.validated()
    }
}

@Test
func runtimeBuildMetadataDistinguishesInstrumentedArtifacts() {
    let plain = RuntimeBuildSelection()
    let address = RuntimeBuildSelection(sanitizer: .address)

    #expect(plain.metadata != address.metadata)
    #expect(plain.identity == "debug-plain-unsanitized")
    #expect(address.identity == "debug-plain-address")
}

private func parsedRunOptions(_ arguments: [String]) throws -> RunOptions {
    try RunOptions.parse(arguments).validated()
}
#endif
