import ColliderCore
import Foundation
import NativeBuilderColliderRecipe
import SystemPackage

public struct RuntimeELFReport: Codable, Hashable, Sendable {
    public struct Dependency: Codable, Hashable, Sendable {
        public let soname: String
        public let owner: NucleusLinuxABI.ELFOwner
    }

    public struct Executable: Codable, Hashable, Sendable {
        public let name: String
        public let path: String
        public let runpath: String
        public let needed: [String]
        public let dependencies: [Dependency]
    }

    public let root: String
    public let staged: Bool
    public let minimumGlibcVersion: String
    public let executables: [Executable]
}

public enum RuntimeELFProductSet: String, Codable, Hashable, Sendable {
    case baseRuntime
    case androidAddon
}

public struct StageRuntimeELFAction: ColliderAction {
    public struct Identity: ColliderActionIdentity {
        public let products: FilePath
        public let prefix: FilePath
        public let productSet: RuntimeELFProductSet

        public func encode(into encoder: inout IdentityEncoder) {
            encoder.append(path: products)
            encoder.append(path: prefix)
            encoder.append(productSet.rawValue)
        }
    }

    public static let kind: ActionKind = "shell.stage-runtime-elf"

    public let products: FilePath
    public let prefix: FilePath
    public let environment: [String: String]
    public let productSet: RuntimeELFProductSet
    public let executionPlatform: ExecutionPlatform

    public var identity: Identity {
        Identity(
            products: products,
            prefix: prefix,
            productSet: productSet)
    }

    public var requirements: ActionRequirements {
        ActionRequirements(
            tools: [
                ActionToolRequirement(
                    "patchelf", executable: .named("patchelf"), role: .semantic),
                ActionToolRequirement(
                    "readelf", executable: .named("readelf"), role: .semantic),
                ActionToolRequirement(
                    "llvm-strip", executable: .named("llvm-strip"), role: .semantic),
            ],
            effects: [
                ActionEffect(.read, scope: .input(products)),
                ActionEffect(.read, scope: .unrestricted(FilePath("/"))),
                ActionEffect(.readWrite, scope: .output(prefix)),
            ],
            executionPlatform: executionPlatform,
            artifactTarget: linuxArtifactTarget(for: executionPlatform))
    }

    public init(
        products: FilePath,
        prefix: FilePath,
        environment: [String: String],
        productSet: RuntimeELFProductSet = .baseRuntime,
        executionPlatform: ExecutionPlatform
    ) {
        self.products = products
        self.prefix = prefix
        self.environment = environment
        self.productSet = productSet
        self.executionPlatform = executionPlatform
    }

    public func execute(in context: ActionContext) async throws {
        try await stageRuntimeELF(
            products: products,
            prefix: prefix,
            environment: environment,
            productSet: productSet,
            targetArchitecture: executionPlatform.architecture,
            context: context)
    }
}

package func stageRuntimeELF(
    products: FilePath,
    prefix: FilePath,
    environment: [String: String],
    productSet: RuntimeELFProductSet,
    targetArchitecture: PlatformArchitecture,
    context: ActionContext
) async throws {
    for directory in RuntimeELFLayout.stagingDirectories(root: prefix) {
        try context.files.createDirectory(directory)
    }

    var queue: [FilePath] = []
    let executables = RuntimeELFLayout.executables(productSet: productSet)
    for executable in executables {
        let source = products.appending(executable.name)
        let destination = RuntimeELFLayout.path(
            for: executable,
            under: prefix,
            staged: true)
        try requireRegularExecutable(source, files: context.files)
        try context.files.copy(from: source, to: destination)
        try context.files.setPermissions(0o755, for: destination)
        queue.append(destination)
    }

    var copiedDependencies: [String: FilePath] = [:]
    var index = 0
    while index < queue.count {
        let artifact = queue[index]
        index += 1
        let header = try await run(
            "readelf",
            ["-h", artifact.string],
            workingDirectory: prefix,
            environment: environment,
            context: context)
        try validateELFArchitecture(
            header,
            artifact: artifact,
            expected: targetArchitecture)
        let dynamic = try await run(
            "readelf",
            ["-d", artifact.string],
            workingDirectory: prefix,
            environment: environment,
            context: context)
        let directDependencies = parseReadELFDynamic(dynamic).needed
        for soname in directDependencies.sorted() {
            guard let owner = NucleusLinuxABI.owner(ofSONAME: soname)
            else {
                throw RuntimeELFFailure(
                    "\(artifact) has unclassified dynamic dependency "
                        + soname)
            }
            let resolvedPath = try resolveELFDependency(
                soname,
                neededBy: artifact,
                runpath: parseReadELFDynamic(dynamic).runpath,
                environment: environment,
                preferredArtifactLibraryRoot: nil,
                owner: owner,
                files: context.files)
            let dependencyHeader = try await run(
                "readelf",
                ["-h", resolvedPath.string],
                workingDirectory: prefix,
                environment: environment,
                context: context)
            try validateELFArchitecture(
                dependencyHeader,
                artifact: resolvedPath,
                expected: targetArchitecture)
            guard owner == .artifact else { continue }
            let name = soname
            let destination = prefix.appending("lib").appending(name)
            if let existing = copiedDependencies[name] {
                if resolvedPath == destination || existing == resolvedPath {
                    continue
                }
                guard
                    try context.files.contentsEqual(
                        at: existing,
                        and: resolvedPath)
                else {
                    throw RuntimeELFFailure(
                        "dynamic dependency basename collision for \(name): "
                            + "\(existing) and \(resolvedPath)")
                }
                continue
            }
            try requireRegularFile(resolvedPath, files: context.files)
            try context.files.copy(from: resolvedPath, to: destination)
            try context.files.setPermissions(0o755, for: destination)
            copiedDependencies[name] = resolvedPath
            queue.append(destination)
        }
    }

    for library in copiedDependencies.keys.sorted() {
        try await requireSuccess(
            "patchelf",
            [
                "--set-rpath", "$ORIGIN",
                prefix.appending("lib")
                    .appending(library).string,
            ],
            workingDirectory: prefix,
            environment: environment,
            context: context)
    }
    for executable in executables {
        let path = RuntimeELFLayout.path(
            for: executable,
            under: prefix,
            staged: true)
        try await requireSuccess(
            "patchelf",
            ["--set-rpath", "$ORIGIN/../lib", path.string],
            workingDirectory: prefix,
            environment: environment,
            context: context)
    }
    for artifact in queue {
        try await requireSuccess(
            "llvm-strip",
            ["--strip-debug", artifact.string],
            workingDirectory: prefix,
            environment: environment,
            context: context)
    }
}

public struct ValidateRuntimeELFAction: ColliderAction {
    public struct Identity: ColliderActionIdentity {
        public let root: FilePath
        public let report: FilePath
        public let productSet: RuntimeELFProductSet

        public func encode(into encoder: inout IdentityEncoder) {
            encoder.append(path: root)
            encoder.append(path: report)
            encoder.append(productSet.rawValue)
        }
    }

    public static let kind: ActionKind = "shell.validate-runtime-elf"

    public let root: FilePath
    public let report: FilePath
    public let environment: [String: String]
    public let productSet: RuntimeELFProductSet
    public let executionPlatform: ExecutionPlatform

    public var identity: Identity {
        Identity(
            root: root,
            report: report,
            productSet: productSet)
    }

    public var requirements: ActionRequirements {
        ActionRequirements(
            tools: [
                ActionToolRequirement(
                    "readelf", executable: .named("readelf"), role: .semantic)
            ],
            effects: [
                ActionEffect(.read, scope: .input(root)),
                ActionEffect(.write, scope: .output(report)),
            ],
            executionPlatform: executionPlatform,
            artifactTarget: linuxArtifactTarget(for: executionPlatform))
    }

    public init(
        root: FilePath,
        report: FilePath,
        environment: [String: String],
        productSet: RuntimeELFProductSet = .baseRuntime,
        executionPlatform: ExecutionPlatform
    ) {
        self.root = root
        self.report = report
        self.environment = environment
        self.productSet = productSet
        self.executionPlatform = executionPlatform
    }

    public func execute(in context: ActionContext) async throws {
        try await validateRuntimeELF(
            root: root,
            report: report,
            environment: environment,
            productSet: productSet,
            targetArchitecture: executionPlatform.architecture,
            context: context)
    }
}

private func linuxArtifactTarget(
    for executionPlatform: ExecutionPlatform
) -> ArtifactTarget {
    precondition(
        executionPlatform.environment == .native
            && executionPlatform.operatingSystem == .linux)
    switch executionPlatform.architecture {
    case .arm64:
        return .linuxARM64
    case .x86_64:
        return .linuxX86_64
    }
}

func validateRuntimeELF(
    root: FilePath,
    report: FilePath,
    environment: [String: String],
    productSet: RuntimeELFProductSet,
    targetArchitecture: PlatformArchitecture,
    context: ActionContext
) async throws {
    let staged =
        try context.files.metadata(for: root.appending("bin"))?.type
        == .directory
        && context.files.metadata(for: root.appending("lib"))?.type
            == .directory
        && context.files.metadata(for: root.appending("libexec"))?.type
            == .directory
    var inspections: [String: RuntimeELFInspection] = [:]
    var reportExecutables: [RuntimeELFReport.Executable] = []
    var staticMetadataCache: [FilePath: RuntimeELFStaticMetadata] = [:]

    for executable in RuntimeELFLayout.executables(productSet: productSet) {
        let path = RuntimeELFLayout.path(
            for: executable,
            under: root,
            staged: staged)
        try requireRegularExecutable(path, files: context.files)
        let header = try await run(
            "readelf",
            ["-h", path.string],
            workingDirectory: root,
            environment: environment,
            context: context)
        try validateELFArchitecture(
            header,
            artifact: path,
            expected: targetArchitecture)
        let dynamic = try await run(
            "readelf",
            ["-d", path.string],
            workingDirectory: root,
            environment: environment,
            context: context)
        let inspection = parseReadELFDynamic(dynamic)
        let symbols = try await run(
            "readelf",
            ["--dyn-syms", "--wide", path.string],
            workingDirectory: root,
            environment: environment,
            context: context)
        _ = try await run(
            "readelf",
            ["--relocs", "--wide", path.string],
            workingDirectory: root,
            environment: environment,
            context: context)
        try validate(
            executable: executable,
            inspection: inspection,
            dynamicMetadata: dynamic,
            staged: staged)
        try validateGlibcImports(symbols, artifact: executable.name)
        try await validateStaticELFClosure(
            root: path,
            environment: environment,
            targetArchitecture: targetArchitecture,
            preferredArtifactLibraryRoot: staged ? root.appending("lib") : nil,
            workingDirectory: root,
            context: context,
            metadataCache: &staticMetadataCache)
        inspections[executable.name] = inspection
        reportExecutables.append(
            RuntimeELFReport.Executable(
                name: executable.name,
                path: path.string,
                runpath: inspection.runpath,
                needed: inspection.needed.sorted(),
                dependencies: try inspection.needed.sorted().map { soname in
                    guard let owner = NucleusLinuxABI.owner(ofSONAME: soname)
                    else {
                        throw RuntimeELFFailure(
                            "\(executable.name) has unclassified dynamic "
                                + "dependency \(soname)")
                    }
                    return RuntimeELFReport.Dependency(
                        soname: soname,
                        owner: owner)
                }))
    }

    try validateDependencyContracts(inspections)
    let value = RuntimeELFReport(
        root: root.string,
        staged: staged,
        minimumGlibcVersion: NucleusLinuxABI.minimumGlibcVersion,
        executables: reportExecutables)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var bytes = Array(try encoder.encode(value))
    bytes.append(0x0a)
    try context.files.write(bytes, to: report)
}

struct RuntimeELFInspection: Hashable, Sendable {
    let runpath: String
    let needed: Set<String>
}

func parseReadELFDynamic(_ output: String) -> RuntimeELFInspection {
    var runpath = ""
    var needed: Set<String> = []
    for line in output.split(separator: "\n") {
        if line.contains("(NEEDED)"),
            let value = bracketedValue(in: line)
        {
            needed.insert(value)
        } else if line.contains("(RUNPATH)") || line.contains("(RPATH)"),
            let value = bracketedValue(in: line)
        {
            runpath = value
        }
    }
    return RuntimeELFInspection(runpath: runpath, needed: needed)
}

struct RuntimeELFDynamicSymbols: Hashable, Sendable {
    let defined: Set<String>
    let undefined: Set<String>
}

struct RuntimeELFStaticMetadata: Hashable, Sendable {
    let dynamic: RuntimeELFInspection
    let symbols: RuntimeELFDynamicSymbols
}

func parseReadELFDynamicSymbols(_ output: String) -> RuntimeELFDynamicSymbols {
    var defined: Set<String> = []
    var undefined: Set<String> = []
    for line in output.split(separator: "\n") {
        let fields = line.split(whereSeparator: { $0.isWhitespace })
        guard fields.count >= 8,
            fields[0].last == ":",
            let symbol = normalizedELFSymbol(String(fields[7]))
        else { continue }
        let binding = fields[4]
        let section = fields[6]
        if section == "UND" {
            if binding != "WEAK" { undefined.insert(symbol) }
        } else {
            defined.insert(symbol)
        }
    }
    return RuntimeELFDynamicSymbols(
        defined: defined,
        undefined: undefined)
}

func validateELFArchitecture(
    _ header: String,
    artifact: FilePath,
    expected: PlatformArchitecture
) throws {
    guard
        let machineLine = header.split(separator: "\n").first(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("Machine:")
        })
    else {
        throw RuntimeELFFailure("\(artifact) has no ELF machine declaration")
    }
    let matches =
        switch expected {
        case .arm64:
            machineLine.contains("AArch64")
        case .x86_64:
            machineLine.contains("X86-64")
                || machineLine.contains("x86-64")
        }
    guard matches else {
        throw RuntimeELFFailure(
            "\(artifact) has \(machineLine.trimmingCharacters(in: .whitespaces)); "
                + "expected \(expected.rawValue)")
    }
}

private func normalizedELFSymbol(_ value: String) -> String? {
    guard !value.isEmpty else { return nil }
    return value.replacingOccurrences(of: "@@", with: "@")
}

private func resolveELFDependency(
    _ soname: String,
    neededBy artifact: FilePath,
    runpath: String,
    environment: [String: String],
    preferredArtifactLibraryRoot: FilePath?,
    owner: NucleusLinuxABI.ELFOwner,
    files: ActionFileSystem
) throws -> FilePath {
    var roots: [FilePath] = []
    if owner == .artifact, let preferredArtifactLibraryRoot {
        roots.append(preferredArtifactLibraryRoot)
    }
    if let value = environment["NUCLEUS_TARGET_LIBRARY_PATH"] {
        roots += value.split(separator: ":").map { FilePath(String($0)) }
    }
    let origin = artifact.removingLastComponent().string
    for component in runpath.split(separator: ":") {
        let expanded = String(component)
            .replacingOccurrences(of: "${ORIGIN}", with: origin)
            .replacingOccurrences(of: "$ORIGIN", with: origin)
        let path = FilePath(expanded)
        guard path.isAbsolute else { continue }
        roots.append(path.lexicallyNormalized())
    }
    var searched: [String] = []
    var unique: Set<FilePath> = []
    for root in roots where unique.insert(root).inserted {
        let candidate = root.appending(soname)
        searched.append(candidate.string)
        if try files.metadata(for: candidate)?.type == .regular {
            return candidate
        }
    }
    throw RuntimeELFFailure(
        "\(artifact) has unresolved dynamic dependency \(soname); searched "
            + searched.joined(separator: ", "))
}

private func validateStaticELFClosure(
    root: FilePath,
    environment: [String: String],
    targetArchitecture: PlatformArchitecture,
    preferredArtifactLibraryRoot: FilePath?,
    workingDirectory: FilePath,
    context: ActionContext,
    metadataCache: inout [FilePath: RuntimeELFStaticMetadata]
) async throws {
    var queue = [root]
    var visited: Set<FilePath> = []
    var defined: Set<String> = []
    var undefined: Set<String> = []

    while let artifact = queue.popLast() {
        guard visited.insert(artifact).inserted else { continue }
        let metadata: RuntimeELFStaticMetadata
        if let cached = metadataCache[artifact] {
            metadata = cached
        } else {
            let header = try await run(
                "readelf",
                ["-h", artifact.string],
                workingDirectory: workingDirectory,
                environment: environment,
                context: context)
            try validateELFArchitecture(
                header,
                artifact: artifact,
                expected: targetArchitecture)
            let dynamic = parseReadELFDynamic(
                try await run(
                    "readelf",
                    ["-d", artifact.string],
                    workingDirectory: workingDirectory,
                    environment: environment,
                    context: context))
            let symbols = parseReadELFDynamicSymbols(
                try await run(
                    "readelf",
                    ["--dyn-syms", "--wide", artifact.string],
                    workingDirectory: workingDirectory,
                    environment: environment,
                    context: context))
            _ = try await run(
                "readelf",
                ["--relocs", "--wide", artifact.string],
                workingDirectory: workingDirectory,
                environment: environment,
                context: context)
            metadata = RuntimeELFStaticMetadata(
                dynamic: dynamic,
                symbols: symbols)
            metadataCache[artifact] = metadata
        }
        defined.formUnion(metadata.symbols.defined)
        undefined.formUnion(metadata.symbols.undefined)
        for soname in metadata.dynamic.needed.sorted() {
            let owner = NucleusLinuxABI.owner(ofSONAME: soname) ?? .host
            queue.append(
                try resolveELFDependency(
                    soname,
                    neededBy: artifact,
                    runpath: metadata.dynamic.runpath,
                    environment: environment,
                    preferredArtifactLibraryRoot: preferredArtifactLibraryRoot,
                    owner: owner,
                    files: context.files))
        }
    }

    let unresolved = undefined.subtracting(defined).sorted()
    guard unresolved.isEmpty else {
        throw RuntimeELFFailure(
            "\(root) has unresolved dynamic symbols: "
                + unresolved.joined(separator: ", "))
    }
}

private enum RuntimeELFLayout {
    struct Executable: Hashable, Sendable {
        enum Location: Hashable, Sendable {
            case bin
            case libexec
        }

        let name: String
        let location: Location
    }

    static let coreExecutables = [
        Executable(name: "NucleusCompositor", location: .bin),
        Executable(name: "NucleusShell", location: .bin),
        Executable(name: "NucleusSessionSupervisor", location: .libexec),
        Executable(name: "NucleusConfigService", location: .libexec),
        Executable(name: "NucleusControlService", location: .libexec),
        Executable(name: "NucleusShellPamHelper", location: .libexec),
        Executable(name: "nucleus", location: .bin),
    ]

    static let androidExecutables = [
        Executable(name: "nucleus-android-runtime", location: .libexec),
        Executable(
            name: "nucleus-android-runtime-privileged",
            location: .libexec),
        Executable(
            name: "nucleus-android-gfxstream-broker",
            location: .libexec),
        Executable(
            name: "nucleus-android-display-host",
            location: .libexec),
    ]

    static func executables(productSet: RuntimeELFProductSet) -> [Executable] {
        switch productSet {
        case .baseRuntime: coreExecutables
        case .androidAddon: androidExecutables
        }
    }

    static let requiredDependencies: [String: Set<String>] = [
        "NucleusCompositor": [
            "libvulkan.so.1", "libdrm.so.2", "libwayland-server.so.0",
        ],
        "NucleusShell": ["libvulkan.so.1", "libwayland-client.so.0"],
        "NucleusSessionSupervisor": ["libsystemd.so.0"],
        "NucleusConfigService": ["libsystemd.so.0"],
        "NucleusControlService": ["libsystemd.so.0"],
        "NucleusShellPamHelper": ["libpam.so.0"],
    ]

    static let restrictedExecutables: Set<String> = [
        "NucleusSessionSupervisor",
        "NucleusConfigService",
        "NucleusControlService",
        "NucleusShellPamHelper",
        "nucleus",
    ]

    static let forbiddenDependencies: Set<String> = [
        "libvulkan.so.1",
        "libdrm.so.2",
        "libgbm.so.1",
        "libwayland-client.so.0",
        "libwayland-server.so.0",
        "libinput.so.10",
        "libudev.so.1",
        "libseat.so.1",
    ]

    static func path(
        for executable: Executable,
        under root: FilePath,
        staged: Bool
    ) -> FilePath {
        guard staged else { return root.appending(executable.name) }
        let directory =
            switch executable.location {
            case .bin: "bin"
            case .libexec: "libexec"
            }
        return root.appending(directory).appending(executable.name)
    }

    static func stagingDirectories(root: FilePath) -> [FilePath] {
        [
            root.appending("bin"),
            root.appending("lib"),
            root.appending("libexec"),
            root.appending("share").appending("nucleus"),
        ]
    }

}

private func validate(
    executable: RuntimeELFLayout.Executable,
    inspection: RuntimeELFInspection,
    dynamicMetadata: String,
    staged: Bool
) throws {
    if staged {
        guard inspection.runpath == "$ORIGIN/../lib" else {
            throw RuntimeELFFailure(
                "\(executable.name) has staged runpath "
                    + "'\(inspection.runpath)', expected $ORIGIN/../lib")
        }
    } else {
        guard inspection.runpath.contains("$ORIGIN") else {
            throw RuntimeELFFailure(
                "\(executable.name) has no origin-relative runtime search path")
        }
    }
    guard !inspection.needed.contains(where: { $0.contains("/") }) else {
        throw RuntimeELFFailure(
            "\(executable.name) contains a path-qualified dependency")
    }
    guard !inspection.needed.contains(where: isFirstPartySharedLibrary) else {
        throw RuntimeELFFailure(
            "\(executable.name) depends on a first-party shared library")
    }
    for dependency in inspection.needed.sorted()
    where NucleusLinuxABI.owner(ofSONAME: dependency) == nil {
        throw RuntimeELFFailure(
            "\(executable.name) has unclassified dynamic dependency \(dependency)")
    }
    if staged {
        let developmentMarkers = [
            "/home/",
            "/Users/",
            "/nucleus-native-sdk",
            "/.nucleus/",
            "/Products/",
        ]
        guard !developmentMarkers.contains(where: dynamicMetadata.contains)
        else {
            throw RuntimeELFFailure(
                "\(executable.name) retains a development path "
                    + "in its dynamic metadata")
        }
    }
}

func validateGlibcImports(_ symbols: String, artifact: String) throws {
    let maximum = NucleusLinuxABI.minimumGlibcVersion.split(separator: ".").map {
        Int($0) ?? 0
    }
    for line in symbols.split(separator: "\n") where line.contains("*UND*") {
        for token in line.split(whereSeparator: { $0.isWhitespace }) {
            guard let marker = token.range(of: "GLIBC_") else { continue }
            let version = token[marker.upperBound...].prefix {
                $0.isNumber || $0 == "."
            }
            let components = version.split(separator: ".").map { Int($0) ?? 0 }
            if components.lexicographicallyPrecedes(maximum) || components == maximum {
                continue
            }
            throw RuntimeELFFailure(
                "\(artifact) imports GLIBC_\(version), newer than the "
                    + "Nucleus Linux ABI baseline GLIBC_"
                    + NucleusLinuxABI.minimumGlibcVersion)
        }
    }
}

func validateDependencyContracts(
    _ inspections: [String: RuntimeELFInspection]
) throws {
    for (executable, required) in RuntimeELFLayout.requiredDependencies {
        guard let inspection = inspections[executable] else {
            throw RuntimeELFFailure("missing inspection for \(executable)")
        }
        for dependency in required where !inspection.needed.contains(dependency) {
            throw RuntimeELFFailure(
                "\(executable) does not depend on \(dependency)")
        }
    }
    for executable in RuntimeELFLayout.restrictedExecutables {
        guard let inspection = inspections[executable] else {
            throw RuntimeELFFailure("missing inspection for \(executable)")
        }
        if let dependency = inspection.needed.intersection(
            RuntimeELFLayout.forbiddenDependencies
        ).sorted().first {
            throw RuntimeELFFailure(
                "\(executable) unexpectedly depends on \(dependency)")
        }
    }
}

private func isFirstPartySharedLibrary(_ name: String) -> Bool {
    guard name.hasPrefix("lib"), name.hasSuffix(".so") else { return false }
    return ["Nucleus", "SwiftTracy", "SwiftVulkan", "SwiftWayland"]
        .contains { name.dropFirst(3).hasPrefix($0) }
}

private func bracketedValue(in line: Substring) -> String? {
    guard let opening = line.firstIndex(of: "["),
        let closing = line[opening...].firstIndex(of: "]")
    else { return nil }
    return String(line[line.index(after: opening)..<closing])
}

private func requireRegularFile(
    _ path: FilePath,
    files: ActionFileSystem
) throws {
    guard try files.metadata(for: path)?.type == .regular else {
        throw RuntimeELFFailure("missing regular file \(path)")
    }
}

private func requireRegularExecutable(
    _ path: FilePath,
    files: ActionFileSystem
) throws {
    guard let metadata = try files.metadata(for: path),
        metadata.type == .regular,
        metadata.ownerExecutable
    else {
        throw RuntimeELFFailure("missing or non-executable artifact \(path)")
    }
}

@discardableResult
private func run(
    _ executable: String,
    _ arguments: [String],
    workingDirectory: FilePath,
    environment: [String: String],
    context: ActionContext
) async throws -> String {
    try await run(
        .named(executable),
        label: executable,
        arguments,
        workingDirectory: workingDirectory,
        environment: environment,
        context: context)
}

@discardableResult
private func run(
    _ executable: CommandSpec.Executable,
    label: String,
    _ arguments: [String],
    workingDirectory: FilePath,
    environment: [String: String],
    context: ActionContext
) async throws -> String {
    let result = try await context.commands.execute(
        CommandSpec(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            output: .combined(limit: 64 * 1024 * 1024)))
    guard result.succeeded else {
        throw result.executionFailure(
            reason: "\(label) failed:\n" + result.standardOutput)
    }
    return result.standardOutput
}

private func requireSuccess(
    _ executable: String,
    _ arguments: [String],
    workingDirectory: FilePath,
    environment: [String: String],
    context: ActionContext,
    failure: String? = nil
) async throws {
    do {
        _ = try await run(
            executable,
            arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            context: context)
    } catch {
        guard let failure else { throw error }
        throw RuntimeELFFailure("\(failure): \(error)")
    }
}

struct RuntimeELFFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = "runtime ELF operation failed: \(description)"
    }
}
