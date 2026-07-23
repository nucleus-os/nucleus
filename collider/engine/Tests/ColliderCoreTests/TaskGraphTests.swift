import SystemPackage
import Testing
@testable import ColliderCore

@Test func taskGraphOrdersDependenciesOnce() throws {
    let root = TaskDeclaration(
        id: TaskID(rawValue: "root"), component: ComponentID(rawValue: "core"),
        operation: .createDirectory(FilePath("root")))
    let leaf = TaskDeclaration(
        id: TaskID(rawValue: "leaf"), component: ComponentID(rawValue: "core"),
        dependencies: [root.id], operation: .createDirectory(FilePath("leaf")))
    let graph = try TaskGraph([leaf, root])
    #expect(try graph.orderedTasks(selecting: [leaf.id]).map(\.id) == [root.id, leaf.id])
}

@Test func taskGraphRejectsCycles() {
    let firstID = TaskID(rawValue: "first")
    let secondID = TaskID(rawValue: "second")
    #expect(throws: TaskGraphFailure.self) {
        _ = try TaskGraph([
            TaskDeclaration(
                id: firstID, component: ComponentID(rawValue: "core"),
                dependencies: [secondID], operation: .createDirectory(FilePath("first"))),
            TaskDeclaration(
                id: secondID, component: ComponentID(rawValue: "core"),
                dependencies: [firstID], operation: .createDirectory(FilePath("second"))),
        ])
    }
}

@Test func canonicalFramingDistinguishesFieldBoundaries() {
    var first = CanonicalDigestEncoder(schema: 1)
    first.append(tag: 1, string: "ab")
    first.append(tag: 2, string: "c")
    var second = CanonicalDigestEncoder(schema: 1)
    second.append(tag: 1, string: "a")
    second.append(tag: 2, string: "bc")
    #expect(first.bytes != second.bytes)
}
