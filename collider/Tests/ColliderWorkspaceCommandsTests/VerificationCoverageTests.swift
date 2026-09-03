import ColliderCore
import LinuxColliderRecipe
import Testing

@testable import ColliderWorkspaceCommands

/// A lane no sweep selects is verified by nobody. The browser lane was added by
/// name for `.build` and not for `.testDefault`, which left its focused Ozone
/// and Viz presenter suites out of the plan entirely -- absent rather than
/// skipped as clean, so no run reported them and nothing failed. That is the
/// same condition that had already let three defects sit in the CEF build lane
/// until the day something finally compiled it.
@Test func verifyingEverythingSelectsBothHalvesOfTheBrowserLane() {
    let requests = ComponentRegistry.verificationRequests(selection: nil)
    let browser = requests.filter { $0.spelling == "browser" }

    #expect(browser.contains { $0.entrypoint == ComponentEntrypointID.build })
    #expect(browser.contains { $0.entrypoint == ComponentEntrypointID.testDefault })
    #expect(browser.count == 2)
}

/// Packaging consumes what building and testing produce, so it is asked for
/// last. Order is the only thing expressing that here.
@Test func verificationAsksForPackagingAfterWhatItConsumes() {
    let requests = ComponentRegistry.verificationRequests(selection: nil)
    let packaging = requests.lastIndex { $0.entrypoint == LinuxEntrypoints.packageRuntime }
    let browserBuild = requests.firstIndex {
        $0.spelling == "browser" && $0.entrypoint == ComponentEntrypointID.build
    }
    let browserTest = requests.firstIndex {
        $0.spelling == "browser" && $0.entrypoint == ComponentEntrypointID.testDefault
    }

    #expect(packaging != nil)
    #expect(browserBuild != nil)
    #expect(browserTest != nil)
    #expect(browserBuild! < packaging!)
    #expect(browserTest! < packaging!)
}

/// A named selection verifies what was named and nothing else. The extra lanes
/// exist because "everything" has to mean everything, not because they are
/// appended unconditionally.
@Test func verifyingOneComponentDoesNotDragInEveryOtherLane() {
    let requests = ComponentRegistry.verificationRequests(selection: "core")

    #expect(requests.allSatisfy { $0.spelling == "core" })
    #expect(
        requests.map(\.entrypoint)
            == [ComponentEntrypointID.build, ComponentEntrypointID.testDefault])
    #expect(ComponentRegistry.verificationCoversEveryLane("all"))
    #expect(ComponentRegistry.verificationCoversEveryLane(nil))
    #expect(!ComponentRegistry.verificationCoversEveryLane("core"))
}
