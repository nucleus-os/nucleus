import Testing
@testable import NucleusWorkspace

@Test
func chromiumCommandHasOneOpinionatedOperationSurface() throws {
    #expect(try ChromiumCommand.parse(["doctor"]) == .doctor)
    #expect(try ChromiumCommand.parse(["bootstrap"]) == .bootstrap)
    #expect(try ChromiumCommand.parse(["build"]) == .build)
    #expect(try ChromiumCommand.parse(["test"]) == .test)
    #expect(try ChromiumCommand.parse(["install"]) == .install)

    #expect(throws: WorkspaceFailure.self) {
        try ChromiumCommand.parse(["build", "cef"])
    }
    #expect(throws: WorkspaceFailure.self) {
        try ChromiumCommand.parse(["package-only"])
    }
}
