import ColliderCore
import ColliderEngine
import Foundation
import SystemPackage
import Testing

@testable import ColliderRuntime

@Test func symlinkTargetValidationRejectsADanglingPublication() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-dangling-publication-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let root = FilePath(directory.path)
    let link = root.appending("published")
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.dangling-publication"),
        component: ComponentID(rawValue: "fixture"),
        outputs: [
            OutputDeclaration(path: link, validation: .symlinkTarget)
        ],
        action: try fixtureReplaceSymlinkAction(
            path: link,
            target: "missing-target"))

    await #expect(throws: (any Error).self) {
        _ = try await ColliderEngine(runtime: ColliderRuntime()).execute(
            graph: TaskGraph([task]),
            selected: [task.id],
            stateRoot: root.appending("state"))
    }
}

@Test func sharedPostconditionParticipatesInIdentityAndCleanliness() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-postcondition-\(UUID().uuidString)",
        isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let shared = FilePath(directory.appendingPathComponent("shared").path)
    let marker = shared.appending("marker")
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.postcondition"),
        component: ComponentID(rawValue: "fixture"),
        postconditions: [
            PathPostcondition(
                path: shared,
                validation: .nonEmptyDirectory)
        ],
        action: try fixturePrepareAndWriteAction(
            root: shared,
            file: marker,
            bytes: Array("ready".utf8),
            reset: false))
    let runtime = ColliderRuntime()
    let state = FilePath(directory.appendingPathComponent("state").path)

    let first = try await ColliderEngine(runtime: runtime).execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: state)
    let clean = try await ColliderEngine(runtime: runtime).execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: state,
        options: TaskExecutionOptions(dryRun: true))
    try FileManager.default.removeItem(atPath: marker.string)
    let missing = try await ColliderEngine(runtime: runtime).execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: state,
        options: TaskExecutionOptions(dryRun: true))
    let changed = TaskDeclaration(
        id: task.id,
        component: task.component,
        postconditions: [
            PathPostcondition(path: shared, validation: .exists)
        ],
        action: task.action)
    let changedPlan = try await ColliderEngine(runtime: runtime).execute(
        graph: TaskGraph([changed]),
        selected: [changed.id],
        stateRoot: state,
        options: TaskExecutionOptions(dryRun: true))

    #expect(first.executed == [task.id])
    #expect(clean.plan[0].isClean)
    #expect(!missing.plan[0].isClean)
    #expect(missing.plan[0].explanation.contains("validation failed"))
    #expect(!changedPlan.plan[0].isClean)
    #expect(changedPlan.plan[0].explanation.hasPrefix("input identity changed "))
}
