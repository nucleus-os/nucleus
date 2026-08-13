import Foundation
import SystemPackage
import Testing

@testable import ColliderCLI

#if os(macOS)
@Test
func checkedInColliderSkillMatchesCurrentCommandGrammar() throws {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let skillRoot = repositoryRoot.appendingPathComponent(
        ColliderSkillDocumentation.root,
        isDirectory: true)

    for (relativePath, expected) in try ColliderSkillDocumentation.documents() {
        let checkedIn = try Data(
            contentsOf: skillRoot.appendingPathComponent(relativePath))
        #expect(
            checkedIn == expected,
            "Regenerate the Collider skill with `collider skill generate collider`: \(relativePath)"
        )
    }
}

@Test
func checkedInSwiftCxxInteropSkillIsInternallyConsistent() throws {
    let repositoryRoot = FilePath(
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent().path)
    try SwiftCxxInteropSkillDocumentation.verifyCheckedIn(at: repositoryRoot)
}

@Test
func swiftCxxInteropFreshnessComparesContentInsteadOfRepositoryRevision() throws {
    let repositoryRoot = FilePath(
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent().path)
    let skillRoot = repositoryRoot.appending(SwiftCxxInteropSkillDocumentation.root)
    let documentation = try Data(
        contentsOf: URL(
            fileURLWithPath: skillRoot.appending(
                "references/mixing-swift-and-cxx.md"
            ).string))
    let license = try Data(
        contentsOf: URL(
            fileURLWithPath: skillRoot.appending(
                "references/swift-org-license.txt"
            ).string))
    try SwiftCxxInteropSkillDocumentation.verify(
        .init(
            revision: String(repeating: "f", count: 40),
            documentation: documentation,
            license: license),
        at: repositoryRoot)

    var changedDocumentation = documentation
    changedDocumentation.append(UInt8(ascii: "\n"))
    #expect(throws: SkillDocumentationFailure.self) {
        try SwiftCxxInteropSkillDocumentation.verify(
            .init(
                revision: String(repeating: "f", count: 40),
                documentation: changedDocumentation,
                license: license),
            at: repositoryRoot)
    }
}

@Test
func managedSkillCommandGrammarRequiresExplicitMutationTargets() throws {
    _ = try ColliderCommand.parseAsRoot(["skill", "generate", "collider"])
    _ = try ColliderCommand.parseAsRoot(["skill", "sync", "swift-cxx-interop"])
    _ = try ColliderCommand.parseAsRoot(["skill", "verify"])
    _ = try ColliderCommand.parseAsRoot(["skill", "verify", "collider"])
    _ = try ColliderCommand.parseAsRoot(["skill", "verify", "swift-cxx-interop"])

    #expect(throws: (any Error).self) {
        try ColliderCommand.parseAsRoot(["skill", "generate"])
    }
    #expect(throws: (any Error).self) {
        try ColliderCommand.parseAsRoot(["skill", "sync"])
    }
    #expect(throws: (any Error).self) {
        try ColliderCommand.parseAsRoot(["skill", "generate", "swift-cxx-interop"])
    }
    #expect(throws: (any Error).self) {
        try ColliderCommand.parseAsRoot(["skill", "sync", "collider"])
    }
}
#endif
