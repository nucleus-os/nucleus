import ColliderCore
import Foundation
import SystemPackage

extension ColliderRuntime {
    func assembleCEFArtifact(
        _ assembly: CEFArtifactAssembly,
        stage: TaskID
    ) async throws {
        let builtManifest = assembly.buildOutput.appending(
            ".nucleus-built-build.json")
        let buildID = try chromiumBuildID(builtManifest)
        var environment = assembly.environment
        environment["PATH"] = assembly.depotTools.string + ":"
            + (environment["PATH"] ?? "/usr/bin:/bin")
        environment["DEPOT_TOOLS_UPDATE"] = "0"
        let automate = assembly.sourceRoot.appending("automate-git.py")
        try await checkedCEFCommand(
            .named("python3"),
            [
                automate.string,
                "--download-dir=\(assembly.sourceRoot)",
                "--depot-tools-dir=\(assembly.depotTools)",
                "--branch=\(assembly.cefBranch)",
                "--checkout=\(assembly.cefCheckout)",
                "--x64-build",
                "--no-debug-build",
                "--no-chromium-history",
                "--with-pgo-profiles",
                "--build-target=cefsimple",
                "--no-update",
                "--no-build",
                "--force-distrib",
                "--minimal-distrib-only",
            ],
            directory: assembly.sourceRoot,
            environment: environment,
            stage: stage)
        let distributionDirectory = assembly.chromiumSource.appending(
            "cef/binary_distrib")
        let checkout = String(assembly.cefCheckout.prefix(7))
        let suffix =
            "+g\(checkout)+chromium-\(assembly.chromiumVersion)"
            + "_linux64_minimal"
        let matches = try FileManager.default.contentsOfDirectory(
            atPath: distributionDirectory.string)
            .filter {
                $0.hasPrefix("cef_binary_") && $0.hasSuffix(suffix)
            }
        guard matches.count == 1, let producedName = matches.first else {
            throw RuntimeFailure.invalidOutput(
                "expected one current CEF minimal distribution; found "
                    + "\(matches.count)")
        }
        let produced = distributionDirectory.appending(producedName)
        let releases = assembly.distributionRoot.appending("releases")
        try FileManager.default.createDirectory(
            atPath: releases.string,
            withIntermediateDirectories: true)
        let candidate = releases.appending(
            ".\(buildID).\(UUID().uuidString).prepared")
        try FileManager.default.createDirectory(
            atPath: candidate.string,
            withIntermediateDirectories: false)
        var succeeded = false
        defer {
            if !succeeded {
                try? FileManager.default.removeItem(atPath: candidate.string)
            }
        }
        let sdk = candidate.appending("sdk")
        let artifacts = candidate.appending("artifacts")
        try FileManager.default.copyItem(
            atPath: produced.string, toPath: sdk.string)
        try FileManager.default.createDirectory(
            atPath: artifacts.string,
            withIntermediateDirectories: true)
        try DurableFile.copy(
            from: builtManifest,
            to: sdk.appending("nucleus-build-manifest.json"))
        for relative in [
            "Release/libvk_swiftshader.so",
            "Release/vk_swiftshader_icd.json",
        ] {
            try? FileManager.default.removeItem(
                atPath: sdk.appending(relative).string)
        }
        let resources = sdk.appending("Resources")
        if cefDirectory(resources) {
            for name in try FileManager.default.contentsOfDirectory(
                atPath: resources.string)
            {
                let link = sdk.appending("Release/\(name)")
                try? FileManager.default.removeItem(atPath: link.string)
                try FileManager.default.createSymbolicLink(
                    atPath: link.string,
                    withDestinationPath: "../Resources/\(name)")
            }
        }
        try await validateCEFSDK(
            sdk, environment: environment, stage: stage)

        let version = String(
            producedName
                .dropFirst("cef_binary_".count)
                .dropLast("_linux64_minimal".count))
        let tarball = "cef-\(version)-linux64-codecs.tar.gz"
        let archive = artifacts.appending(tarball)
        try await checkedCEFCommand(
            .named("tar"),
            [
                "-C", candidate.string,
                "-czf", archive.string,
                "--transform=s,^sdk,\(buildID),",
                "sdk",
            ],
            directory: candidate,
            environment: environment,
            stage: stage)
        let checksum = try ArtifactHasher.digest(file: archive)
            .description.replacingOccurrences(of: "sha256:", with: "")
        try DurableFile.write(
            Data("\(checksum)  \(tarball)\n".utf8),
            to: artifacts.appending("\(tarball).sha256"))
        try DurableFile.copy(
            from: builtManifest,
            to: artifacts.appending("nucleus-build-manifest.json"))

        try GenerationPublisher.publish(
            candidate: candidate,
            generation: releases.appending(buildID),
            active: assembly.distributionRoot.appending("current-release"))
        try DirectoryLifecycle.activate(
            target: "current-release/sdk",
            link: assembly.distributionRoot.appending("current"))
        try DirectoryLifecycle.activate(
            target: "current-release/artifacts",
            link: assembly.distributionRoot.appending("artifacts-current"))
        succeeded = true
    }

    func validateCEFArtifact(
        _ assembly: CEFArtifactAssembly,
        stage: TaskID
    ) async throws {
        let builtManifest = assembly.buildOutput.appending(
            ".nucleus-built-build.json")
        let buildID = try chromiumBuildID(builtManifest)
        let release = assembly.distributionRoot.appending("current-release")
        guard let metadata = try? release.stat(followTargetSymlink: false),
              metadata.type == .symbolicLink,
              try FileManager.default.destinationOfSymbolicLink(
                atPath: release.string) == "releases/\(buildID)"
        else {
            throw RuntimeFailure.invalidOutput(
                "published CEF generation does not match \(buildID)")
        }
        for manifest in [
            assembly.distributionRoot.appending(
                "current/nucleus-build-manifest.json"),
            assembly.distributionRoot.appending(
                "artifacts-current/nucleus-build-manifest.json"),
        ] {
            guard try Data(contentsOf: URL(
                fileURLWithPath: builtManifest.string))
                    == Data(contentsOf: URL(
                        fileURLWithPath: manifest.string))
            else {
                throw RuntimeFailure.invalidOutput(
                    "published CEF manifest does not match \(buildID)")
            }
        }
        try await validateCEFSDK(
            assembly.distributionRoot.appending("current"),
            environment: assembly.environment,
            stage: stage)
        try await checkedCEFCommand(
            .named("python3"),
            ["tools/version_manager.py", "-c"],
            directory: assembly.chromiumSource.appending("cef"),
            environment: assembly.environment,
            stage: stage)
    }

    private func validateCEFSDK(
        _ sdk: FilePath,
        environment: [String: String],
        stage: TaskID
    ) async throws {
        for relative in [
            "Release/libcef.so", "Release/chrome-sandbox",
            "Release/icudtl.dat", "Resources",
            "include/cef_version_info.h",
            "nucleus-build-manifest.json",
        ] {
            guard cefExists(sdk.appending(relative)) else {
                throw RuntimeFailure.invalidOutput(
                    "CEF SDK artifact is missing: \(relative)")
            }
        }
        let linker = try await execute(
            CommandSpec(
                executable: .named("ldd"),
                arguments: [sdk.appending("Release/libcef.so").string],
                workingDirectory: sdk,
                environment: environment,
                output: .captured(limit: 4 * 1_024 * 1_024)),
            stage: stage)
        guard linker.status == 0,
              !linker.standardOutput.contains("not found")
        else {
            throw RuntimeFailure.invalidOutput(
                "CEF SDK has unresolved dynamic libraries")
        }
        let smoke = FilePath(
            FileManager.default.temporaryDirectory.appendingPathComponent(
                "collider-cef-consumer-\(UUID().uuidString)").path)
        try FileManager.default.createDirectory(
            atPath: smoke.string,
            withIntermediateDirectories: false)
        defer {
            try? FileManager.default.removeItem(atPath: smoke.string)
        }
        let source = smoke.appending("consumer.c")
        try DurableFile.write(
            Data(
                """
                #include "include/cef_version_info.h"
                int main(void) { return cef_version_info(0) > 0 ? 0 : 1; }
                """.utf8),
            to: source)
        let consumer = smoke.appending("consumer")
        try await checkedCEFCommand(
            .named("cc"),
            [
                "-I", sdk.string,
                source.string,
                "-L", sdk.appending("Release").string,
                "-Wl,-rpath,\(sdk.appending("Release"))",
                "-lcef",
                "-o", consumer.string,
            ],
            directory: smoke,
            environment: environment,
            stage: stage)
        try await checkedCEFCommand(
            .path(consumer),
            [],
            directory: smoke,
            environment: environment,
            stage: stage)
    }

    private func checkedCEFCommand(
        _ executable: CommandSpec.Executable,
        _ arguments: [String],
        directory: FilePath,
        environment: [String: String],
        stage: TaskID
    ) async throws {
        let result = try await execute(
            CommandSpec(
                executable: executable,
                arguments: arguments,
                workingDirectory: directory,
                environment: environment),
            stage: stage)
        guard result.status == 0 else {
            throw RuntimeFailure.commandFailed(status: result.status)
        }
    }
}

private func cefExists(_ path: FilePath) -> Bool {
    FileManager.default.fileExists(atPath: path.string)
}

private func cefDirectory(_ path: FilePath) -> Bool {
    var directory = ObjCBool(false)
    return FileManager.default.fileExists(
        atPath: path.string, isDirectory: &directory) && directory.boolValue
}
