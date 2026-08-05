import ColliderCore
import Foundation
import SystemPackage

public struct RuntimeELFReport: Codable, Hashable, Sendable {
    public struct Executable: Codable, Hashable, Sendable {
        public let name: String
        public let path: String
        public let runpath: String
        public let needed: [String]
    }

    public let root: String
    public let staged: Bool
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

        public func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: products.string)
            encoder.append(tag: 2, string: prefix.string)
            encoder.append(tag: 3, string: productSet.rawValue)
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
                    "ldd", executable: .named("ldd"), role: .semantic),
                ActionToolRequirement(
                    "patchelf", executable: .named("patchelf"), role: .semantic),
                ActionToolRequirement(
                    "strip", executable: .named("strip"), role: .semantic),
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
            context: context)
    }
}

package func stageRuntimeELF(
    products: FilePath,
    prefix: FilePath,
    environment: [String: String],
    productSet: RuntimeELFProductSet,
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
        let output = try await run(
            "ldd",
            [artifact.string],
            workingDirectory: prefix,
            environment: environment,
            context: context)
        for dependency in parseLDDResolvedPaths(output)
        where !RuntimeELFLayout.isSystemLibrary(dependency) {
            let name = dependency.lastComponent?.string ?? dependency.string
            let destination = prefix.appending("lib").appending(name)
            if let existing = copiedDependencies[name] {
                if dependency == destination || existing == dependency {
                    continue
                }
                guard
                    try context.files.contentsEqual(
                        at: existing,
                        and: dependency)
                else {
                    throw RuntimeELFFailure(
                        "dynamic dependency basename collision for \(name): "
                            + "\(existing) and \(dependency)")
                }
                continue
            }
            try requireRegularFile(dependency, files: context.files)
            try context.files.copy(from: dependency, to: destination)
            try context.files.setPermissions(0o755, for: destination)
            copiedDependencies[name] = dependency
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
            "strip",
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

        public func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: root.string)
            encoder.append(tag: 2, string: report.string)
            encoder.append(tag: 3, string: productSet.rawValue)
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
                    "readelf", executable: .named("readelf"), role: .semantic),
                ActionToolRequirement(
                    "ldd", executable: .named("ldd"), role: .operational),
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

    for executable in RuntimeELFLayout.executables(productSet: productSet) {
        let path = RuntimeELFLayout.path(
            for: executable,
            under: root,
            staged: staged)
        try requireRegularExecutable(path, files: context.files)
        try await requireSuccess(
            "readelf",
            ["-h", path.string],
            workingDirectory: root,
            environment: environment,
            context: context,
            failure: "\(executable.name) is not an ELF executable")
        let dynamic = try await run(
            "readelf",
            ["-d", path.string],
            workingDirectory: root,
            environment: environment,
            context: context)
        let inspection = parseReadELFDynamic(dynamic)
        try validate(
            executable: executable,
            inspection: inspection,
            dynamicMetadata: dynamic,
            staged: staged)
        let relocation: String
        do {
            relocation = try await run(
                "ldd",
                ["-r", path.string],
                workingDirectory: root,
                environment: environment,
                context: context)
        } catch {
            throw RuntimeELFFailure(
                "\(executable.name) failed relocation validation: \(error)")
        }
        guard !relocation.contains("not found"),
            !relocation.contains("undefined symbol")
        else {
            throw RuntimeELFFailure(
                "\(executable.name) has an unresolved dependency:\n"
                    + relocation)
        }
        inspections[executable.name] = inspection
        reportExecutables.append(
            RuntimeELFReport.Executable(
                name: executable.name,
                path: path.string,
                runpath: inspection.runpath,
                needed: inspection.needed.sorted()))
    }

    try validateDependencyContracts(inspections)
    let value = RuntimeELFReport(
        root: root.string,
        staged: staged,
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

func parseLDDResolvedPaths(_ output: String) -> [FilePath] {
    output.split(separator: "\n").compactMap { rawLine in
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if let arrow = line.range(of: "=> /") {
            let suffix = line[arrow.upperBound...]
            let path = "/" + suffix.prefix { !$0.isWhitespace }
            return FilePath(String(path))
        }
        guard line.hasPrefix("/") else { return nil }
        return FilePath(String(line.prefix { !$0.isWhitespace }))
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

    static func isSystemLibrary(_ path: FilePath) -> Bool {
        let value = path.string
        return value.hasPrefix("/lib/")
            || value.hasPrefix("/lib64/")
            || value.hasPrefix("/usr/lib/")
            || value.hasPrefix("/usr/lib64/")
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
    let result = try await context.commands.execute(
        CommandSpec(
            executable: .named(executable),
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            output: .combined(limit: 64 * 1024 * 1024)))
    guard result.status == 0 else {
        throw RuntimeELFFailure(
            "\(executable) failed with status \(result.status):\n"
                + result.standardOutput)
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
