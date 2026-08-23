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
func swiftCxxInteropRenderingExpandsTheWebsiteTableOfContents() throws {
    let source = Data(
        """
        ---
        title: Guide
        ---

        ## Table of Contents
        {:.no_toc}

        * TOC
        {:toc}

        ## First Section
        ### Using `std::span`
        #### C++ Details
        """.utf8)
    let rendered = try #require(
        String(
            data: SwiftCxxInteropSkillDocumentation.renderTableOfContents(in: source),
            encoding: .utf8))
    #expect(!rendered.contains("no_toc"))
    #expect(!rendered.contains("{:toc}"))
    #expect(rendered.contains("- [First Section](#first-section)"))
    #expect(rendered.contains("  - [Using `std::span`](#using-stdspan)"))
    #expect(rendered.contains("    - [C++ Details](#c-details)"))
}

@Test
func swiftCxxInteropFreshnessComparesContentInsteadOfRepositoryRevision() async throws {
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
    let safeInterop = try Data(
        contentsOf: URL(
            fileURLWithPath: skillRoot.appending(
                "references/safe-interop.md"
            ).string))
    try await SwiftCxxInteropSkillDocumentation.verify(
        .init(
            revision: String(repeating: "f", count: 40),
            documentation: documentation,
            safeInterop: safeInterop,
            license: license),
        at: repositoryRoot)

    var changedDocumentation = documentation
    changedDocumentation.append(UInt8(ascii: "\n"))
    await #expect(throws: SkillDocumentationFailure.self) {
        try await SwiftCxxInteropSkillDocumentation.verify(
            .init(
                revision: String(repeating: "f", count: 40),
                documentation: changedDocumentation,
                safeInterop: safeInterop,
                license: license),
            at: repositoryRoot)
    }

    var changedSafeInterop = safeInterop
    changedSafeInterop.append(UInt8(ascii: "\n"))
    await #expect(throws: SkillDocumentationFailure.self) {
        try await SwiftCxxInteropSkillDocumentation.verify(
            .init(
                revision: String(repeating: "f", count: 40),
                documentation: documentation,
                safeInterop: changedSafeInterop,
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
