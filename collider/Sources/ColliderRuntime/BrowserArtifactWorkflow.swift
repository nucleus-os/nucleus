import ColliderCore
import Foundation
import SystemPackage

extension ColliderRuntime {
    func assembleBrowserArtifact(
        _ assembly: BrowserArtifactAssembly,
        stage: TaskID
    ) async throws {
        let builtManifest = assembly.buildOutput.appending(
            ".nucleus-built-build.json")
        let buildID = try chromiumBuildID(builtManifest)
        let generations = assembly.distributionRoot.appending("generations")
        try FileManager.default.createDirectory(
            atPath: generations.string,
            withIntermediateDirectories: true)
        let candidate = generations.appending(
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
        let runtime = candidate.appending("runtime")
        try FileManager.default.createDirectory(
            atPath: runtime.string,
            withIntermediateDirectories: true)
        let required: [(String, String, Int?)] = [
            ("chrome", "nucleus-browser-bin", 0o755),
            ("chrome_crashpad_handler", "chrome_crashpad_handler", 0o755),
            ("chrome_sandbox", "chrome_sandbox", 0o755),
            ("icudtl.dat", "icudtl.dat", nil),
            ("resources.pak", "resources.pak", nil),
            ("chrome_100_percent.pak", "chrome_100_percent.pak", nil),
            ("chrome_200_percent.pak", "chrome_200_percent.pak", nil),
            ("libEGL.so", "libEGL.so", 0o755),
            ("libGLESv2.so", "libGLESv2.so", 0o755),
            ("libvulkan.so.1", "libvulkan.so.1", 0o755),
        ]
        for (source, destination, permissions) in required {
            try copyBrowserItem(
                assembly.buildOutput.appending(source),
                runtime.appending(destination),
                permissions: permissions)
        }
        let snapshot = assembly.buildOutput.appending(
            "v8_context_snapshot.bin")
        if browserPathExists(snapshot) {
            try copyBrowserItem(
                snapshot,
                runtime.appending("v8_context_snapshot.bin"))
        } else {
            try copyBrowserItem(
                assembly.buildOutput.appending("snapshot_blob.bin"),
                runtime.appending("snapshot_blob.bin"))
        }
        let optionalFiles: [(String, Int?)] = [
            ("chrome_management_service", 0o755),
        ]
        for (name, permissions) in optionalFiles {
            let source = assembly.buildOutput.appending(name)
            if browserPathExists(source) {
                try copyBrowserItem(
                    source,
                    runtime.appending(name),
                    permissions: permissions)
            }
        }
        for name in [
            "locales", "default_apps", "MEIPreload",
            "PrivacySandboxAttestationsPreloaded",
        ] {
            let source = assembly.buildOutput.appending(name)
            if browserPathExists(source) {
                try copyBrowserItem(source, runtime.appending(name))
            }
        }
        try copyBrowserItem(
            assembly.launcher,
            candidate.appending("bin/nucleus-browser"),
            permissions: 0o755)
        try copyBrowserItem(
            assembly.desktopTemplate,
            candidate.appending(
                "share/applications/dev.nucleus.Browser.desktop.in"))
        for size in [16, 22, 24, 32, 48, 64, 128, 256] {
            if let icon = browserIcon(
                size: size,
                output: assembly.buildOutput,
                source: assembly.chromiumSource)
            {
                try copyBrowserItem(
                    icon,
                    candidate.appending(
                        "share/icons/hicolor/\(size)x\(size)/apps/"
                            + "dev.nucleus.Browser.png"))
            }
        }
        try copyBrowserItem(
            builtManifest,
            candidate.appending("nucleus-build-manifest.json"))
        try await validateBrowserGeneration(
            candidate,
            environment: assembly.environment,
            stage: stage)
        try GenerationPublisher.publish(
            candidate: candidate,
            generation: generations.appending(buildID),
            active: assembly.distributionRoot.appending("current"))
        succeeded = true
    }

    func validateBrowserArtifact(
        _ assembly: BrowserArtifactAssembly,
        stage: TaskID
    ) async throws {
        let builtManifest = assembly.buildOutput.appending(
            ".nucleus-built-build.json")
        let buildID = try chromiumBuildID(builtManifest)
        let current = assembly.distributionRoot.appending("current")
        guard let metadata = try? current.stat(followTargetSymlink: false),
              metadata.type == .symbolicLink,
              try FileManager.default.destinationOfSymbolicLink(
                atPath: current.string) == "generations/\(buildID)"
        else {
            throw RuntimeFailure.invalidOutput(
                "published browser generation does not match \(buildID)")
        }
        let publishedManifest = current.appending(
            "nucleus-build-manifest.json")
        guard try Data(contentsOf: URL(fileURLWithPath: builtManifest.string))
                == Data(contentsOf: URL(
                    fileURLWithPath: publishedManifest.string))
        else {
            throw RuntimeFailure.invalidOutput(
                "published browser build manifest does not match \(buildID)")
        }
        try await validateBrowserGeneration(
            current,
            environment: assembly.environment,
            stage: stage)
    }

    private func validateBrowserGeneration(
        _ generation: FilePath,
        environment: [String: String],
        stage: TaskID
    ) async throws {
        let runtime = generation.appending("runtime")
        for relative in [
            "nucleus-browser-bin", "chrome_crashpad_handler",
            "chrome_sandbox", "icudtl.dat", "resources.pak",
            "chrome_100_percent.pak", "chrome_200_percent.pak",
            "locales", "libEGL.so", "libGLESv2.so", "libvulkan.so.1",
        ] {
            guard browserPathExists(runtime.appending(relative)) else {
                throw RuntimeFailure.invalidOutput(
                    "browser generation is missing: \(relative)")
            }
        }
        for relative in [
            "share/icons/hicolor/128x128/apps/"
                + "dev.nucleus.Browser.png",
            "nucleus-build-manifest.json",
            "bin/nucleus-browser",
        ] {
            guard browserPathExists(generation.appending(relative)) else {
                throw RuntimeFailure.invalidOutput(
                    "browser generation is missing: \(relative)")
            }
        }
        let linker = try await execute(
            CommandSpec(
                executable: .named("ldd"),
                arguments: [runtime.appending("nucleus-browser-bin").string],
                workingDirectory: generation,
                environment: environment,
                output: .captured(limit: 4 * 1_024 * 1_024)),
            stage: stage)
        guard linker.status == 0,
              !linker.standardOutput.contains("not found")
        else {
            throw RuntimeFailure.invalidOutput(
                "browser generation has unresolved dynamic libraries")
        }
        let launcher = try await execute(
            CommandSpec(
                executable: .named("bash"),
                arguments: ["-n", generation.appending(
                    "bin/nucleus-browser").string],
                workingDirectory: generation,
                environment: environment),
            stage: stage)
        guard launcher.status == 0 else {
            throw RuntimeFailure.invalidOutput(
                "browser launcher is not valid shell syntax")
        }
    }
}

func chromiumBuildID(_ manifest: FilePath) throws -> String {
    let object = try JSONSerialization.jsonObject(
        with: Data(contentsOf: URL(fileURLWithPath: manifest.string)))
    guard let dictionary = object as? [String: Any],
          let value =
            dictionary["buildID"] as? String
            ?? dictionary["build_id"] as? String,
          value.range(
            of: #"^[0-9a-f]{24}$"#,
            options: .regularExpression) != nil
    else {
        throw RuntimeFailure.invalidOutput(
            "Chromium build identity is missing: \(manifest)")
    }
    return value
}

private func copyBrowserItem(
    _ source: FilePath,
    _ destination: FilePath,
    permissions: Int? = nil
) throws {
    guard browserPathExists(source) else {
        throw RuntimeFailure.invalidOutput(
            "required browser artifact is missing: \(source)")
    }
    try FileManager.default.createDirectory(
        atPath: destination.removingLastComponent().string,
        withIntermediateDirectories: true)
    try FileManager.default.copyItem(
        atPath: source.string,
        toPath: destination.string)
    if let permissions {
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions],
            ofItemAtPath: destination.string)
    }
}

private func browserIcon(
    size: Int,
    output: FilePath,
    source: FilePath
) -> FilePath? {
    [
        output.appending("product_logo_\(size).png"),
        source.appending(
            "chrome/app/theme/chromium/linux/product_logo_\(size).png"),
        source.appending(
            "chrome/app/theme/default_100_percent/chromium/linux/"
                + "product_logo_\(size).png"),
        source.appending(
            "chrome/app/theme/chromium/product_logo_\(size).png"),
    ].first(where: browserPathExists)
}

private func browserPathExists(_ path: FilePath) -> Bool {
    FileManager.default.fileExists(atPath: path.string)
}
