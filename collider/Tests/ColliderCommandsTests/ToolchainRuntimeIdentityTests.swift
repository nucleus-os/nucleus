import Foundation
import SwiftTargetSDKColliderRecipe
import SystemPackage
import Testing

@testable import ColliderCommands

@Test func targetRuntimeIdentityChangesOnlyWithRuntimeInputs() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let recipe = root.appendingPathComponent("swift-toolchain", isDirectory: true)
    let lock = try SwiftTargetSDKLock.load(
        from: FilePath(recipe.appendingPathComponent("target-sdk.lock.json").path))
    let builder = FilePath(
        recipe.appendingPathComponent("runtime-build-container", isDirectory: true).path)
    let preset = FilePath(
        recipe.appendingPathComponent("nucleus-target-runtime-presets.ini").path)
    let sysroot = FilePath(
        recipe.appendingPathComponent("prepare-linux-sysroot.sh").path)

    let first = try swiftTargetRuntimeBuildID(
        lock: lock,
        sourceID: "source-a",
        runtimeBuilderContext: builder,
        runtimePreset: preset,
        sysrootPreparer: sysroot)
    let repeated = try swiftTargetRuntimeBuildID(
        lock: lock,
        sourceID: "source-a",
        runtimeBuilderContext: builder,
        runtimePreset: preset,
        sysrootPreparer: sysroot)
    let changedSource = try swiftTargetRuntimeBuildID(
        lock: lock,
        sourceID: "source-b",
        runtimeBuilderContext: builder,
        runtimePreset: preset,
        sysrootPreparer: sysroot)

    #expect(first.count == 24)
    #expect(repeated == first)
    #expect(changedSource != first)
}
