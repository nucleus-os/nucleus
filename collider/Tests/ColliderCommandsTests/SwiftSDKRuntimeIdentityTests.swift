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
    let inputs = try SwiftTargetSDKInputs.load(
        from: FilePath(recipe.appendingPathComponent("target-sdk-inputs.json").path))
    let builder = FilePath(
        recipe.appendingPathComponent("runtime-build-container", isDirectory: true).path)
    let preset = FilePath(
        recipe.appendingPathComponent("nucleus-target-runtime-presets.ini").path)
    let sysroot = FilePath(
        recipe.appendingPathComponent("prepare-linux-sysroot.sh").path)
    let arm64 = try #require(
        inputs.linuxTargets.first { $0.architecture == .arm64 })
    let amd64 = try #require(
        inputs.linuxTargets.first { $0.architecture == .amd64 })

    let first = try swiftTargetRuntimeBuildID(
        inputs: inputs,
        target: arm64,
        sourceID: "source-a",
        runtimeBuilderContext: builder,
        runtimePreset: preset,
        sysrootPreparer: sysroot)
    let repeated = try swiftTargetRuntimeBuildID(
        inputs: inputs,
        target: arm64,
        sourceID: "source-a",
        runtimeBuilderContext: builder,
        runtimePreset: preset,
        sysrootPreparer: sysroot)
    let changedSource = try swiftTargetRuntimeBuildID(
        inputs: inputs,
        target: arm64,
        sourceID: "source-b",
        runtimeBuilderContext: builder,
        runtimePreset: preset,
        sysrootPreparer: sysroot)
    let otherArchitecture = try swiftTargetRuntimeBuildID(
        inputs: inputs,
        target: amd64,
        sourceID: "source-a",
        runtimeBuilderContext: builder,
        runtimePreset: preset,
        sysrootPreparer: sysroot)

    #expect(first.count == 24)
    #expect(repeated == first)
    #expect(changedSource != first)
    #expect(otherArchitecture != first)
}
