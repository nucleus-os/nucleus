import Testing
@testable import ColliderRuntime

@Test func rootColliderTestProductResolvesValidationResources() throws {
    for fixture in ToolchainValidationFixtures.Fixture.allCases {
        let resource = try ToolchainValidationFixtures.resourceURL(for: fixture)
        #expect(resource.lastPathComponent == fixture.rawValue)
    }
}
