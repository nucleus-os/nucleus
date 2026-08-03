import ColliderCore
import Foundation
import SystemPackage
import Testing

@Test func swiftPMInvocationEmitsSDKIdentityAndTargetTripleTogether() {
    let packageRoot = FilePath("/workspace")
    let scratch = FilePath("/workspace/.nucleus/swiftpm/android")
    let arm64 = SwiftPMInvocation(
        context: SwiftBuildContext(
            packageRoot: packageRoot,
            configuration: .release,
            target: .swiftSDK(
                name: "fixture-sdk",
                targetTriple: "aarch64-unknown-linux-android24"),
            toolchainIdentity: "swiftc@fixture"),
        scratchPath: scratch)
    let amd64 = SwiftPMInvocation(
        context: SwiftBuildContext(
            packageRoot: packageRoot,
            configuration: .release,
            target: .swiftSDK(
                name: "fixture-sdk",
                targetTriple: "x86_64-unknown-linux-android24"),
            toolchainIdentity: "swiftc@fixture"),
        scratchPath: scratch)

    #expect(
        arm64.commandArguments(["build"]) == [
            "build",
            "--configuration", "release",
            "--jobs", "10",
            "--scratch-path", scratch.string,
            "--package-path", packageRoot.string,
            "--swift-sdk", "fixture-sdk",
            "--triple", "aarch64-unknown-linux-android24",
        ])
    #expect(
        amd64.commandArguments(["build"]) == [
            "build",
            "--configuration", "release",
            "--jobs", "10",
            "--scratch-path", scratch.string,
            "--package-path", packageRoot.string,
            "--swift-sdk", "fixture-sdk",
            "--triple", "x86_64-unknown-linux-android24",
        ])
    #expect(arm64.context.identityBytes != amd64.context.identityBytes)
    #expect(
        arm64.configurationProducts
            == scratch.appending("out/Products/Release-android-aarch64"))
    #expect(
        amd64.configurationProducts
            == scratch.appending("out/Products/Release-android-x86_64"))
}

@Test func swiftPMSelectsEachTripleFromOneSDKArtifactID() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
        "nucleus-swift-sdk-selection-\(UUID().uuidString)",
        isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }

    let bundle = root.appendingPathComponent(
        "fixture.artifactbundle",
        isDirectory: true)
    let variant = bundle.appendingPathComponent("sdk", isDirectory: true)
    let arm64Root = variant.appendingPathComponent("arm64-root", isDirectory: true)
    let amd64Root = variant.appendingPathComponent("amd64-root", isDirectory: true)
    for directory in [arm64Root, amd64Root] {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
    }

    try writeJSON(
        [
            "schemaVersion": "1.0",
            "artifacts": [
                "fixture-sdk": [
                    "type": "swiftSDK",
                    "version": "1.0",
                    "variants": [["path": "sdk"]],
                ]
            ],
        ],
        to: bundle.appendingPathComponent("info.json"))
    try writeJSON(
        [
            "schemaVersion": "4.0",
            "targetTriples": [
                "aarch64-unknown-linux-android24": [
                    "sdkRootPath": "arm64-root"
                ],
                "x86_64-unknown-linux-android24": [
                    "sdkRootPath": "amd64-root"
                ],
            ],
        ],
        to: variant.appendingPathComponent("swift-sdk.json"))

    let arm64 = try showSDKConfiguration(
        searchRoot: root,
        triple: "aarch64-unknown-linux-android24")
    let amd64 = try showSDKConfiguration(
        searchRoot: root,
        triple: "x86_64-unknown-linux-android24")

    #expect(arm64.contains("sdkRootPath: \(arm64Root.path)"))
    #expect(!arm64.contains(amd64Root.path))
    #expect(amd64.contains("sdkRootPath: \(amd64Root.path)"))
    #expect(!amd64.contains(arm64Root.path))
}

private func showSDKConfiguration(
    searchRoot: URL,
    triple: String
) throws -> String {
    let output = Pipe()
    let errors = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
        "swift", "sdk", "configure", "--show-configuration",
        "--swift-sdks-path", searchRoot.path,
        "fixture-sdk", triple,
    ]
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    process.waitUntilExit()

    let standardOutput = String(
        decoding: output.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self)
    let standardError = String(
        decoding: errors.fileHandleForReading.readDataToEndOfFile(),
        as: UTF8.self)
    guard process.terminationStatus == 0 else {
        throw SwiftSDKSelectionFailure(
            status: process.terminationStatus,
            output: standardOutput + standardError)
    }
    return standardOutput
}

private func writeJSON(_ value: Any, to destination: URL) throws {
    try JSONSerialization.data(
        withJSONObject: value,
        options: [.prettyPrinted, .sortedKeys]
    ).write(to: destination)
}

private struct SwiftSDKSelectionFailure: Error, CustomStringConvertible {
    let status: Int32
    let output: String

    var description: String {
        "swift sdk configure exited \(status): \(output)"
    }
}
