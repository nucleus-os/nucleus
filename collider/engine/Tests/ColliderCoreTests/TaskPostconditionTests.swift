import ColliderCore
import Foundation
import SystemPackage
import Testing
@testable import ColliderRuntime

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
                validation: .nonEmptyDirectory),
        ],
        operation: .sequence([
            .createDirectory(shared),
            .writeFile(marker, bytes: Array("ready".utf8)),
        ]))
    let runtime = ColliderRuntime()
    let state = FilePath(directory.appendingPathComponent("state").path)

    let first = try await runtime.execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: state)
    let clean = try await runtime.execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: state,
        options: TaskExecutionOptions(dryRun: true))
    try FileManager.default.removeItem(atPath: marker.string)
    let missing = try await runtime.execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: state,
        options: TaskExecutionOptions(dryRun: true))
    let changed = TaskDeclaration(
        id: task.id,
        component: task.component,
        postconditions: [
            PathPostcondition(path: shared, validation: .exists),
        ],
        operation: task.operation)
    let changedPlan = try await runtime.execute(
        graph: TaskGraph([changed]),
        selected: [changed.id],
        stateRoot: state,
        options: TaskExecutionOptions(dryRun: true))

    #expect(first.executed == [task.id])
    #expect(clean.plan[0].isClean)
    #expect(!missing.plan[0].isClean)
    #expect(missing.plan[0].explanation.contains("validation failed"))
    #expect(!changedPlan.plan[0].isClean)
    #expect(changedPlan.plan[0].explanation == "input identity changed")
}
