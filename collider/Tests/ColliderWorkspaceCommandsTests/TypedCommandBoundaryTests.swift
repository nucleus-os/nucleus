import Testing

@testable import ColliderWorkspaceCommands

@Test
func androidLeavesConstructOneOpinionatedOperationPerEntrypoint() throws {
    let build = try Android.Build.parse(["--dry-run"])
    #expect(build.operation == .build)
    #expect(build.taskOptions.dryRun)

    let native = try Android.Native.parse([])
    #expect(native.operation == .native)

    let verify = try Android.Verify.parse([])
    #expect(verify.operation == .verify)

    #expect(throws: (any Error).self) {
        try Android.Build.parse(["--", "--stacktrace"])
    }
    #expect(throws: (any Error).self) {
        try Android.Verify.parse(["/tmp/libNucleusAndroid.so"])
    }
}

@Test
func swiftSDKRebuildAlwaysBuildsTheCompleteTargetSet() throws {
    _ = try SwiftSDK.Rebuild.parse([])
    #expect(throws: (any Error).self) {
        try SwiftSDK.Rebuild.parse(["--arch", "aarch64"])
    }
    #expect(throws: (any Error).self) {
        try SwiftSDK.Rebuild.parse(["--reconfigure"])
    }
}

@Test
func boundedCommandValuesRejectUnknownSpellingsDuringParsing() {
    for arguments in [
        ["doctor", "unknown"],
        ["sanitize", "memory"],
    ] {
        #expect(throws: (any Error).self) {
            switch arguments.first {
            case "doctor":
                _ = try Doctor.parse(Array(arguments.dropFirst()))
            case "sanitize":
                _ = try Sanitize.parse(Array(arguments.dropFirst()))
            default:
                Issue.record("unexpected command fixture")
            }
        }
    }
}
