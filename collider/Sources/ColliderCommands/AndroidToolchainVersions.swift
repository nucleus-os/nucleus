import Foundation
import SystemPackage

struct AndroidToolchainVersions: Equatable, Sendable {
    let androidGradlePlugin: String
    let gradle: String
    let compileSDKAPI: UInt32
    let compileSDKMinor: UInt32
    let minimumSDK: UInt32
    let targetSDKAPI: UInt32
    let buildTools: String
    let ndk: String
    let java: UInt32

    static func load(workspaceRoot: FilePath) throws -> Self {
        let catalogPath = workspaceRoot.appending(
            "core/android/gradle/libs.versions.toml")
        let catalog = URL(fileURLWithPath: catalogPath.string)
        let contents: String
        do {
            contents = try String(contentsOf: catalog, encoding: .utf8)
        } catch {
            throw WorkspaceFailure.message(
                "Android toolchain version catalog is unreadable: "
                    + "\(catalog.path): \(error)")
        }
        let versions = parseVersions(contents)
        return try Self(
            androidGradlePlugin: required("agp", in: versions, catalog: catalog),
            gradle: required("gradle", in: versions, catalog: catalog),
            compileSDKAPI: unsigned(
                "compileSdkApi", in: versions, catalog: catalog),
            compileSDKMinor: unsigned(
                "compileSdkMinor", in: versions, catalog: catalog),
            minimumSDK: unsigned("minSdk", in: versions, catalog: catalog),
            targetSDKAPI: unsigned(
                "targetSdkApi", in: versions, catalog: catalog),
            buildTools: required(
                "buildTools", in: versions, catalog: catalog),
            ndk: required("ndk", in: versions, catalog: catalog),
            java: unsigned("jvm", in: versions, catalog: catalog))
    }

    func ndkRoot(environment: [String: String]) throws -> FilePath {
        let root: FilePath
        if let explicit = environment["NUCLEUS_ANDROID_NDK_HOME"]
            ?? environment["ANDROID_NDK_HOME"],
            !explicit.isEmpty
        {
            root = FilePath(explicit)
        } else {
            let sdk: FilePath
            if let explicit = environment["ANDROID_SDK_ROOT"]
                ?? environment["ANDROID_HOME"],
                !explicit.isEmpty
            {
                sdk = FilePath(explicit)
            } else {
                guard let home = environment["HOME"], !home.isEmpty else {
                    throw WorkspaceFailure.message(
                        "HOME or an Android SDK/NDK location is required")
                }
                #if os(macOS)
                sdk = FilePath(home).appending("Library/Android/sdk")
                #else
                sdk = FilePath(home).appending("Android/Sdk")
                #endif
            }
            root = sdk.appending("ndk/\(ndk)")
        }
        try validateNDK(at: root)
        return root
    }

    private func validateNDK(at root: FilePath) throws {
        let sourceProperties = URL(
            fileURLWithPath: root.appending("source.properties").string)
        guard
            let contents = try? String(
                contentsOf: sourceProperties, encoding: .utf8)
        else {
            throw WorkspaceFailure.message(
                "Android NDK metadata is missing: \(sourceProperties.path)")
        }
        let properties = Dictionary(
            uniqueKeysWithValues:
                contents
                .split(whereSeparator: \.isNewline)
                .compactMap { line -> (String, String)? in
                    let fields = line.split(
                        separator: "=", maxSplits: 1,
                        omittingEmptySubsequences: false)
                    guard fields.count == 2 else { return nil }
                    return (
                        fields[0].trimmingCharacters(in: .whitespaces),
                        fields[1].trimmingCharacters(in: .whitespaces)
                    )
                })
        let installed =
            properties["Pkg.BaseRevision"]
            ?? properties["Pkg.Revision"]?.split(separator: "-").first.map(String.init)
        guard installed == ndk else {
            throw WorkspaceFailure.message(
                "Android NDK at \(root.string) is \(installed ?? "unversioned"); "
                    + "the version catalog requires \(ndk)")
        }
    }

    private static func parseVersions(_ contents: String) -> [String: String] {
        var result: [String: String] = [:]
        var isVersionsSection = false
        for rawLine in contents.split(
            omittingEmptySubsequences: false,
            whereSeparator: \.isNewline)
        {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                isVersionsSection = line == "[versions]"
                continue
            }
            guard isVersionsSection, !line.isEmpty, !line.hasPrefix("#") else {
                continue
            }
            let fields = line.split(
                separator: "=", maxSplits: 1,
                omittingEmptySubsequences: false)
            guard fields.count == 2 else { continue }
            let key = fields[0].trimmingCharacters(in: .whitespaces)
            let value = fields[1].trimmingCharacters(in: .whitespaces)
            guard value.count >= 2,
                value.first == "\"",
                value.last == "\""
            else { continue }
            result[key] = String(value.dropFirst().dropLast())
        }
        return result
    }

    private static func required(
        _ key: String,
        in versions: [String: String],
        catalog: URL
    ) throws -> String {
        guard let value = versions[key], !value.isEmpty else {
            throw WorkspaceFailure.message(
                "Android toolchain version '\(key)' is missing from "
                    + catalog.path)
        }
        return value
    }

    private static func unsigned(
        _ key: String,
        in versions: [String: String],
        catalog: URL
    ) throws -> UInt32 {
        let value = try required(key, in: versions, catalog: catalog)
        guard let result = UInt32(value) else {
            throw WorkspaceFailure.message(
                "Android toolchain version '\(key)' is not an integer in "
                    + catalog.path)
        }
        return result
    }
}
