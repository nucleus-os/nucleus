import Foundation
import SystemPackage
import Testing

@testable import ColliderCommands

@Test func SwiftToolchainStorageSeparatesArtifactsFromIncrementalBuildState() {
    let cache = URL(fileURLWithPath: "/cache", isDirectory: true)
    let first = SwiftToolchainStoragePaths(
        cacheRoot: cache,
        sourceID: "111111111111111111111111")
    let second = SwiftToolchainStoragePaths(
        cacheRoot: cache,
        sourceID: "222222222222222222222222")

    #expect(first.artifactRoot != second.artifactRoot)
    #expect(first.platformID != second.platformID)
    #expect(first.buildLaneRoot == second.buildLaneRoot)
    #expect(first.buildWorkspace == second.buildWorkspace)
    #expect(first.compilerCache == second.compilerCache)
    #expect(first.rebuildLock == second.rebuildLock)
    #expect(
        first.buildWorkspace.path
            == "/cache/nucleus/swift-build-workspaces/linux-arm64-host/workspace")
    #expect(
        first.artifactRoot.path
            == "/cache/nucleus/swift-platforms/111111111111111111111111-linux-arm64-host")
}

@Test func CompletedActiveSwiftGenerationIsReusable() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-swift-generation-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let artifactID = "aaaaaaaaaaaaaaaaaaaaaaaa"
    let generation = root.appendingPathComponent(
        "generations/\(artifactID)", isDirectory: true)
    let driver = generation.appendingPathComponent(
        "toolchain/usr/bin/swift-driver")
    let bundleName = "swift-source_android.artifactbundle"
    let bundle = generation.appendingPathComponent(
        "android/\(bundleName)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: driver.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: bundle, withIntermediateDirectories: true)
    try Data("driver".utf8).write(to: driver)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: driver.path)
    try Data("\(artifactID)\n".utf8).write(
        to: generation.appendingPathComponent(".nucleus-toolchain-artifact"))
    let active = root.appendingPathComponent("current")
    try FileManager.default.createSymbolicLink(
        at: active,
        withDestinationURL: generation)
    let discovery = root.appendingPathComponent("discovery/\(bundleName)")
    try FileManager.default.createDirectory(
        at: discovery.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        at: discovery,
        withDestinationURL: active.appendingPathComponent(
            "android/\(bundleName)", isDirectory: true))

    #expect(
        isReusableSwiftToolchainGeneration(
            generation: generation,
            active: active,
            sdkDiscoveryLink: discovery,
            bundleName: bundleName,
            artifactID: artifactID))

    try Data("different\n".utf8).write(
        to: generation.appendingPathComponent(".nucleus-toolchain-artifact"))
    #expect(
        !isReusableSwiftToolchainGeneration(
            generation: generation,
            active: active,
            sdkDiscoveryLink: discovery,
            bundleName: bundleName,
            artifactID: artifactID))
}

@Test func SwiftToolchainArtifactIdentityTracksOutputAffectingInputs() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-swift-identity-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let builder = root.appendingPathComponent("builder", isDirectory: true)
    let recipe = root.appendingPathComponent("recipe", isDirectory: true)
    try FileManager.default.createDirectory(
        at: builder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: recipe, withIntermediateDirectories: true)
    let files = [
        "builder/Containerfile", "preset.ini", "overrides.cmake",
        "source.properties", "recipe/Recipe.swift", "HostWorkflow.swift",
    ]
    for file in files {
        let url = root.appendingPathComponent(file)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(file.utf8).write(to: url)
    }
    func identity(sourceID: String, architectures: [String]) throws -> String {
        try swiftToolchainArtifactID(
            sourceID: sourceID,
            builderContext: FilePath(builder.path),
            preset: FilePath(root.appendingPathComponent("preset.ini").path),
            cmakeOverrides: FilePath(
                root.appendingPathComponent("overrides.cmake").path),
            ndkProperties: FilePath(
                root.appendingPathComponent("source.properties").path),
            recipeSource: FilePath(recipe.path),
            hostWorkflowSource: FilePath(
                root.appendingPathComponent("HostWorkflow.swift").path),
            architectures: architectures,
            apiLevel: 37)
    }

    let baseline = try identity(sourceID: "source-a", architectures: ["aarch64"])
    #expect(baseline.count == 24)
    #expect(
        try identity(sourceID: "source-a", architectures: ["aarch64"])
            == baseline)
    #expect(
        try identity(sourceID: "source-b", architectures: ["aarch64"])
            != baseline)
    #expect(
        try identity(
            sourceID: "source-a", architectures: ["aarch64", "x86_64"])
            != baseline)
}
