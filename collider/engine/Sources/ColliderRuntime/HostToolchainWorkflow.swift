import ColliderCore
import Foundation
import Subprocess
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
        _ assembly: HostToolchainAssembly,
        stage: TaskID
    ) async throws {
        guard assembly.archive.isRegularFile else {
            throw RuntimeFailure.invalidOutput(
                "upstream Swift build did not produce \(assembly.archive)")
        }
        try hostRemoveExisting(assembly.toolchain)
        try FileManager.default.createDirectory(
            atPath: assembly.toolchain.removingLastComponent().string,
            withIntermediateDirectories: true)
        let extraction = try await execute(
            CommandSpec(
                executable: .named("tar"),
                arguments: [
                    "-xzf", assembly.archive.string,
                    "-C", assembly.toolchain.removingLastComponent().string,
                ],
                workingDirectory: assembly.workspace,
                environment: assembly.environment,
                output: .logged),
            stage: stage)
        guard extraction.status == 0, assembly.toolchain.isDirectory else {
            throw RuntimeFailure.commandFailed(status: extraction.status)
        }
        guard assembly.platform == .linux else { return }

        let library = assembly.toolchain.appending("lib")
        let cfxmlStatic = library.appending(
            "swift_static/linux/lib_CFXMLInterface.a")
        guard cfxmlStatic.isRegularFile else {
            throw RuntimeFailure.invalidOutput(
                "host FoundationXML support archive is missing: "
                    + "\(cfxmlStatic)")
        }
        try hostCopyReplacing(
            from: cfxmlStatic,
            to: library.appending("swift/linux/lib_CFXMLInterface.a"))
        let staticArguments = library.appending(
            "swift_static/linux/static-stdlib-args.lnk")
        guard staticArguments.isRegularFile else {
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
        if testingInterop.isRegularFile {
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
        guard archive.appending("index.html").isRegularFile,
            archive.appending("data").isDirectory
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
        let lspInitialize = try ToolchainValidationFixtures.jsonRPCPayload([
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
        ])
        let lspSymbols = try ToolchainValidationFixtures.jsonRPCPayload([
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
        ])
        let lspShutdown = try ToolchainValidationFixtures.jsonRPCPayload([
            [
                "jsonrpc": "2.0",
                "id": 3,
                "method": "shutdown",
                "params": [:],
            ],
        ])
        let lspExit = try ToolchainValidationFixtures.jsonRPCPayload([
            [
                "jsonrpc": "2.0",
                "method": "exit",
                "params": [:],
            ],
        ])
        let lsp = try await executeJSONRPCSession(
            CommandSpec(
                executable: .path(validation.toolchain.appending(
                    "bin/sourcekit-lsp")),
                arguments: [],
                workingDirectory: lspPackage,
                environment: commandEnvironment,
                output: .captured(limit: 16 * 1_024 * 1_024),
                timeoutNanoseconds: 120_000_000_000),
            exchanges: [
                (request: lspInitialize, responseID: 1),
                (request: lspSymbols, responseID: 2),
                (request: lspShutdown, responseID: 3),
            ],
            finalInput: lspExit,
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

private struct JSONRPCSessionOutput {
    let status: Int32
    let standardOutput: String
}

extension ColliderRuntime {
    private func executeJSONRPCSession(
        _ command: CommandSpec,
        exchanges: [(request: [UInt8], responseID: Int)],
        finalInput: [UInt8],
        stage: TaskID
    ) async throws -> JSONRPCSessionOutput {
        let executable: Subprocess.Executable = switch command.executable {
        case .named(let name): .name(name)
        case .path(let path), .taskOutput(let path): .path(path)
        }
        let environment = Subprocess.Environment.custom(
            Dictionary(
                uniqueKeysWithValues: command.environment.map {
                    (Subprocess.Environment.Key(rawValue: $0.key)!, $0.value)
                }))
        var platform = Subprocess.PlatformOptions()
        #if !os(Windows)
        platform.processGroupID = 0
        platform.teardownSequence = [
            .gracefulShutDown(
                toProcessGroup: true,
                allowedDurationToNextStep: .seconds(2))
        ]
        #endif
        let result = try await Subprocess.run(
            executable,
            arguments: Arguments(command.arguments),
            environment: environment,
            workingDirectory: command.workingDirectory,
            platformOptions: platform,
            input: CustomWriteInput.inputWriter,
            output: SequenceOutput.sequence,
            error: SequenceOutput.sequence
        ) { execution in
            let registration = await cancellation.registerProcessGroup(
                execution.processIdentifier.value)
            do {
                async let errorBytes = collectJSONRPCStream(
                    execution.standardError,
                    limit: 4 * 1_024 * 1_024)
                var outputBytes: [UInt8] = []
                var iterator = execution.standardOutput.makeAsyncIterator()
                for exchange in exchanges {
                    _ = try await execution.standardInputWriter.write(
                        exchange.request)
                    while !containsJSONRPCResponse(
                        outputBytes,
                        id: exchange.responseID)
                    {
                        guard let chunk = try await iterator.next() else {
                            throw RuntimeFailure.invalidOutput(
                                "SourceKit-LSP closed stdout before response "
                                    + "\(exchange.responseID)")
                        }
                        outputBytes += unsafe chunk.withUnsafeBytes {
                            unsafe Array($0)
                        }
                        guard outputBytes.count <= 16 * 1_024 * 1_024 else {
                            throw RuntimeFailure.outputLimitExceeded(
                                16 * 1_024 * 1_024)
                        }
                    }
                }
                _ = try await execution.standardInputWriter.write(finalInput)
                try await execution.standardInputWriter.finish()
                while let chunk = try await iterator.next() {
                    outputBytes += unsafe chunk.withUnsafeBytes {
                        unsafe Array($0)
                    }
                    guard outputBytes.count <= 16 * 1_024 * 1_024 else {
                        throw RuntimeFailure.outputLimitExceeded(
                            16 * 1_024 * 1_024)
                    }
                }
                let capturedError = try await errorBytes
                if !capturedError.isEmpty, let logging {
                    try await logging.registry.appendLog(
                        capturedError,
                        stage: stage,
                        in: logging.run)
                }
                await cancellation.unregisterProcessGroup(registration)
                return outputBytes
            } catch {
                await cancellation.unregisterProcessGroup(registration)
                throw error
            }
        }
        return JSONRPCSessionOutput(
            status: hostStatusCode(result.terminationStatus),
            standardOutput: String(
                decoding: result.closureResult,
                as: UTF8.self))
    }
}

private func containsJSONRPCResponse(
    _ bytes: [UInt8],
    id: Int
) -> Bool {
    let data = Data(bytes)
    let separator = Data("\r\n\r\n".utf8)
    var offset = data.startIndex
    while offset < data.endIndex {
        guard let headerRange = data.range(
            of: separator,
            in: offset..<data.endIndex),
            let header = String(
                data: data[offset..<headerRange.lowerBound],
                encoding: .utf8),
            let lengthLine = header.split(separator: "\r\n").first(
                where: {
                    $0.lowercased().hasPrefix("content-length:")
                }),
            let length = Int(
                lengthLine.split(separator: ":", maxSplits: 1)[1]
                    .trimmingCharacters(in: .whitespaces))
        else {
            return false
        }
        let bodyStart = headerRange.upperBound
        let bodyEnd = bodyStart + length
        guard bodyEnd <= data.endIndex else { return false }
        if let message = try? JSONSerialization.jsonObject(
            with: data[bodyStart..<bodyEnd]) as? [String: Any],
            (message["id"] as? Int) == id
        {
            return true
        }
        offset = bodyEnd
    }
    return false
}

private func collectJSONRPCStream(
    _ sequence: SubprocessOutputSequence,
    limit: Int
) async throws -> [UInt8] {
    var captured: [UInt8] = []
    for try await chunk in sequence {
        let bytes = unsafe chunk.withUnsafeBytes { unsafe Array($0) }
        guard captured.count <= limit,
            bytes.count <= limit - captured.count
        else {
            throw RuntimeFailure.outputLimitExceeded(limit)
        }
        captured += bytes
    }
    return captured
}

private func hostStatusCode(_ status: TerminationStatus) -> Int32 {
    switch status {
    case .exited(let code): code
    #if !os(Windows)
    case .signaled(let signal): 128 + signal
    #endif
    }
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
