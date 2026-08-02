import ColliderCore
import Foundation
import SystemPackage

extension ColliderRuntime {
    func validateAndroidHost(
        _ validation: AndroidHostValidation,
        stage: TaskID
    ) async throws {
        guard validation.library.isRegularFile else {
            throw RuntimeFailure.invalidOutput(
                "Android host library is missing: \(validation.library)")
        }
        guard validation.kotlinContract.isRegularFile else {
            throw RuntimeFailure.invalidOutput(
                "Android Kotlin JNI contract is missing: "
                    + validation.kotlinContract.string)
        }
        let readelf = try androidNDKReadELF(validation.ndk)
        func inspect(_ arguments: [String]) async throws -> String {
            let result = try await execute(
                CommandSpec(
                    executable: .path(readelf),
                    arguments: arguments + [validation.library.string],
                    workingDirectory: validation.library.removingLastComponent(),
                    environment: validation.environment,
                    output: .captured(limit: 64 * 1_024 * 1_024)),
                stage: stage)
            guard result.status == 0 else {
                throw RuntimeFailure.commandFailed(status: result.status)
            }
            return result.standardOutput
        }
        let header = try await inspect(["-h"])
        let dynamic = try await inspect(["-d"])
        let symbols = try await inspect(["-Ws"])
        var failures: [String] = []
        func require(_ condition: Bool, _ description: String) {
            if !condition { failures.append(description) }
        }
        require(
            header.contains("Machine:") && header.contains("AArch64"),
            "ELF machine is not AArch64")
        for library in ["libandroid.so", "libvulkan.so", "libSwiftJava.so"] {
            require(
                dynamic.contains("[\(library)]"),
                "missing dynamic dependency \(library)")
        }
        require(
            !dynamic.contains("[libswiftCore.so]"),
            "must not link libswiftCore.so")
        require(symbols.contains("JNI_OnLoad"), "missing JNI_OnLoad export")
        let staticRuntimePattern =
            #"\sFUNC\s+LOCAL\s+PROTECTED\s+\d+\s+swift_retain(?:\s|$)"#
        require(
            symbols.range(
                of: staticRuntimePattern,
                options: .regularExpression) != nil,
            "missing static Swift runtime")

        let source = try String(
            contentsOf: URL(
                fileURLWithPath: validation.kotlinContract.string),
            encoding: .utf8)
        let expression = try NSRegularExpression(
            pattern: #"external\s+fun\s+([A-Za-z0-9_]+)"#)
        let range = NSRange(source.startIndex..., in: source)
        let functions = expression.matches(
            in: source, range: range
        ).compactMap { match -> String? in
            guard let value = Range(match.range(at: 1), in: source) else {
                return nil
            }
            return String(source[value])
        }
        require(!functions.isEmpty, "Kotlin contract declares no external functions")
        for function in functions {
            require(
                symbols.contains(
                    "Java_dev_nucleus_android_NucleusNative_\(function)"),
                "missing JNI export for NucleusNative.\(function)")
        }
        let thunkCount =
            symbols.components(
                separatedBy: "Java_dev_nucleus_android_AndroidHost__"
            ).count - 1
        require(
            thunkCount >= Int(validation.minimumSwiftJavaThunkCount),
            "found \(thunkCount) swift-java AndroidHost thunks; expected at least "
                + "\(validation.minimumSwiftJavaThunkCount)")
        guard failures.isEmpty else {
            throw RuntimeFailure.invalidOutput(
                "Android host validation failed:\n  "
                    + failures.joined(separator: "\n  "))
        }
    }
}

private func androidNDKReadELF(_ ndk: FilePath) throws -> FilePath {
    let prebuilt = ndk.appending("toolchains/llvm/prebuilt")
    let candidates = try directoryChildren(prebuilt).map {
        $0.appending("bin/llvm-readelf")
    }.filter {
        FileManager.default.isExecutableFile(atPath: $0.string)
    }
    guard candidates.count == 1, let readelf = candidates.first else {
        throw RuntimeFailure.invalidOutput(
            "expected one llvm-readelf under \(prebuilt); found "
                + "\(candidates.count)")
    }
    return readelf
}

func sanitizeLinkMetadata(
    _ sanitization: LinkMetadataSanitization
) throws {
    guard
        let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: sanitization.root.string),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])
    else {
        throw RuntimeFailure.invalidOutput(
            "link metadata root is missing: \(sanitization.root)")
    }
    for case let url as URL in enumerator {
        let path = url.path
        guard
            path.hasSuffix(".pc")
                || path.hasSuffix(".la")
                || path.contains("/cmake/"),
            try url.resourceValues(
                forKeys: [.isRegularFileKey]).isRegularFile == true
        else { continue }
        var contents = try String(contentsOf: url, encoding: .utf8)
        let original = contents
        for option in sanitization.removedLinkerOptions {
            for expression in [
                "$<LINK_ONLY:\(option)>",
                "\\$<LINK_ONLY:\(option)>",
                "\\\\$<LINK_ONLY:\(option)>",
            ] {
                contents = contents.replacingOccurrences(
                    of: expression, with: "")
            }
            contents = contents.replacingOccurrences(of: option, with: "")
        }
        for repair in sanitization.cmakeDependencyRepairs
        where url.lastPathComponent == repair.configurationFileName {
            let generatedLookup =
                "find_dependency(\(repair.package) \"\(repair.version)\")"
            let repairedLookup =
                "find_package(\(repair.package) \(repair.version) REQUIRED"
                + (repair.configurationOnly ? " CONFIG)" : ")")
            let nonConfigurationLookup =
                "find_package(\(repair.package) \(repair.version) REQUIRED)"
            if contents.contains(generatedLookup) {
                contents = contents.replacingOccurrences(
                    of: generatedLookup,
                    with: repairedLookup)
            } else if repair.configurationOnly
                && contents.contains(nonConfigurationLookup)
            {
                contents = contents.replacingOccurrences(
                    of: nonConfigurationLookup,
                    with: repairedLookup)
            } else if !contents.contains(repairedLookup) {
                throw RuntimeFailure.invalidOutput(
                    "\(repair.configurationFileName) does not contain expected "
                        + "CMake dependency lookup: \(generatedLookup)")
            }
        }
        for replacement in sanitization.replacements
        where url.lastPathComponent == replacement.fileName {
            if contents.contains(replacement.original) {
                contents = contents.replacingOccurrences(
                    of: replacement.original,
                    with: replacement.replacement)
            } else if !contents.contains(replacement.replacement) {
                throw RuntimeFailure.invalidOutput(
                    "\(replacement.fileName) does not contain expected link "
                        + "metadata: \(replacement.original)")
            }
        }
        if contents != original {
            try DurableFile.write(Data(contents.utf8), to: FilePath(path))
        }
    }
}

private func directoryChildren(_ directory: FilePath) throws -> [FilePath] {
    try FileManager.default.contentsOfDirectory(atPath: directory.string)
        .sorted()
        .map(directory.appending)
}
