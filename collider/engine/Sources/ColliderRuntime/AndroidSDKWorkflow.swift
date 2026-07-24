import ColliderCore
import Foundation
import SystemPackage

extension ColliderRuntime {
    func validateAndroidSDK(
        _ validation: AndroidSDKValidation,
        stage: TaskID
    ) async throws {
        let targetMachine: String
        switch validation.architecture {
        case "aarch64":
            targetMachine = "AArch64"
        case "x86_64":
            targetMachine = "Advanced Micro Devices X86-64"
        default:
            throw RuntimeFailure.invalidOutput(
                "unsupported Android SDK validation architecture "
                    + validation.architecture)
        }
        let bundle = validation.sdkSearchRoot.appending(validation.bundleName)
        guard isDirectory(bundle) else {
            throw RuntimeFailure.invalidOutput(
                "Android Swift SDK bundle is missing: \(bundle)")
        }
        let swift = validation.toolchain.appending("bin/swift")
        guard FileManager.default.isExecutableFile(atPath: swift.string) else {
            throw RuntimeFailure.invalidOutput(
                "Swift executable is missing: \(swift)")
        }
        let readelf = try androidNDKReadELF(validation.ndk)
        let triple = validation.architecture
            + "-unknown-linux-android\(validation.apiLevel)"
        try removeExisting(validation.workDirectory)
        try FileManager.default.createDirectory(
            atPath: validation.workDirectory.string,
            withIntermediateDirectories: true)
        var succeeded = false
        defer {
            if succeeded {
                try? FileManager.default.removeItem(
                    atPath: validation.workDirectory.string)
            }
        }

        try ToolchainValidationFixtures.materialize(
            .androidSDKConsumer,
            at: validation.workDirectory)

        var environment = validation.environment
        environment["ANDROID_NDK_HOME"] = validation.ndk.string
        for mode in ["dynamic", "static"] {
            let build = validation.workDirectory.appending(".build-\(mode)")
            var arguments = [
                "build",
                "--package-path", validation.workDirectory.string,
                "--build-path", build.string,
                "--swift-sdks-path", validation.sdkSearchRoot.string,
                "--swift-sdk", triple,
            ]
            if mode == "static" {
                arguments.append("--static-swift-stdlib")
            }
            let result = try await execute(
                CommandSpec(
                    executable: .path(swift),
                    arguments: arguments,
                    workingDirectory: validation.workDirectory,
                    environment: environment),
                stage: stage)
            guard result.status == 0 else {
                throw RuntimeFailure.commandFailed(status: result.status)
            }
            let binary = try singleExecutable(named: "hello", under: build)
            let header = try await execute(
                CommandSpec(
                    executable: .path(readelf),
                    arguments: ["-h", binary.string],
                    workingDirectory: validation.workDirectory,
                    environment: environment,
                    output: .captured(limit: 1_024 * 1_024)),
                stage: stage)
            guard header.status == 0,
                  header.standardOutput.contains("Machine:"),
                  header.standardOutput.contains(targetMachine)
            else {
                throw RuntimeFailure.invalidOutput(
                    "\(mode) Android consumer has the wrong machine type: \(binary)")
            }
            _ = try singleExecutable(
                named: "FoundationXMLHostPlugin",
                under: build)
        }
        succeeded = true
    }

    func validateAndroidRuntimeLinkage(
        _ validation: AndroidRuntimeLinkageValidation,
        stage: TaskID
    ) async throws {
        let readelf = try androidNDKReadELF(validation.ndk)
        let nm = readelf.removingLastComponent().appending("llvm-nm")
        guard FileManager.default.isExecutableFile(atPath: nm.string) else {
            throw RuntimeFailure.invalidOutput(
                "Android NDK llvm-nm is missing: \(nm)")
        }
        for architecture in validation.architectures {
            let library = validation.installRoot.appending(
                "install-\(architecture)/usr/lib/swift/android/libswiftCore.so")
            guard isRegularFile(library) else {
                throw RuntimeFailure.invalidOutput(
                    "Android libswiftCore is missing: \(library)")
            }
            let dynamic = try await execute(
                CommandSpec(
                    executable: .path(readelf),
                    arguments: ["-d", library.string],
                    workingDirectory: validation.installRoot,
                    environment: validation.environment,
                    output: .captured(limit: 4 * 1_024 * 1_024)),
                stage: stage)
            guard dynamic.status == 0,
                  dynamic.standardOutput.contains(
                    "Shared library: [libc++_shared.so]"),
                  !dynamic.standardOutput.contains(
                    "Shared library: [libstdc++")
            else {
                throw RuntimeFailure.invalidOutput(
                    "Android libswiftCore has an invalid C++ runtime dependency: "
                        + library.string)
            }
            let symbols = try await execute(
                CommandSpec(
                    executable: .path(nm),
                    arguments: ["--dynamic", "--demangle", library.string],
                    workingDirectory: validation.installRoot,
                    environment: validation.environment,
                    output: .captured(limit: 32 * 1_024 * 1_024)),
                stage: stage)
            guard symbols.status == 0,
                  !symbols.standardOutput.contains("std::__cxx11::")
            else {
                throw RuntimeFailure.invalidOutput(
                    "Android libswiftCore contains libstdc++ ABI symbols: "
                        + library.string)
            }
        }
    }

    func validateAndroidHost(
        _ validation: AndroidHostValidation,
        stage: TaskID
    ) async throws {
        guard isRegularFile(validation.library) else {
            throw RuntimeFailure.invalidOutput(
                "Android host library is missing: \(validation.library)")
        }
        guard isRegularFile(validation.kotlinContract) else {
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
        require(header.contains("Machine:") && header.contains("AArch64"),
                "ELF machine is not AArch64")
        for library in ["libandroid.so", "libvulkan.so", "libSwiftJava.so"] {
            require(dynamic.contains("[\(library)]"),
                    "missing dynamic dependency \(library)")
        }
        require(!dynamic.contains("[libswiftCore.so]"),
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
            in: source, range: range).compactMap { match -> String? in
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
        let thunkCount = symbols.components(
            separatedBy: "Java_dev_nucleus_android_AndroidHost__").count - 1
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

func assembleAndroidSDK(_ assembly: AndroidSDKAssembly) throws {
    guard !assembly.architectures.isEmpty else {
        throw RuntimeFailure.invalidOutput(
            "Android SDK assembly requires at least one architecture")
    }
    let triples = try Dictionary(
        uniqueKeysWithValues: assembly.architectures.map { architecture in
            switch architecture {
            case "aarch64", "x86_64":
                (
                    architecture,
                    "\(architecture)-unknown-linux-android\(assembly.apiLevel)")
            default:
                throw RuntimeFailure.invalidOutput(
                    "unsupported Android SDK architecture \(architecture)")
            }
        })
    let fileManager = FileManager.default
    try removeExisting(assembly.bundle)
    let variant = assembly.bundle.appending("swift-android")
    let resources = variant.appending("swift-resources")
    let resourcesUSR = resources.appending("usr")
    let resourcesLibrary = resourcesUSR.appending("lib")
    try fileManager.createDirectory(
        atPath: variant.appending("ndk-sysroot").string,
        withIntermediateDirectories: true)
    try fileManager.createDirectory(
        atPath: resourcesLibrary.appending("swift").string,
        withIntermediateDirectories: true)

    try writeJSON([
        "schemaVersion": "1.0",
        "artifacts": [
            "swift-\(assembly.sourceID)_android": [
                "variants": [["path": "swift-android"]],
                "version": "0.1",
                "type": "swiftSDK",
            ],
        ],
    ], to: assembly.bundle.appending("info.json"))
    try writeJSON([
        "cCompiler": ["extraCLIOptions": ["-fPIC"]],
        "swiftCompiler": [
            "extraCLIOptions": ["-Xclang-linker", "-fuse-ld=lld"],
        ],
        "linker": ["extraCLIOptions": ["-z", "max-page-size=16384"]],
        "schemaVersion": "1.0",
    ], to: variant.appending("swift-toolset.json"))
    try writeJSON([
        "DisplayName": "Swift Android SDK",
        "Version": "0.1",
        "VersionMap": [:],
        "CanonicalName": "linux-android",
    ], to: resources.appending("SDKSettings.json"))
    let targetTriples = Dictionary(uniqueKeysWithValues:
        assembly.architectures.map { architecture in
            (
                triples[architecture]!,
                [
                    "sdkRootPath": "ndk-sysroot",
                    "swiftResourcesPath":
                        "swift-resources/usr/lib/swift-\(architecture)",
                    "swiftStaticResourcesPath":
                        "swift-resources/usr/lib/swift_static-\(architecture)",
                    "toolsetPaths": ["swift-toolset.json"],
                ] as [String: Any]
            )
        })
    try writeJSON([
        "schemaVersion": "4.0",
        "targetTriples": targetTriples,
    ], to: variant.appending("swift-sdk.json"))

    let firstArchitecture = assembly.architectures[0]
    let firstUSR = assembly.installRoot.appending(
        "install-\(firstArchitecture)/usr")
    guard isDirectory(firstUSR) else {
        throw RuntimeFailure.invalidOutput(
            "Android SDK install tree is missing: \(firstUSR)")
    }
    try copyDirectoryContents(
        from: firstUSR.appending("include"),
        to: resourcesUSR.appending("include"))
    for relativePath in ["share/swift", "lib/cmake", "lib/pkgconfig"] {
        let source = firstUSR.appending(relativePath)
        if fileManager.fileExists(atPath: source.string) {
            try copyReplacing(
                from: source,
                to: resourcesUSR.appending(relativePath))
        }
    }
    let toolchainSwiftHeaders = assembly.toolchain.appending("include/swift")
    let toolchainModuleMap = assembly.toolchain.appending(
        "include/module.modulemap")
    guard isDirectory(toolchainSwiftHeaders),
          isRegularFile(toolchainModuleMap)
    else {
        throw RuntimeFailure.invalidOutput(
            "host Swift bridging headers are missing under \(assembly.toolchain)")
    }
    try copyReplacing(
        from: toolchainSwiftHeaders,
        to: resourcesUSR.appending("include/swift"))
    try copyReplacing(
        from: toolchainModuleMap,
        to: resourcesUSR.appending("include/module.modulemap"))

    for architecture in assembly.architectures {
        let installUSR = assembly.installRoot.appending(
            "install-\(architecture)/usr")
        let swiftDestination = resourcesLibrary.appending(
            "swift-\(architecture)")
        let staticDestination = resourcesLibrary.appending(
            "swift_static-\(architecture)")
        let swiftSource = installUSR.appending("lib/swift")
        let staticSource = installUSR.appending("lib/swift_static")
        guard isDirectory(swiftSource.appending("android")),
              isDirectory(staticSource.appending("android"))
        else {
            throw RuntimeFailure.invalidOutput(
                "Swift Android resources are missing for \(architecture)")
        }
        try copyReplacing(from: swiftSource, to: swiftDestination)
        try copyReplacing(from: staticSource, to: staticDestination)
        try replaceSymlink(
            "../swift/clang",
            at: swiftDestination.appending("clang"))
        try replaceSymlink(
            "../swift/clang",
            at: staticDestination.appending("clang"))

        for archive in ["libswiftCxx.a", "libswiftCxxStdlib.a"] {
            let source = swiftDestination.appending("android/\(archive)")
            guard isRegularFile(source) else {
                throw RuntimeFailure.invalidOutput(
                    "Swift C++ interoperability archive is missing: \(source)")
            }
            try copyReplacing(
                from: source,
                to: staticDestination.appending("android/\(archive)"))
        }
        let cfxml = staticDestination.appending(
            "android/lib_CFXMLInterface.a")
        guard isRegularFile(cfxml) else {
            throw RuntimeFailure.invalidOutput(
                "FoundationXML support archive is missing: \(cfxml)")
        }
        try copyReplacing(
            from: cfxml,
            to: swiftDestination.appending("android/lib_CFXMLInterface.a"))
        let staticArguments = staticDestination.appending(
            "android/static-stdlib-args.lnk")
        guard isRegularFile(staticArguments) else {
            throw RuntimeFailure.invalidOutput(
                "static Swift link arguments are missing: \(staticArguments)")
        }
        var arguments = try String(
            contentsOfFile: staticArguments.string,
            encoding: .utf8)
        if !arguments.contains("-l_CFXMLInterface") {
            if !arguments.hasSuffix("\n") {
                arguments.append("\n")
            }
            arguments += """
            -lFoundationXML
            -l_CFXMLInterface
            -lxml2
            -lz
            -llzma
            -liconv

            """
            try DurableFile.write(
                Data(arguments.utf8),
                to: staticArguments)
        }
        let libraryRoot = installUSR.appending("lib")
        for name in try fileManager.contentsOfDirectory(
            atPath: libraryRoot.string).sorted()
        where name.hasSuffix(".a")
        {
            let source = libraryRoot.appending(name)
            guard isRegularFile(source) else { continue }
            try copyReplacing(
                from: source,
                to: resourcesLibrary.appending(name))
            try copyReplacing(
                from: source,
                to: staticDestination.appending("android/\(name)"))
        }
    }
    try rewriteAndroidSDKMetadata(
        under: resourcesLibrary,
        originalPrefix: firstUSR.string)
}

private func writeJSON(_ object: Any, to path: FilePath) throws {
    var data = try JSONSerialization.data(
        withJSONObject: object,
        options: [.prettyPrinted, .sortedKeys])
    data.append(0x0a)
    try DurableFile.write(data, to: path)
}

private func copyDirectoryContents(
    from source: FilePath,
    to destination: FilePath
) throws {
    guard isDirectory(source) else {
        throw RuntimeFailure.invalidOutput(
            "copy source directory is missing: \(source)")
    }
    let fileManager = FileManager.default
    try fileManager.createDirectory(
        atPath: destination.string,
        withIntermediateDirectories: true)
    for name in try fileManager.contentsOfDirectory(
        atPath: source.string).sorted()
    {
        try copyReplacing(
            from: source.appending(name),
            to: destination.appending(name))
    }
}

private func copyReplacing(
    from source: FilePath,
    to destination: FilePath
) throws {
    try removeExisting(destination)
    try FileManager.default.createDirectory(
        atPath: destination.removingLastComponent().string,
        withIntermediateDirectories: true)
    try FileManager.default.copyItem(
        atPath: source.string,
        toPath: destination.string)
}

private func rewriteAndroidSDKMetadata(
    under library: FilePath,
    originalPrefix: String
) throws {
    guard let enumerator = FileManager.default.enumerator(
        at: URL(fileURLWithPath: library.string),
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles])
    else { return }
    for case let url as URL in enumerator {
        guard try url.resourceValues(
            forKeys: [.isRegularFileKey]).isRegularFile == true
        else { continue }
        var contents: String
        switch url.pathExtension {
        case "pc":
            contents = try String(contentsOf: url, encoding: .utf8)
            let lines = contents.split(
                separator: "\n",
                omittingEmptySubsequences: false).map { line -> String in
                if line.hasPrefix("prefix=") {
                    return "prefix=${pcfiledir}/../.."
                }
                if line.hasPrefix("exec_prefix=") {
                    return "exec_prefix=${prefix}"
                }
                if line.hasPrefix("libdir=") {
                    return "libdir=${exec_prefix}/lib"
                }
                if line.hasPrefix("includedir=") {
                    return "includedir=${prefix}/include"
                }
                return String(line)
            }
            let rewritten = lines.joined(separator: "\n")
            if rewritten != contents {
                try DurableFile.write(
                    Data(rewritten.utf8),
                    to: FilePath(url.path))
            }
        case "cmake":
            contents = try String(contentsOf: url, encoding: .utf8)
            let rewritten = contents.replacingOccurrences(
                of: originalPrefix,
                with: "${_IMPORT_PREFIX}")
            if rewritten != contents {
                try DurableFile.write(
                    Data(rewritten.utf8),
                    to: FilePath(url.path))
            }
        default:
            continue
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

private func singleExecutable(
    named name: String,
    under directory: FilePath
) throws -> FilePath {
    guard let enumerator = FileManager.default.enumerator(
        at: URL(fileURLWithPath: directory.string),
        includingPropertiesForKeys: [.isRegularFileKey, .isExecutableKey],
        options: [.skipsHiddenFiles])
    else {
        throw RuntimeFailure.invalidOutput(
            "build output is missing: \(directory)")
    }
    var matches: [FilePath] = []
    for case let url as URL in enumerator where url.lastPathComponent == name {
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isExecutableKey])
        if values.isRegularFile == true, values.isExecutable == true {
            matches.append(FilePath(url.path))
        }
    }
    guard matches.count == 1, let executable = matches.first else {
        throw RuntimeFailure.invalidOutput(
            "expected one executable named \(name) under \(directory); found "
                + "\(matches.count)")
    }
    return executable
}

func sanitizeLinkMetadata(
    _ sanitization: LinkMetadataSanitization
) throws {
    guard let enumerator = FileManager.default.enumerator(
        at: URL(fileURLWithPath: sanitization.root.string),
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles])
    else {
        throw RuntimeFailure.invalidOutput(
            "link metadata root is missing: \(sanitization.root)")
    }
    for case let url as URL in enumerator {
        let path = url.path
        guard path.hasSuffix(".pc")
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
        if contents != original {
            try DurableFile.write(Data(contents.utf8), to: FilePath(path))
        }
    }
}

func wireAndroidSDK(_ wiring: AndroidSDKWiring) throws {
    let fileManager = FileManager.default
    let sourceProperties = wiring.ndk.appending("source.properties")
    let properties: String
    do {
        properties = try String(
            contentsOfFile: sourceProperties.string,
            encoding: .utf8)
    } catch {
        throw RuntimeFailure.invalidOutput(
            "Android NDK source.properties is missing: \(sourceProperties)")
    }
    guard let revision = properties.split(whereSeparator: \.isNewline)
        .first(where: { $0.hasPrefix("Pkg.Revision = ") })?
        .dropFirst("Pkg.Revision = ".count)
        .split(separator: ".")
        .first,
          let major = UInt32(revision),
          major >= wiring.minimumNDKMajorVersion
    else {
        throw RuntimeFailure.invalidOutput(
            "Android NDK \(wiring.ndk) must be version "
                + "\(wiring.minimumNDKMajorVersion) or newer")
    }

    let prebuiltRoot = wiring.ndk.appending("toolchains/llvm/prebuilt")
    let hostDirectories = try directoryChildren(prebuiltRoot).filter {
        isDirectory($0.appending("sysroot/usr/include"))
            && isDirectory($0.appending("sysroot/usr/lib"))
            && isDirectory($0.appending("lib/clang"))
    }
    guard hostDirectories.count == 1, let prebuilt = hostDirectories.first else {
        throw RuntimeFailure.invalidOutput(
            "expected one complete Android NDK LLVM prebuilt under "
                + "\(prebuiltRoot); found \(hostDirectories.count)")
    }

    let variant = wiring.bundle.appending("swift-android")
    let resources = variant.appending("swift-resources")
    let resourcesLibrary = resources.appending("usr/lib")
    guard isDirectory(resourcesLibrary) else {
        throw RuntimeFailure.invalidOutput(
            "Swift Android resources are missing: \(resourcesLibrary)")
    }

    let sysroot = variant.appending("ndk-sysroot")
    let legacyToolchain = variant.appending("ndk-toolchain")
    try removeExisting(sysroot)
    try removeExisting(legacyToolchain)
    let sysrootLibraries = sysroot.appending("usr/lib")
    try fileManager.createDirectory(
        atPath: sysrootLibraries.string,
        withIntermediateDirectories: true)
    try replaceSymlink(
        prebuilt.appending("sysroot/usr/include").string,
        at: sysroot.appending("usr/include"))
    for libraryDirectory in try directoryChildren(
        prebuilt.appending("sysroot/usr/lib"))
    {
        try replaceSymlink(
            libraryDirectory.string,
            at: sysrootLibraries.appending(libraryDirectory.lastComponent!.string))
    }

    let clangVersions = try directoryChildren(prebuilt.appending("lib/clang"))
        .filter(isDirectory)
        .sorted(by: versionPathOrdering)
    guard let clangResources = clangVersions.last else {
        throw RuntimeFailure.invalidOutput(
            "Android NDK Clang resources are missing under \(prebuilt)/lib/clang")
    }
    try replaceSymlink(
        clangResources.string,
        at: resourcesLibrary.appending("swift/clang"))

    for resourceDirectory in try directoryChildren(resourcesLibrary) {
        let directoryName = resourceDirectory.lastComponent!.string
        let family: String
        if directoryName.hasPrefix("swift_static-") {
            family = "swift_static"
        } else if directoryName.hasPrefix("swift-") {
            family = "swift"
        } else {
            continue
        }
        let android = resourceDirectory.appending("android")
        guard isDirectory(android) else { continue }
        for architectureDirectory in try directoryChildren(android) {
            let source = architectureDirectory.appending("swiftrt.o")
            guard isRegularFile(source) else { continue }
            let destinationDirectory = sysrootLibraries
                .appending(family)
                .appending("android")
                .appending(architectureDirectory.lastComponent!.string)
            try fileManager.createDirectory(
                atPath: destinationDirectory.string,
                withIntermediateDirectories: true)
            let destination = destinationDirectory.appending("swiftrt.o")
            try replaceSymlink(
                relativePath(from: destinationDirectory, to: source),
                at: destination)
        }
    }
}

private func directoryChildren(_ directory: FilePath) throws -> [FilePath] {
    try FileManager.default.contentsOfDirectory(atPath: directory.string)
        .sorted()
        .map(directory.appending)
}

private func isDirectory(_ path: FilePath) -> Bool {
    var directory: ObjCBool = false
    return FileManager.default.fileExists(
        atPath: path.string,
        isDirectory: &directory) && directory.boolValue
}

private func isRegularFile(_ path: FilePath) -> Bool {
    var directory: ObjCBool = false
    return FileManager.default.fileExists(
        atPath: path.string,
        isDirectory: &directory) && !directory.boolValue
}

private func removeExisting(_ path: FilePath) throws {
    if FileManager.default.fileExists(atPath: path.string)
        || (try? FileManager.default.destinationOfSymbolicLink(
            atPath: path.string)) != nil
    {
        try FileManager.default.removeItem(atPath: path.string)
    }
}

private func replaceSymlink(_ target: String, at path: FilePath) throws {
    try removeExisting(path)
    try FileManager.default.createDirectory(
        atPath: path.removingLastComponent().string,
        withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        atPath: path.string,
        withDestinationPath: target)
}

private func relativePath(from directory: FilePath, to destination: FilePath) -> String {
    let base = URL(fileURLWithPath: directory.string).standardizedFileURL.pathComponents
    let target = URL(fileURLWithPath: destination.string).standardizedFileURL.pathComponents
    var common = 0
    while common < base.count, common < target.count,
          base[common] == target[common]
    {
        common += 1
    }
    return (
        Array(repeating: "..", count: base.count - common)
            + Array(target.dropFirst(common))
    ).joined(separator: "/")
}

private func versionPathOrdering(_ lhs: FilePath, _ rhs: FilePath) -> Bool {
    func components(_ path: FilePath) -> [Int] {
        path.lastComponent!.string.split(separator: ".").map {
            Int($0) ?? -1
        }
    }
    return components(lhs).lexicographicallyPrecedes(components(rhs))
}
