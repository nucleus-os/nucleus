import Foundation
import SwiftTargetSDKColliderRecipe
import SystemPackage
import Testing

@testable import ColliderCommands

@Test func targetSDKTaskEnvironmentUsesRuntimeSourceIdentity() {
    let environment = swiftTargetSDKTaskEnvironment(
        [
            "NUCLEUS_SWIFT_SOURCE_ID": "checkout-source",
            "NUCLEUS_BUILD_JOBS": "12",
        ],
        runtimeSourceID: "runtime-source")

    #expect(environment["NUCLEUS_SWIFT_SOURCE_ID"] == "runtime-source")
    #expect(environment["NUCLEUS_BUILD_JOBS"] == "12")
}

@Test func targetRuntimeIdentityChangesOnlyWithRuntimeInputs() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let recipe = root.appendingPathComponent("swift-sdk", isDirectory: true)
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
    let sdkPackagesChanged = try swiftTargetRuntimeBuildID(
        inputs: inputs,
        target: SwiftTargetSDKInputs.LinuxTarget(
            architecture: arm64.architecture,
            runtimeUbuntuPackages: arm64.runtimeUbuntuPackages,
            sdkUbuntuPackages: amd64.sdkUbuntuPackages),
        sourceID: "source-a",
        runtimeBuilderContext: builder,
        runtimePreset: preset,
        sysrootPreparer: sysroot)
    let runtimePackagesChanged = try swiftTargetRuntimeBuildID(
        inputs: inputs,
        target: SwiftTargetSDKInputs.LinuxTarget(
            architecture: arm64.architecture,
            runtimeUbuntuPackages: amd64.runtimeUbuntuPackages,
            sdkUbuntuPackages: arm64.sdkUbuntuPackages),
        sourceID: "source-a",
        runtimeBuilderContext: builder,
        runtimePreset: preset,
        sysrootPreparer: sysroot)

    #expect(first.count == 24)
    #expect(repeated == first)
    #expect(changedSource != first)
    #expect(otherArchitecture != first)
    #expect(sdkPackagesChanged == first)
    #expect(runtimePackagesChanged != first)
}

@Test func targetSDKArtifactIdentityIncludesGeneratorSource() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let recipe = root.appendingPathComponent("swift-sdk", isDirectory: true)
    let inputs = FilePath(recipe.appendingPathComponent("target-sdk-inputs.json").path)
    let fixture = FilePath(
        root.appendingPathComponent(
            "swift-sdk/validation/AndroidSDKConsumer",
            isDirectory: true
        ).path)
    let validator = FilePath(
        recipe.appendingPathComponent("validate-target-sdk-artifacts.sh").path)
    let builder = FilePath(
        recipe.appendingPathComponent("runtime-build-container", isDirectory: true).path)
    let preset = FilePath(
        recipe.appendingPathComponent("nucleus-target-runtime-presets.ini").path)
    let sysroot = FilePath(
        recipe.appendingPathComponent("prepare-linux-sysroot.sh").path)
    let pkgConfig = FilePath(
        recipe.appendingPathComponent("pkgconfig", isDirectory: true).path)

    let first = try swiftTargetSDKArtifactID(
        inputsFile: inputs,
        validationFixture: fixture,
        validator: validator,
        ndkIdentity: "ndk-fixture",
        xcodeIdentity: "Xcode fixture",
        sourceID: "runtime-source",
        runtimeBuilderContext: builder,
        runtimePreset: preset,
        sysrootPreparer: sysroot,
        pkgConfigDirectory: pkgConfig,
        generatorSourceID: "generator-a")
    let changedGenerator = try swiftTargetSDKArtifactID(
        inputsFile: inputs,
        validationFixture: fixture,
        validator: validator,
        ndkIdentity: "ndk-fixture",
        xcodeIdentity: "Xcode fixture",
        sourceID: "runtime-source",
        runtimeBuilderContext: builder,
        runtimePreset: preset,
        sysrootPreparer: sysroot,
        pkgConfigDirectory: pkgConfig,
        generatorSourceID: "generator-b")

    #expect(first.count == 24)
    #expect(changedGenerator != first)
}
