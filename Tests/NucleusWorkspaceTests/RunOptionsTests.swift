import Testing
@testable import NucleusWorkspace

@Test
func plainRunBuildsTheDebugSessionWithoutInstrumentation() throws {
    let options = try #require(try RunOptions.parse([]))

    #expect(options.build)
    #expect(options.configuration == "debug")
    #expect(!options.tracy)
    #expect(options.sanitizer == nil)
    #expect(options.compositorArguments.isEmpty)
    #expect(options.buildOptions.identity == "debug-plain-unsanitized")
}

@Test
func runParsesAUnifiedInstrumentedCapture() throws {
    let options = try #require(try RunOptions.parse([
        "--tracy",
        "--seconds", "20",
        "--sanitize", "address",
        "--vk-validation",
        "--present-mode", "mailbox_latest_wins",
        "--optimize", "release",
        "--", "--fixture-output", "DP-1",
    ]))

    #expect(options.tracy)
    #expect(options.seconds == 20)
    #expect(options.sanitizer == .address)
    #expect(options.validation)
    #expect(options.presentMode == "mailbox_latest_wins")
    #expect(options.configuration == "release")
    #expect(options.compositorArguments == ["--fixture-output", "DP-1"])
    #expect(options.buildOptions.identity == "release-tracy-address")
}

@Test
func tracyDefaultsToAReleaseRuntime() throws {
    let options = try #require(try RunOptions.parse(["--tracy"]))

    #expect(options.configuration == "release")
    #expect(options.buildOptions.identity == "release-tracy-unsanitized")
}

@Test
func durationIsAvailableWithoutTracy() throws {
    let options = try #require(try RunOptions.parse(["--seconds", "5"]))
    #expect(options.seconds == 5)
    #expect(!options.tracy)
    #expect(options.configuration == "debug")

    #expect(try RunOptions.parse([
        "--sanitize", "address", "--seconds", "5",
    ])?.seconds == 5)
    #expect(try RunOptions.parse([
        "--valgrind", "--seconds", "5",
    ])?.seconds == 5)
    #expect(throws: WorkspaceFailure.self) {
        try RunOptions.parse(["--seconds", "0"])
    }
}

@Test
func tracyCaptureOptionsRequireTracy() {
    #expect(throws: WorkspaceFailure.self) {
        try RunOptions.parse(["--host", "192.0.2.10", "--valgrind"])
    }
}

@Test
func valgrindRejectsCompilerSanitizersAndTracy() {
    #expect(throws: WorkspaceFailure.self) {
        try RunOptions.parse(["--valgrind", "--sanitize", "thread"])
    }
    #expect(throws: WorkspaceFailure.self) {
        try RunOptions.parse(["--valgrind", "--tracy"])
    }
}

@Test
func runtimeBuildMetadataDistinguishesInstrumentedArtifacts() {
    let plain = RuntimeBuildOptions()
    let address = RuntimeBuildOptions(sanitizer: .address)

    #expect(plain.metadata != address.metadata)
    #expect(plain.identity == "debug-plain-unsanitized")
    #expect(address.identity == "debug-plain-address")
}
