import Foundation
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
            "Regenerate the Collider skill with `collider skill generate`: \(relativePath)")
    }
}
#endif
