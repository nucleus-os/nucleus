import Foundation
import SystemPackage
import Testing
@testable import ColliderRuntime

@Test func validationFixturesMaterializeAsRealProjects() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-validation-fixtures-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let expectedFiles: [ToolchainValidationFixtures.Fixture: [String]] = [
        .hostSmoke: ["smoke.swift"],
        .cxxInterop: [
            "Package.swift",
            "Sources/Example/Example.swift",
            "Tests/ExampleTests/ExampleTests.swift",
        ],
        .sourceKitLSP: [
            "Package.swift",
            "Sources/Greeter/Greeter.swift",
            "Sources/App/main.swift",
        ],
        .androidSDKConsumer: [
            "Package.swift",
            "Sources/hello/hello.swift",
            "Plugins/FoundationXMLHostPlugin/plugin.swift",
        ],
    ]
    for fixture in ToolchainValidationFixtures.Fixture.allCases {
        let destination = FilePath(
            directory.appendingPathComponent(fixture.rawValue).path)
        try ToolchainValidationFixtures.materialize(
            fixture,
            at: destination)
        #expect(
            FileManager.default.fileExists(atPath: destination.string),
            "missing materialized fixture \(fixture.rawValue)")
        for relativePath in try #require(expectedFiles[fixture]) {
            let file = destination.appending(relativePath)
            #expect(
                FileManager.default.fileExists(atPath: file.string),
                "missing \(fixture.rawValue)/\(relativePath)")
            #expect(
                try Data(contentsOf: URL(fileURLWithPath: file.string))
                    .isEmpty == false,
                "empty \(fixture.rawValue)/\(relativePath)")
        }
        let enumerator = try #require(FileManager.default.enumerator(
            at: URL(fileURLWithPath: destination.string),
            includingPropertiesForKeys: nil))
        let containsBuildCache = enumerator.compactMap { $0 as? URL }
            .contains { $0.lastPathComponent == ".build" }
        #expect(
            !containsBuildCache,
            "packaged fixture \(fixture.rawValue) contains a build cache")
    }
}

@Test func sourceKitJSONRPCFramingRoundTripsBundledFixtureMessages() throws {
    let messages: [[String: Any]] = [
        [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": ["rootUri": "file:///nucleus"],
        ],
        [
            "jsonrpc": "2.0",
            "method": "initialized",
            "params": [:],
        ],
    ]
    let payload = try ToolchainValidationFixtures.jsonRPCPayload(messages)
    let parsed = try ToolchainValidationFixtures.jsonRPCMessages(
        String(decoding: payload, as: UTF8.self))

    #expect(parsed.count == 2)
    #expect(parsed[0]["method"] as? String == "initialize")
    #expect(parsed[1]["method"] as? String == "initialized")
}
