import ColliderCore
import Foundation
import NativeBuilderColliderRecipe
import Synchronization
import SystemPackage
import Testing

@testable import ShellColliderRecipe

@Test func readELFDynamicMetadataIsParsedIntoTypedValues() {
    let inspection = parseReadELFDynamic(
        """
         0x0000000000000001 (NEEDED) Shared library: [libvulkan.so.1]
         0x0000000000000001 (NEEDED) Shared library: [libdrm.so.2]
         0x000000000000001d (RUNPATH) Library runpath: [$ORIGIN/../lib]
        """)

    #expect(inspection.runpath == "$ORIGIN/../lib")
    #expect(inspection.needed == ["libvulkan.so.1", "libdrm.so.2"])
}

@Test func dynamicSymbolMetadataSeparatesDefinitionsAndStrongImports() {
    let symbols = parseReadELFDynamicSymbols(
        """
              1: 0000000000001000 12 FUNC GLOBAL DEFAULT 12 provided@@GLIBC_2.38
              2: 0000000000000000  0 FUNC GLOBAL DEFAULT UND provided@GLIBC_2.38 (2)
              3: 0000000000000000  0 NOTYPE WEAK DEFAULT UND optional
        """)

    #expect(symbols.defined == ["provided@GLIBC_2.38"])
    #expect(symbols.undefined == ["provided@GLIBC_2.38"])
}

@Test func ELFMachineMustMatchTheDeclaredArtifactArchitecture() throws {
    try validateELFArchitecture(
        "Machine:                           Advanced Micro Devices X86-64",
        artifact: FilePath("/fixture"),
        expected: .x86_64)
    #expect(throws: RuntimeELFFailure.self) {
        try validateELFArchitecture(
            "Machine:                           AArch64",
            artifact: FilePath("/fixture"),
            expected: .x86_64)
    }
}

@Test func linuxABIContractRejectsUnknownDependencies() {
    #expect(NucleusLinuxABI.minimumGlibcVersion == "2.38")
    #expect(NucleusLinuxABI.owner(ofSONAME: "libswiftCore.so") == .artifact)
    #expect(NucleusLinuxABI.owner(ofSONAME: "libc++.so.1") == .artifact)
    #expect(NucleusLinuxABI.owner(ofSONAME: "libvulkan.so.1") == .host)
    #expect(NucleusLinuxABI.owner(ofSONAME: "libstdc++.so.6") == nil)
}

@Test func glibcImportsCannotExceedTheLinuxABIBaseline() throws {
    try validateGlibcImports(
        "0000 DF *UND* 0000 (GLIBC_2.38) fmod",
        artifact: "valid")
    #expect(throws: RuntimeELFFailure.self) {
        try validateGlibcImports(
            "0000 DF *UND* 0000 (GLIBC_2.39) future",
            artifact: "future")
    }
}

@Test func dependencyContractsRejectRenderLibrariesAtPrivilegeBoundaries() {
    var inspections = validInspections()
    inspections["NucleusShellPamHelper"] = RuntimeELFInspection(
        runpath: "$ORIGIN",
        needed: ["libpam.so.0", "libvulkan.so.1"])

    #expect(throws: RuntimeELFFailure.self) {
        try validateDependencyContracts(inspections)
    }
}

@Test func componentActionsHaveStableDistinctIdentity() throws {
    let first = try AnyColliderAction(
        ValidateRuntimeELFAction(
            root: FilePath("/products"),
            report: FilePath("/products/report.json"),
            environment: ["PATH": "/one"],
            executionPlatform: .linuxX86_64Native))
    let sameDeclaration = try AnyColliderAction(
        ValidateRuntimeELFAction(
            root: FilePath("/products"),
            report: FilePath("/products/report.json"),
            environment: ["PATH": "/one"],
            executionPlatform: .linuxX86_64Native))
    let differentOutput = try AnyColliderAction(
        ValidateRuntimeELFAction(
            root: FilePath("/products"),
            report: FilePath("/elsewhere/report.json"),
            environment: ["PATH": "/one"],
            executionPlatform: .linuxX86_64Native))
    let androidPackage = try AnyColliderAction(
        ValidateRuntimeELFAction(
            root: FilePath("/products"),
            report: FilePath("/products/report.json"),
            environment: ["PATH": "/one"],
            productSet: .androidPackage,
            executionPlatform: .linuxX86_64Native))

    #expect(first == sameDeclaration)
    #expect(first != differentOutput)
    #expect(first != androidPackage)
    #expect(first.kind == "shell.validate-runtime-elf")
}

@Test func validationActionInspectsEveryProcessAndWritesTypedJSON() async throws {
    let reportBytes = Mutex<[UInt8]?>(nil)
    let inspections = validInspections()
    let files = ActionFileSystem(
        metadata: { path in
            if ["/products/bin", "/products/lib", "/products/libexec"]
                .contains(path.string)
            {
                return nil
            }
            return ActionFileSystem.Metadata(
                type: .regular,
                ownerExecutable: true)
        },
        contentsEqual: { _, _ in false },
        createDirectory: { _ in },
        copy: { _, _ in },
        setPermissions: { _, _ in },
        write: { bytes, _ in
            reportBytes.withLock { $0 = bytes }
        })
    let context = testActionContext(files: files) { command in
        let executable = commandExecutableName(command.executable)
        let name =
            command.arguments.last.map {
                FilePath($0).lastComponent?.string ?? $0
            } ?? ""
        if executable == "readelf", command.arguments.first == "-h" {
            return CommandResult(
                status: 0,
                standardOutput:
                    "Machine:                           Advanced Micro Devices X86-64")
        }
        if executable == "readelf", command.arguments.first == "-d",
            let inspection = inspections[name]
        {
            let needed = inspection.needed.sorted().map {
                " 0x1 (NEEDED) Shared library: [\($0)]"
            }
            return CommandResult(
                status: 0,
                standardOutput: (needed
                    + [
                        " 0x1 (RUNPATH) Library runpath: "
                            + "[\(inspection.runpath)]"
                    ]).joined(separator: "\n"))
        }
        return CommandResult(status: 0)
    }

    try await ValidateRuntimeELFAction(
        root: FilePath("/products"),
        report: FilePath("/products/runtime-elf-report.json"),
        environment: ["NUCLEUS_TARGET_LIBRARY_PATH": "/target-libraries"],
        executionPlatform: .linuxX86_64Native
    ).execute(in: context)

    let bytes = try #require(reportBytes.withLock { $0 })
    let report = try JSONDecoder().decode(RuntimeELFReport.self, from: Data(bytes))
    #expect(report.staged == false)
    #expect(report.minimumGlibcVersion == "2.38")
    #expect(report.executables.count == 7)
    #expect(report.executables.map(\.name).contains("NucleusCompositor"))
    #expect(
        report.executables.first { $0.name == "NucleusCompositor" }?
            .dependencies.first { $0.soname == "libvulkan.so.1" }?.owner
            == .host)
}

@Test func stagingActionCopiesTheDynamicClosureAndRewritesEveryRunpath() async throws {
    struct Recording: Sendable {
        var copies: [(String, String)] = []
        var commands: [(String, [String])] = []
    }
    let recording = Mutex(Recording())
    let files = ActionFileSystem(
        metadata: { _ in
            ActionFileSystem.Metadata(type: .regular, ownerExecutable: true)
        },
        contentsEqual: { _, _ in false },
        createDirectory: { _ in },
        copy: { source, destination in
            recording.withLock {
                $0.copies.append((source.string, destination.string))
            }
        },
        setPermissions: { _, _ in },
        write: { _, _ in })
    let context = testActionContext(files: files) { command in
        let executable = commandExecutableName(command.executable)
        recording.withLock {
            $0.commands.append((executable, command.arguments))
        }
        if executable == "readelf", command.arguments.first == "-h" {
            return CommandResult(
                status: 0,
                standardOutput:
                    "Machine:                           Advanced Micro Devices X86-64")
        }
        if executable == "readelf", command.arguments.first == "-d" {
            return CommandResult(
                status: 0,
                standardOutput:
                    " 0x1 (NEEDED) Shared library: [libswiftCore.so]\n")
        }
        return CommandResult(status: 0)
    }

    try await StageRuntimeELFAction(
        products: FilePath("/products"),
        prefix: FilePath("/runtime"),
        environment: [
            "NUCLEUS_TARGET_LIBRARY_PATH": "/toolchain"
        ],
        executionPlatform: .linuxX86_64Native
    ).execute(in: context)

    let result = recording.withLock { $0 }
    #expect(result.copies.count == 8)
    #expect(
        result.copies.contains {
            $0 == ("/toolchain/libswiftCore.so", "/runtime/lib/libswiftCore.so")
        })
    #expect(result.commands.filter { $0.0 == "patchelf" }.count == 8)
    #expect(result.commands.filter { $0.0 == "llvm-strip" }.count == 8)
}

@Test func stagingActionRejectsAnUnresolvedArtifactDependency() async {
    let files = ActionFileSystem(
        metadata: { path in
            if path.string == "/missing/libswiftCore.so" { return nil }
            return ActionFileSystem.Metadata(type: .regular, ownerExecutable: true)
        },
        contentsEqual: { _, _ in false },
        createDirectory: { _ in },
        copy: { _, _ in },
        setPermissions: { _, _ in },
        write: { _, _ in })
    let context = testActionContext(files: files) { command in
        let executable = commandExecutableName(command.executable)
        if executable == "readelf", command.arguments.first == "-h" {
            return CommandResult(
                status: 0,
                standardOutput:
                    "Machine:                           Advanced Micro Devices X86-64")
        }
        if executable == "readelf", command.arguments.first == "-d" {
            return CommandResult(
                status: 0,
                standardOutput:
                    " 0x1 (NEEDED) Shared library: [libswiftCore.so]\n")
        }
        return CommandResult(status: 0)
    }

    await #expect(throws: RuntimeELFFailure.self) {
        try await StageRuntimeELFAction(
            products: FilePath("/products"),
            prefix: FilePath("/runtime"),
            environment: ["NUCLEUS_TARGET_LIBRARY_PATH": "/missing"],
            executionPlatform: .linuxX86_64Native
        ).execute(in: context)
    }
}

private func validInspections() -> [String: RuntimeELFInspection] {
    [
        "NucleusCompositor": RuntimeELFInspection(
            runpath: "$ORIGIN",
            needed: [
                "libvulkan.so.1",
                "libdrm.so.2",
                "libwayland-server.so.0",
            ]),
        "NucleusShell": RuntimeELFInspection(
            runpath: "$ORIGIN",
            needed: ["libvulkan.so.1", "libwayland-client.so.0"]),
        "NucleusSessionSupervisor": RuntimeELFInspection(
            runpath: "$ORIGIN",
            needed: ["libsystemd.so.0"]),
        "NucleusConfigService": RuntimeELFInspection(
            runpath: "$ORIGIN",
            needed: ["libsystemd.so.0"]),
        "NucleusControlService": RuntimeELFInspection(
            runpath: "$ORIGIN",
            needed: ["libsystemd.so.0"]),
        "NucleusShellPamHelper": RuntimeELFInspection(
            runpath: "$ORIGIN",
            needed: ["libpam.so.0"]),
        "nucleus": RuntimeELFInspection(runpath: "$ORIGIN", needed: []),
    ]
}

private func testActionContext(
    files: ActionFileSystem,
    execute: @escaping @Sendable (CommandSpec) async throws -> CommandResult
) -> ActionContext {
    ActionContext(
        files: files,
        cancellation: ActionCancellation {},
        logger: ActionLogger { _ in },
        commands: ActionCommandExecutor(execute: execute),
        downloads: ActionDownloader { _, _ in })
}

private func commandExecutableName(_ executable: CommandSpec.Executable) -> String {
    switch executable {
    case .named(let name), .operationalNamed(let name):
        return name
    case .path(let path), .taskOutput(let path):
        return path.lastComponent?.string ?? path.string
    case .artifact:
        return "artifact"
    }
}
