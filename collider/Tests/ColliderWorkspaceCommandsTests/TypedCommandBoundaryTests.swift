import Testing

@testable import ColliderWorkspaceCommands

@Test
func androidTargetsUseTheSharedBuildAndTestVerbs() throws {
    let build = try Build.parse(["android", "--dry-run"])
    #expect(build.component == "android")
    #expect(build.taskOptions.dryRun)

    let native = try Build.parse(["android-native"])
    #expect(native.component == "android-native")

    let verify = try Test.parse(["android"])
    #expect(verify.component == "android")

    #expect(throws: (any Error).self) {
        try Build.parse(["android", "--", "--stacktrace"])
    }
    #expect(throws: (any Error).self) {
        try Test.parse(["android", "/tmp/libNucleusAndroid.so"])
    }
}

@Test
func swiftSDKRebuildAlwaysBuildsTheCompleteTargetSet() throws {
    let command = try Build.parse(["swift-sdk", "--rebuild"])
    #expect(command.component == "swift-sdk")
    #expect(command.taskOptions.rebuild)
    #expect(throws: (any Error).self) {
        try Build.parse(["swift-sdk", "--arch", "aarch64"])
    }
    #expect(throws: (any Error).self) {
        try Build.parse(["swift-sdk", "--reconfigure"])
    }
}

@Test
func boundedCommandValuesRejectUnknownSpellingsDuringParsing() {
    for arguments in [
        ["doctor", "unknown"],
        ["check", "memory-sanitizer"],
    ] {
        #expect(throws: (any Error).self) {
            switch arguments.first {
            case "doctor":
                _ = try Doctor.parse(Array(arguments.dropFirst()))
            case "check":
                _ = try Check.parse(Array(arguments.dropFirst()))
            default:
                Issue.record("unexpected command fixture")
            }
        }
    }
}
