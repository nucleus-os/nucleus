import Foundation

private struct ArtifactDescriptor: Codable { let sdk: String; let fingerprint: String; let archive: String; let tools: [String: String] }

struct SDKArtifacts {
    let context: WorkspaceContext

    func run(_ arguments: ArraySlice<String>) throws {
        guard let action = arguments.first else { throw WorkspaceFailure.message("sdk requires build, verify, or fetch") }
        switch action {
        case "build": guard let sdk = arguments.dropFirst().first else { throw WorkspaceFailure.message("sdk build requires render or rn") }; try build(String(sdk))
        case "verify": guard let path = arguments.dropFirst().first else { throw WorkspaceFailure.message("sdk verify requires an archive") }; try verify(URL(fileURLWithPath: String(path)))
        case "fetch":
            guard let sdk = arguments.dropFirst().first else { throw WorkspaceFailure.message("sdk fetch requires render or rn") }
            let rest = Array(arguments.dropFirst(2)); guard rest.count == 2, rest[0] == "--from" else { throw WorkspaceFailure.message("usage: sdk fetch <render|rn> --from <directory-or-url>") }
            try fetch(String(sdk), from: rest[1])
        default: throw WorkspaceFailure.message("unknown sdk action '\(action)'")
        }
    }

    private func validate(_ sdk: String) throws { guard ["render", "rn"].contains(sdk) else { throw WorkspaceFailure.message("SDK must be render or rn") } }
    private var artifacts: URL { context.root.appendingPathComponent(".nucleus/artifacts") }
    private func cache(_ sdk: String) -> URL { URL(fileURLWithPath: context.environment["HOME"] ?? "").appendingPathComponent(".cache/nucleus/nucleus-native-sdk/\(sdk)") }

    private func build(_ sdk: String) throws {
        try validate(sdk); guard FileManager.default.fileExists(atPath: cache(sdk).path) else { throw WorkspaceFailure.message("SDK cache is missing: \(cache(sdk).path)") }
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nucleus-sdk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let payload = temp.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        // Follow the cache's top-level symlink farm, but preserve symlinks inside
        // vendored trees (Dawn intentionally contains a few dangling tool links).
        try context.run("sh", ["-c", "for group in \"$1\"/*; do g=\"$2/$(basename \"$group\")\"; mkdir -p \"$g\"; for entry in \"$group\"/*; do d=\"$g/$(basename \"$entry\")\"; mkdir -p \"$d\"; rsync -a --exclude=.git --exclude=.git/ --exclude=infra/ --exclude=tools/ --exclude=tests/ --exclude=test/ --exclude=docs/ --exclude=site/ --exclude=out/ --exclude=bin/ --exclude=third_party/externals/unicodetools/ --exclude=third_party/externals/emsdk/ --exclude=third_party/externals/swiftshader/ --exclude=third_party/externals/opengl-registry/specs/ --exclude=third_party/externals/icu/ \"$entry/\" \"$d/\"; done; done", "sh", cache(sdk).path, payload.path])
        let checksums = try context.run("sh", ["-c", "cd \"$1/payload\" && find . -type f -print0 | sort -z | xargs -0 sha256sum", "sh", temp.path], capture: true)
        try Data(checksums.appending("\n").utf8).write(to: temp.appendingPathComponent("SHA256SUMS"))
        let identity = try context.run("sh", ["-c", "{ sha256sum \"$1/config/build-contract.json\"; git -C \"$1\" rev-parse HEAD; sha256sum \"$2/SHA256SUMS\"; } | sha256sum | cut -d' ' -f1", "sh", context.root.path, temp.path], capture: true)
        let archiveName = "\(sdk)-\(identity).tar.gz"
        var tools: [String: String] = [:]
        for (name, command, arguments) in [("swift", "swift", ["--version"]), ("clang", "clang", ["--version"]), ("cmake", "cmake", ["--version"]), ("ninja", "ninja", ["--version"])] {
            tools[name] = try context.run(command, arguments, capture: true).split(separator: "\n").first.map(String.init) ?? "unknown"
        }
        let descriptor = ArtifactDescriptor(sdk: sdk, fingerprint: identity, archive: archiveName, tools: tools)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(descriptor).write(to: temp.appendingPathComponent("manifest.json"))
        try context.run("tar", ["--sort=name", "--mtime=@0", "--owner=0", "--group=0", "--numeric-owner", "-czf", artifacts.appendingPathComponent(archiveName).path, "-C", temp.path, "manifest.json", "SHA256SUMS", "payload"])
        try encoder.encode(descriptor).write(to: artifacts.appendingPathComponent("\(sdk)-latest.json"), options: .atomic)
        print("built \(artifacts.appendingPathComponent(archiveName).path)")
    }

    private func verify(_ archive: URL) throws {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nucleus-verify-\(UUID().uuidString)"); defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        try context.run("tar", ["-xzf", archive.path, "-C", temp.path])
        try context.run("sha256sum", ["-c", "../SHA256SUMS"], directory: temp.appendingPathComponent("payload"))
        print("verified \(archive.path)")
    }

    private func fetch(_ sdk: String, from source: String) throws {
        try validate(sdk); try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        let descriptorURL = artifacts.appendingPathComponent("\(sdk)-latest.json")
        try? FileManager.default.removeItem(at: descriptorURL)
        if source.hasPrefix("http://") || source.hasPrefix("https://") { try context.run("curl", ["-fsSL", "\(source)/\(sdk)-latest.json", "-o", descriptorURL.path]) }
        else { try FileManager.default.copyItem(at: URL(fileURLWithPath: source).appendingPathComponent("\(sdk)-latest.json"), to: descriptorURL) }
        let descriptor = try JSONDecoder().decode(ArtifactDescriptor.self, from: Data(contentsOf: descriptorURL)); let archive = artifacts.appendingPathComponent(descriptor.archive)
        try? FileManager.default.removeItem(at: archive)
        if source.hasPrefix("http://") || source.hasPrefix("https://") { try context.run("curl", ["-fsSL", "\(source)/\(descriptor.archive)", "-o", archive.path]) }
        else { try FileManager.default.copyItem(at: URL(fileURLWithPath: source).appendingPathComponent(descriptor.archive), to: archive) }
        try verify(archive)
        let destination = cache(sdk); try? FileManager.default.removeItem(at: destination); try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try context.run("tar", ["-xzf", archive.path, "-C", destination.deletingLastPathComponent().path, "--strip-components=1", "payload"])
        print("installed \(sdk) SDK at \(destination.path)")
    }
}
