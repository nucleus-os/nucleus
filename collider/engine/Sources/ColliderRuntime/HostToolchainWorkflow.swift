import ColliderCore
import Foundation
import SystemPackage

extension ColliderRuntime {
    func prepareHostToolchainBuild(
        _ preparation: HostToolchainBuildPreparation
    ) throws {
        try hostRemoveExisting(preparation.stagingRoot)
        try FileManager.default.createDirectory(
            atPath: preparation.stagingRoot.string,
            withIntermediateDirectories: true)
        try DurableFile.write(
            Data("nucleus\n".utf8),
            to: preparation.stagingRoot.appending(".nucleus-owned"))
        guard preparation.platform == .linux else { return }
        let llvmLibrary = preparation.workspace.appending(
            "build/buildbot_linux/llvm-linux-x86_64/lib")
        let buildSwiftLibrary = preparation.workspace.appending(
            "build/buildbot_linux/swift-linux-x86_64/lib/swift/linux")
        let installSwiftLibrary = preparation.stagingRoot.appending(
            "usr/lib/swift/linux")
        try FileManager.default.createDirectory(
            atPath: buildSwiftLibrary.string,
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: installSwiftLibrary.string,
            withIntermediateDirectories: true)
        for library in [
            "libc++.so", "libc++.so.1", "libc++.so.1.0",
            "libc++abi.so", "libc++abi.so.1", "libc++abi.so.1.0",
            "libunwind.so", "libunwind.so.1", "libunwind.so.1.0",
        ] {
            try hostReplaceSymlink(
                llvmLibrary.appending(library).string,
                at: buildSwiftLibrary.appending(library))
            try hostReplaceSymlink(
                "../../\(library)",
                at: installSwiftLibrary.appending(library))
        }
        let compilerConfiguration = """
        -L<CFGDIR>/../lib

        """
        for name in ["clang.cfg", "clang++.cfg"] {
            try DurableFile.write(
                Data(compilerConfiguration.utf8),
                to: preparation.stagingRoot.appending("usr/bin/\(name)"))
        }
    }

    func assembleHostToolchain(
        _ assembly: HostToolchainAssembly
    ) throws {
        let staged = assembly.stagingRoot.appending("usr")
        guard hostIsDirectory(staged) else {
            throw RuntimeFailure.invalidOutput(
                "upstream Swift build did not produce \(staged)")
        }
        try hostRemoveExisting(assembly.toolchain)
        try FileManager.default.createDirectory(
            atPath: assembly.toolchain.removingLastComponent().string,
            withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            atPath: staged.string,
            toPath: assembly.toolchain.string)
        try? FileManager.default.removeItem(
            atPath: assembly.stagingRoot.appending(".nucleus-owned").string)
        guard assembly.platform == .linux else { return }

        let library = assembly.toolchain.appending("lib")
        let cfxmlStatic = library.appending(
            "swift_static/linux/lib_CFXMLInterface.a")
        guard hostIsRegularFile(cfxmlStatic) else {
            throw RuntimeFailure.invalidOutput(
                "host FoundationXML support archive is missing: "
                    + "\(cfxmlStatic)")
        }
        try hostCopyReplacing(
            from: cfxmlStatic,
            to: library.appending("swift/linux/lib_CFXMLInterface.a"))
        let staticArguments = library.appending(
            "swift_static/linux/static-stdlib-args.lnk")
        guard hostIsRegularFile(staticArguments) else {
            throw RuntimeFailure.invalidOutput(
                "host static Swift link metadata is missing: "
                    + "\(staticArguments)")
        }
        var arguments = try String(
            contentsOfFile: staticArguments.string,
            encoding: .utf8)
        if !arguments.contains("-lswift_StringProcessing") {
            if !arguments.hasSuffix("\n") { arguments.append("\n") }
            arguments += """
            -Xlinker --start-group
            -lFoundation
            -lFoundationEssentials
            -lFoundationInternationalization
            -lFoundationNetworking
            -lFoundationXML
            -l_CFXMLInterface
            -lCoreFoundation
            -l_FoundationICU
            -l_FoundationCShims
            -l_FoundationCollections
            -lswift_StringProcessing
            -lswift_RegexParser
            -lswiftRegexBuilder
            -lswift_Concurrency
            -lswiftObservation
            -lswiftSynchronization
            -lswiftSwiftOnoneSupport
            -Xlinker --end-group

            """
        } else if !arguments.contains("-l_CFXMLInterface") {
            arguments += "\n-l_CFXMLInterface\n"
        }
        if !arguments.contains("-lxml2") {
            arguments += "\n-lxml2\n"
        }
        try DurableFile.write(Data(arguments.utf8), to: staticArguments)
        let testingInterop = assembly.workspace.appending(
            "build/buildbot_linux/swifttesting-linux-x86_64/lib/"
                + "lib_TestingInterop.so")
        if hostIsRegularFile(testingInterop) {
            try hostCopyReplacing(
                from: testingInterop,
                to: library.appending(
                    "swift/linux/lib_TestingInterop.so"))
        }
    }

    func validateHostToolchain(
        _ validation: HostToolchainValidation,
        stage: TaskID
    ) async throws {
        let executables: [String]
        let products: [String]
        let targets: [String]
        switch validation.platform {
        case .linux:
            executables = [
                "swift", "swiftc", "clang", "clang++", "lldb",
                "lldb-argdumper", "lldb-dap", "lldb-server", "repl_swift",
                "sourcekit-lsp", "swift-format", "docc", "wasmkit",
            ]
            products = [
                "lib/liblldb.so",
                "lib/libIndexStore.so",
                "lib/libSwiftSourceKitClientPlugin.so",
                "lib/libSwiftSourceKitPlugin.so",
                "lib/swift/linux/Foundation.swiftmodule",
                "lib/swift/linux/FoundationEssentials.swiftmodule",
                "lib/swift/linux/FoundationInternationalization.swiftmodule",
                "lib/swift/linux/FoundationNetworking.swiftmodule",
                "lib/swift/linux/FoundationXML.swiftmodule",
                "lib/swift/linux/Dispatch.swiftmodule",
                "lib/swift/linux/libFoundation.so",
                "lib/swift/linux/libdispatch.so",
                "lib/swift_static/linux/Foundation.swiftmodule",
                "lib/swift_static/linux/Dispatch.swiftmodule",
                "lib/swift_static/linux/Glibc.swiftmodule",
                "lib/swift_static/linux/libFoundation.a",
                "lib/swift_static/linux/libdispatch.a",
                "lib/swift/embedded",
                "lib/swift_static/embedded",
                "share/docc/render",
            ]
            targets = [
                "aarch64", "arm", "avr", "bpf", "mips", "ppc32",
                "riscv32", "systemz", "wasm32", "x86",
            ]
        case .macOS:
            executables = [
                "swift", "swiftc", "swift-frontend", "clang", "lldb",
                "lldb-argdumper", "lldb-dap", "lldb-server", "repl_swift",
                "sourcekit-lsp", "swift-format", "docc", "wasmkit",
            ]
            products = [
                "lib/libIndexStore.dylib",
                "lib/libSwiftSourceKitClientPlugin.dylib",
                "lib/libSwiftSourceKitPlugin.dylib",
                "lib/swift/macosx",
                "lib/swift/iphoneos",
                "lib/swift/iphonesimulator",
                "lib/swift/appletvos",
                "lib/swift/appletvsimulator",
                "lib/swift/watchos",
                "lib/swift/watchsimulator",
                "lib/swift/xros",
                "lib/swift/xrsimulator",
                "lib/swift/embedded",
                "share/docc/render",
            ]
            targets = ["aarch64", "arm", "wasm32", "x86"]
        }
        for executable in executables {
            let path = validation.toolchain.appending("bin/\(executable)")
            guard FileManager.default.isExecutableFile(
                atPath: path.string)
            else {
                throw RuntimeFailure.invalidOutput(
                    "host toolchain executable is missing: \(path)")
            }
        }
        for product in products {
            let path = validation.toolchain.appending(product)
            guard FileManager.default.fileExists(atPath: path.string) else {
                throw RuntimeFailure.invalidOutput(
                    "host toolchain product is missing: \(path)")
            }
        }
        try hostRemoveExisting(validation.workDirectory)
        try FileManager.default.createDirectory(
            atPath: validation.workDirectory.string,
            withIntermediateDirectories: true)
        let home = validation.workDirectory.appending("home")
        let temporary = validation.workDirectory.appending("tmp")
        try FileManager.default.createDirectory(
            atPath: home.string,
            withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            atPath: temporary.string,
            withIntermediateDirectories: true)
        var environment = validation.environment
        environment["HOME"] = home.string
        environment["TMPDIR"] = temporary.string
        environment["USER"] = environment["USER"] ?? "nucleus"
        environment["PATH"] =
            validation.toolchain.appending("bin").string
            + ":/usr/bin:/bin"
        environment["SWIFT_EXEC"] = validation.toolchain.appending(
            "bin/swiftc").string
        environment["SOURCEKIT_TOOLCHAIN_PATH"] =
            validation.toolchain.string
        let commandEnvironment = environment

        func checked(
            _ executable: String,
            _ arguments: [String],
            directory: FilePath? = nil,
            output: CommandSpec.Output = .logged
        ) async throws -> CommandResult {
            let result = try await execute(
                CommandSpec(
                    executable: .path(validation.toolchain.appending(
                        "bin/\(executable)")),
                    arguments: arguments,
                    workingDirectory:
                        directory ?? validation.workDirectory,
                    environment: commandEnvironment,
                    output: output),
                stage: stage)
            guard result.status == 0 else {
                throw RuntimeFailure.commandFailed(status: result.status)
            }
            return result
        }

        let clang = validation.toolchain.appending("bin/clang")
        let targetOutput = try await execute(
            CommandSpec(
                executable: .path(clang),
                arguments: ["--print-targets"],
                workingDirectory: validation.toolchain,
                environment: commandEnvironment,
                output: .captured(limit: 4 * 1_024 * 1_024)),
            stage: stage)
        guard targetOutput.status == 0 else {
            throw RuntimeFailure.commandFailed(
                status: targetOutput.status)
        }
        for target in targets
        where !targetOutput.standardOutput.split(separator: "\n").contains(
            where: {
                $0.trimmingCharacters(in: .whitespaces)
                    .hasPrefix(target + " ")
            })
        {
            throw RuntimeFailure.invalidOutput(
                "host Clang is missing LLVM target \(target)")
        }

        let smokeFixture =
            validation.workDirectory.appending("host-smoke")
        try ToolchainValidationFixtures.materialize(
            .hostSmoke,
            at: smokeFixture)
        let source = smokeFixture.appending("smoke.swift")
        let binary = validation.workDirectory.appending("smoke")
        let compile = try await execute(
            CommandSpec(
                executable: .path(
                    validation.toolchain.appending("bin/swiftc")),
                arguments: [
                    "-parse-as-library", source.string,
                    "-o", binary.string,
                ],
                workingDirectory: validation.workDirectory,
                environment: commandEnvironment),
            stage: stage)
        guard compile.status == 0 else {
            throw RuntimeFailure.commandFailed(status: compile.status)
        }
        let run = try await execute(
            CommandSpec(
                executable: .path(binary),
                arguments: [],
                workingDirectory: validation.workDirectory,
                environment: commandEnvironment),
            stage: stage)
        guard run.status == 0 else {
            throw RuntimeFailure.commandFailed(status: run.status)
        }
        for (executable, arguments) in [
            ("sourcekit-lsp", ["--help"]),
            ("swift-format", ["--version"]),
            ("docc", ["--help"]),
            ("wasmkit", ["--version"]),
        ] {
            let result = try await checked(
                executable,
                arguments,
                output: .combined(limit: 4 * 1_024 * 1_024))
            guard !result.standardOutput.isEmpty else {
                throw RuntimeFailure.invalidOutput(
                    "\(executable) produced no version/help output")
            }
        }

        let formatSource = validation.workDirectory.appending(
            "format/Unformatted.swift")
        try DurableFile.write(
            Data("struct Example{let value:Int}\n".utf8),
            to: formatSource)
        _ = try await checked(
            "swift-format",
            ["format", "--in-place", formatSource.string])
        let formatted = try String(
            contentsOfFile: formatSource.string,
            encoding: .utf8)
        guard formatted.contains("struct Example {"),
            formatted.contains("let value: Int")
        else {
            throw RuntimeFailure.invalidOutput(
                "swift-format did not format the validation source")
        }
        _ = try await checked(
            "swift-format",
            ["lint", "--strict", formatSource.string])

        let catalog = validation.workDirectory.appending(
            "docc/NucleusSmoke.docc")
        let archive = validation.workDirectory.appending(
            "docc/NucleusSmoke.doccarchive")
        try DurableFile.write(
            Data(
                (
                    "# Nucleus Smoke\n\n"
                        + "A functional Swift-DocC conversion test.\n"
                ).utf8),
            to: catalog.appending("NucleusSmoke.md"))
        _ = try await checked(
            "docc",
            [
                "convert", catalog.string,
                "--fallback-display-name", "Nucleus Smoke",
                "--fallback-bundle-identifier",
                "org.nucleustos.toolchain-smoke",
                "--fallback-bundle-version", "1",
                "--output-path", archive.string,
            ])
        guard hostIsRegularFile(archive.appending("index.html")),
            hostIsDirectory(archive.appending("data"))
        else {
            throw RuntimeFailure.invalidOutput(
                "DocC did not emit a valid documentation archive")
        }

        let wasm = validation.workDirectory.appending("wasmkit/empty.wasm")
        try DurableFile.write(
            Data([0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]),
            to: wasm)
        _ = try await checked("wasmkit", ["run", wasm.string])

        let cxxPackage = validation.workDirectory.appending(
            "cxx-interop-test-runner")
        try ToolchainValidationFixtures.materialize(
            .cxxInterop,
            at: cxxPackage)
        _ = try await checked(
            "swift",
            ["test", "--package-path", cxxPackage.string],
            directory: cxxPackage)

        let lspPackage = validation.workDirectory.appending(
            "sourcekit-lsp/NucleusLSPPackage")
        try ToolchainValidationFixtures.materialize(
            .sourceKitLSP,
            at: lspPackage)
        _ = try await checked(
            "swift",
            ["build", "--package-path", lspPackage.string],
            directory: lspPackage)
        let library = lspPackage.appending(
            "Sources/Greeter/Greeter.swift")
        let librarySource = try String(
            contentsOfFile: library.string,
            encoding: .utf8)
        let rootURI = URL(
            fileURLWithPath: lspPackage.string).absoluteString
        let libraryURI = URL(
            fileURLWithPath: library.string).absoluteString
        let lspInput = try ToolchainValidationFixtures.jsonRPCPayload([
            [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": [
                    "processId":
                        ProcessInfo.processInfo.processIdentifier,
                    "rootUri": rootURI,
                    "workspaceFolders": [
                        ["uri": rootURI, "name": "NucleusLSPPackage"],
                    ],
                    "capabilities": [
                        "textDocument": ["documentSymbol": [:]],
                    ],
                ],
            ],
            [
                "jsonrpc": "2.0",
                "method": "initialized",
                "params": [:],
            ],
            [
                "jsonrpc": "2.0",
                "method": "textDocument/didOpen",
                "params": [
                    "textDocument": [
                        "uri": libraryURI,
                        "languageId": "swift",
                        "version": 1,
                        "text": librarySource,
                    ],
                ],
            ],
            [
                "jsonrpc": "2.0",
                "id": 2,
                "method": "textDocument/documentSymbol",
                "params": [
                    "textDocument": ["uri": libraryURI],
                ],
            ],
            [
                "jsonrpc": "2.0",
                "id": 3,
                "method": "shutdown",
                "params": [:],
            ],
            [
                "jsonrpc": "2.0",
                "method": "exit",
                "params": [:],
            ],
        ])
        let lsp = try await execute(
            CommandSpec(
                executable: .path(validation.toolchain.appending(
                    "bin/sourcekit-lsp")),
                arguments: [],
                workingDirectory: lspPackage,
                environment: commandEnvironment,
                input: .bytes(lspInput),
                output: .captured(limit: 16 * 1_024 * 1_024),
                timeoutNanoseconds: 120_000_000_000),
            stage: stage)
        guard lsp.status == 0 else {
            throw RuntimeFailure.commandFailed(status: lsp.status)
        }
        let messages =
            try ToolchainValidationFixtures.jsonRPCMessages(
                lsp.standardOutput)
        guard messages.contains(where: {
            ($0["id"] as? Int) == 1 && $0["result"] != nil
        }),
            messages.contains(where: {
                ($0["id"] as? Int) == 2
                    && (($0["result"] as? [Any])?.isEmpty == false)
            })
        else {
            throw RuntimeFailure.invalidOutput(
                "SourceKit-LSP did not return initialize "
                    + "and document symbols")
        }
        try FileManager.default.removeItem(
            atPath: validation.workDirectory.string)
    }
}

private func hostIsDirectory(_ path: FilePath) -> Bool {
    var directory: ObjCBool = false
    return FileManager.default.fileExists(
        atPath: path.string,
        isDirectory: &directory) && directory.boolValue
}

private func hostIsRegularFile(_ path: FilePath) -> Bool {
    var directory: ObjCBool = false
    return FileManager.default.fileExists(
        atPath: path.string,
        isDirectory: &directory) && !directory.boolValue
}

private func hostRemoveExisting(_ path: FilePath) throws {
    if FileManager.default.fileExists(atPath: path.string)
        || (try? FileManager.default.destinationOfSymbolicLink(
            atPath: path.string)) != nil
    {
        try FileManager.default.removeItem(atPath: path.string)
    }
}

private func hostReplaceSymlink(
    _ target: String,
    at path: FilePath
) throws {
    try hostRemoveExisting(path)
    try FileManager.default.createDirectory(
        atPath: path.removingLastComponent().string,
        withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        atPath: path.string,
        withDestinationPath: target)
}

private func hostCopyReplacing(
    from source: FilePath,
    to destination: FilePath
) throws {
    try hostRemoveExisting(destination)
    try FileManager.default.createDirectory(
        atPath: destination.removingLastComponent().string,
        withIntermediateDirectories: true)
    try FileManager.default.copyItem(
        atPath: source.string,
        toPath: destination.string)
}
