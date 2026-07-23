import ColliderCore
import Foundation
import SystemPackage
import Testing
@testable import ColliderRuntime

@Test func taskEngineExplainsInvalidationAndThenSkipsCleanWork() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-engine-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appendingPathComponent("output")
    let command = CommandSpec(
        executable: .named("sh"),
        arguments: ["-c", "printf result > \"$1\"", "sh", output.path],
        workingDirectory: FilePath(directory.path),
        environment: ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"])
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.write"),
        component: ComponentID(rawValue: "fixture"),
        inputs: [.value(name: "content", bytes: Array("result".utf8))],
        outputs: [OutputDeclaration(path: FilePath(output.path), validation: .regularFile)],
        operation: .command(command))
    let graph = try TaskGraph([task])
    let runtime = ColliderRuntime()
    let state = FilePath(directory.appendingPathComponent("state").path)
    let first = try await runtime.execute(
        graph: graph, selected: [task.id], stateRoot: state)
    #expect(first.executed == [task.id])
    #expect(first.plan[0].explanation == "no prior task state")
    let second = try await runtime.execute(
        graph: graph, selected: [task.id], stateRoot: state)
    #expect(second.executed.isEmpty)
    #expect(second.plan[0].isClean)
}

@Test func taskIdentityIgnoresPerRunLoggingDestinations() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-engine-run-environment-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appendingPathComponent("output")
    let state = FilePath(directory.appendingPathComponent("state").path)
    let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"

    func task(runDirectory: String) -> TaskDeclaration {
        TaskDeclaration(
            id: TaskID(rawValue: "fixture.run-environment"),
            component: ComponentID(rawValue: "fixture"),
            outputs: [
                OutputDeclaration(
                    path: FilePath(output.path),
                    validation: .regularFile),
            ],
            operation: .command(CommandSpec(
                executable: .named("sh"),
                arguments: ["-c", "printf result > \"$1\"", "sh", output.path],
                workingDirectory: FilePath(directory.path),
                environment: [
                    "PATH": path,
                    "NUCLEUS_RUN_DIR": runDirectory,
                    "NUCLEUS_RUN_LOG": runDirectory + "/run.log",
                ])))
    }

    let runtime = ColliderRuntime()
    let first = task(runDirectory: "/runs/first")
    _ = try await runtime.execute(
        graph: TaskGraph([first]), selected: [first.id], stateRoot: state)
    let second = task(runDirectory: "/runs/second")
    let report = try await runtime.execute(
        graph: TaskGraph([second]), selected: [second.id], stateRoot: state)
    #expect(report.executed.isEmpty)
    #expect(report.plan[0].isClean)
}

@Test func outputContractChangesInvalidatePriorTaskState() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-engine-output-contract-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appendingPathComponent("output")
    let state = FilePath(directory.appendingPathComponent("state").path)
    let command = CommandSpec(
        executable: .named("sh"),
        arguments: ["-c", "printf result > \"$1\"", "sh", output.path],
        workingDirectory: FilePath(directory.path),
        environment: [
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        ])

    func task(validation: OutputDeclaration.Validation) -> TaskDeclaration {
        TaskDeclaration(
            id: TaskID(rawValue: "fixture.output-contract"),
            component: ComponentID(rawValue: "fixture"),
            outputs: [
                OutputDeclaration(
                    path: FilePath(output.path),
                    validation: validation),
            ],
            operation: .command(command))
    }

    let runtime = ColliderRuntime()
    let first = task(validation: .exists)
    _ = try await runtime.execute(
        graph: TaskGraph([first]), selected: [first.id], stateRoot: state)
    let changed = task(validation: .regularFile)
    let report = try await runtime.execute(
        graph: TaskGraph([changed]), selected: [changed.id], stateRoot: state)
    #expect(report.executed == [changed.id])
    #expect(report.plan[0].explanation == "input identity changed")
}

@Test func uncommittedSourceContentsInvalidatePriorTaskState() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-engine-source-content-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source")
    let output = directory.appendingPathComponent("output")
    try Data("first".utf8).write(to: source)
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.source-content"),
        component: ComponentID(rawValue: "fixture"),
        inputs: [.file(FilePath(source.path))],
        outputs: [
            OutputDeclaration(
                path: FilePath(output.path), validation: .regularFile),
        ],
        operation: .command(CommandSpec(
            executable: .named("sh"),
            arguments: [
                "-c", "cp \"$1\" \"$2\"", "sh", source.path, output.path,
            ],
            workingDirectory: FilePath(directory.path),
            environment: [
                "PATH": ProcessInfo.processInfo.environment["PATH"]
                    ?? "/usr/bin:/bin",
            ])))
    let runtime = ColliderRuntime()
    let graph = try TaskGraph([task])
    let state = FilePath(directory.appendingPathComponent("state").path)
    _ = try await runtime.execute(
        graph: graph, selected: [task.id], stateRoot: state)
    try Data("second".utf8).write(to: source)

    let report = try await runtime.execute(
        graph: graph, selected: [task.id], stateRoot: state)
    #expect(report.executed == [task.id])
    #expect(report.plan[0].explanation == "input identity changed")
    #expect(try String(contentsOf: output, encoding: .utf8) == "second")
}

@Test func taskSequenceOwnsOrderedFilesystemMutation() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-engine-sequence-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let candidate = FilePath(directory.appendingPathComponent("candidate").path)
    try FileManager.default.createDirectory(
        atPath: candidate.string, withIntermediateDirectories: true)
    try Data("stale".utf8).write(
        to: URL(fileURLWithPath: candidate.appending("stale").string))
    let payload = candidate.appending("payload")
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.sequence"),
        component: ComponentID(rawValue: "fixture"),
        outputs: [
            OutputDeclaration(path: payload, validation: .regularFile),
        ],
        operation: .sequence([
            .removePath(candidate),
            .createDirectory(candidate),
            .writeFile(payload, bytes: Array("fresh".utf8)),
        ]))

    let report = try await ColliderRuntime().execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: FilePath(directory.appendingPathComponent("state").path))
    #expect(report.executed == [task.id])
    #expect(!FileManager.default.fileExists(
        atPath: candidate.appending("stale").string))
    #expect(try String(
        contentsOf: URL(fileURLWithPath: payload.string),
        encoding: .utf8) == "fresh")
}

@Test func staticArchiveMergeDiscoversPostBuildArchivesWithoutShellSyntax() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-archive-merge-\(UUID().uuidString)")
    let build = directory.appendingPathComponent("build")
    try FileManager.default.createDirectory(
        at: build, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let environment = [
        "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
    ]
    let runtime = ColliderRuntime()
    for name in ["one", "two", "gtest-fixture"] {
        let member = build.appendingPathComponent("\(name).member")
        try Data(name.utf8).write(to: member)
        let result = try await runtime.execute(CommandSpec(
            executable: .named("ar"),
            arguments: [
                "rcs",
                build.appendingPathComponent("lib\(name).a").path,
                member.path,
            ],
            workingDirectory: FilePath(build.path),
            environment: environment))
        #expect(result.status == 0)
    }
    let combined = FilePath(
        build.appendingPathComponent("libcombined.a").path)
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.archive-merge"),
        component: ComponentID(rawValue: "fixture"),
        outputs: [
            OutputDeclaration(path: combined, validation: .regularFile),
        ],
        operation: .mergeStaticArchives(StaticArchiveMerge(
            sourceRoot: FilePath(build.path),
            output: combined,
            excludedFilePrefixes: ["libgtest"],
            environment: environment)))
    _ = try await runtime.execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: FilePath(directory.appendingPathComponent("state").path))
    let table = try await runtime.execute(CommandSpec(
        executable: .named("ar"),
        arguments: ["t", combined.string],
        workingDirectory: FilePath(build.path),
        environment: environment,
        output: .captured(limit: 1_024)))
    #expect(table.standardOutput.contains("one.member"))
    #expect(table.standardOutput.contains("two.member"))
    #expect(!table.standardOutput.contains("gtest-fixture.member"))
}

@Test func androidSDKWiringBuildsRelocatableRuntimeLinksFromTheSelectedNDK() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-android-sdk-wiring-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let bundle = directory.appendingPathComponent("swift-android.artifactbundle")
    let variant = bundle.appendingPathComponent("swift-android")
    let resourceLibrary = variant.appendingPathComponent(
        "swift-resources/usr/lib")
    let dynamicRuntime = resourceLibrary.appendingPathComponent(
        "swift-aarch64/android/aarch64/swiftrt.o")
    let staticRuntime = resourceLibrary.appendingPathComponent(
        "swift_static-aarch64/android/aarch64/swiftrt.o")
    for runtime in [dynamicRuntime, staticRuntime] {
        try FileManager.default.createDirectory(
            at: runtime.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("runtime".utf8).write(to: runtime)
    }
    let legacyToolchain = variant.appendingPathComponent("ndk-toolchain")
    try FileManager.default.createDirectory(
        at: legacyToolchain, withIntermediateDirectories: true)

    let ndk = directory.appendingPathComponent("ndk")
    try FileManager.default.createDirectory(
        at: ndk, withIntermediateDirectories: true)
    try Data("Pkg.Revision = 30.0.14904198\n".utf8).write(
        to: ndk.appendingPathComponent("source.properties"),
        options: .atomic)
    let prebuilt = ndk.appendingPathComponent(
        "toolchains/llvm/prebuilt/linux-x86_64")
    for child in [
        "sysroot/usr/include",
        "sysroot/usr/lib/aarch64-linux-android",
        "lib/clang/19/include",
    ] {
        try FileManager.default.createDirectory(
            at: prebuilt.appendingPathComponent(child),
            withIntermediateDirectories: true)
    }

    let sysroot = variant.appendingPathComponent("ndk-sysroot")
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.wire-android-sdk"),
        component: ComponentID(rawValue: "fixture"),
        outputs: [
            OutputDeclaration(
                path: FilePath(sysroot.appendingPathComponent("usr/include").path),
                validation: .exists),
        ],
        operation: .wireAndroidSDK(AndroidSDKWiring(
            bundle: FilePath(bundle.path),
            ndk: FilePath(ndk.path))))
    _ = try await ColliderRuntime().execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: FilePath(directory.appendingPathComponent("state").path))

    #expect(!FileManager.default.fileExists(atPath: legacyToolchain.path))
    #expect(try FileManager.default.destinationOfSymbolicLink(
        atPath: sysroot.appendingPathComponent("usr/include").path)
        == prebuilt.appendingPathComponent("sysroot/usr/include").path)
    #expect(try FileManager.default.destinationOfSymbolicLink(
        atPath: resourceLibrary.appendingPathComponent("swift/clang").path)
        == prebuilt.appendingPathComponent("lib/clang/19").path)
    let wiredRuntime = sysroot.appendingPathComponent(
        "usr/lib/swift/android/aarch64/swiftrt.o")
    let runtimeTarget = try FileManager.default.destinationOfSymbolicLink(
        atPath: wiredRuntime.path)
    #expect(!runtimeTarget.hasPrefix("/"))
    #expect(
        wiredRuntime.deletingLastPathComponent()
            .appendingPathComponent(runtimeTarget)
            .standardizedFileURL == dynamicRuntime.standardizedFileURL)
}

@Test func androidSDKAssemblyBuildsARelocatableStaticAndDynamicBundle() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-android-sdk-assembly-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let toolchain = directory.appendingPathComponent("toolchain")
    let installs = directory.appendingPathComponent("build")
    let installUSR = installs.appendingPathComponent("install-aarch64/usr")
    let dynamic = installUSR.appendingPathComponent("lib/swift/android")
    let staticRuntime = installUSR.appendingPathComponent(
        "lib/swift_static/android")

    func write(_ contents: String, _ path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: path)
    }

    try write("header", toolchain.appendingPathComponent(
        "include/swift/bridging.modulemap"))
    try write("module Swift {}", toolchain.appendingPathComponent(
        "include/module.modulemap"))
    try write("include", installUSR.appendingPathComponent("include/fixture.h"))
    try write("archive", installUSR.appendingPathComponent("lib/libfixture.a"))
    try write("cxx", dynamic.appendingPathComponent("libswiftCxx.a"))
    try write("cxx stdlib", dynamic.appendingPathComponent(
        "libswiftCxxStdlib.a"))
    try write("core", dynamic.appendingPathComponent("libswiftCore.so"))
    try write("cfxml", staticRuntime.appendingPathComponent(
        "lib_CFXMLInterface.a"))
    try write("-lswiftCore", staticRuntime.appendingPathComponent(
        "static-stdlib-args.lnk"))
    try write(
        "prefix=/absolute\nexec_prefix=/absolute\nlibdir=/absolute\n"
            + "includedir=/absolute\n",
        installUSR.appendingPathComponent("lib/pkgconfig/fixture.pc"))
    try write(
        "set(PATH \"\(installUSR.path)/lib\")\n",
        installUSR.appendingPathComponent("lib/cmake/fixture.cmake"))

    let bundle = directory.appendingPathComponent(
        "swift-test_android.artifactbundle")
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.assemble-android-sdk"),
        component: ComponentID(rawValue: "fixture"),
        outputs: [
            OutputDeclaration(
                path: FilePath(bundle.path),
                validation: .nonEmptyDirectory),
        ],
        operation: .assembleAndroidSDK(AndroidSDKAssembly(
            toolchain: FilePath(toolchain.path),
            installRoot: FilePath(installs.path),
            bundle: FilePath(bundle.path),
            sourceID: "test",
            architectures: ["aarch64"],
            apiLevel: 36)))
    _ = try await ColliderRuntime().execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: FilePath(directory.appendingPathComponent("state").path))

    let resources = bundle.appendingPathComponent(
        "swift-android/swift-resources/usr")
    let staticAndroid = resources.appendingPathComponent(
        "lib/swift_static-aarch64/android")
    #expect(FileManager.default.fileExists(
        atPath: resources.appendingPathComponent(
            "lib/swift-aarch64/android/lib_CFXMLInterface.a").path))
    #expect(FileManager.default.fileExists(
        atPath: staticAndroid.appendingPathComponent("libswiftCxx.a").path))
    #expect(FileManager.default.fileExists(
        atPath: staticAndroid.appendingPathComponent("libfixture.a").path))
    let staticArguments = try String(
        contentsOf: staticAndroid.appendingPathComponent(
            "static-stdlib-args.lnk"),
        encoding: .utf8)
    #expect(staticArguments.contains("-l_CFXMLInterface"))
    #expect(staticArguments.contains("-lxml2"))
    let pkgconfig = try String(
        contentsOf: resources.appendingPathComponent(
            "lib/pkgconfig/fixture.pc"),
        encoding: .utf8)
    #expect(pkgconfig.contains("prefix=${pcfiledir}/../.."))
    #expect(!pkgconfig.contains("/absolute"))
    let cmake = try String(
        contentsOf: resources.appendingPathComponent(
            "lib/cmake/fixture.cmake"),
        encoding: .utf8)
    #expect(cmake.contains("${_IMPORT_PREFIX}/lib"))
    #expect(!cmake.contains(installUSR.path))
    let sdk = try JSONSerialization.jsonObject(
        with: Data(contentsOf: bundle.appendingPathComponent(
            "swift-android/swift-sdk.json"))) as? [String: Any]
    let triples = sdk?["targetTriples"] as? [String: Any]
    #expect(triples?["aarch64-unknown-linux-android36"] != nil)
}

@Test func hostToolchainPreparationAndAssemblyPreserveTheRelocatableRuntime() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-host-toolchain-assembly-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let workspace = directory.appendingPathComponent("source")
    let staging = workspace.appendingPathComponent(
        ".nucleus-candidate-install")
    let toolchain = directory.appendingPathComponent("generation/usr")
    let state = FilePath(directory.appendingPathComponent("state").path)
    let preparation = TaskDeclaration(
        id: TaskID(rawValue: "fixture.prepare-host-toolchain"),
        component: ComponentID(rawValue: "fixture"),
        outputs: [
            OutputDeclaration(
                path: FilePath(staging.appendingPathComponent(
                    ".nucleus-owned").path),
                validation: .regularFile),
        ],
        cachePolicy: .always,
        operation: .prepareHostToolchainBuild(
            HostToolchainBuildPreparation(
                workspace: FilePath(workspace.path),
                stagingRoot: FilePath(staging.path),
                platform: .linux)))
    _ = try await ColliderRuntime().execute(
        graph: TaskGraph([preparation]),
        selected: [preparation.id],
        stateRoot: state)
    #expect(try FileManager.default.destinationOfSymbolicLink(
        atPath: staging.appendingPathComponent(
            "usr/lib/swift/linux/libc++.so.1").path) == "../../libc++.so.1")
    #expect(try String(
        contentsOf: staging.appendingPathComponent("usr/bin/clang.cfg"),
        encoding: .utf8).contains("-L<CFGDIR>/../lib"))

    func write(_ contents: String, _ path: URL, executable: Bool = false) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: path)
        if executable {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: path.path)
        }
    }
    try write(
        "#!/bin/sh\n",
        staging.appendingPathComponent("usr/bin/swift"),
        executable: true)
    try write(
        "cfxml",
        staging.appendingPathComponent(
            "usr/lib/swift_static/linux/lib_CFXMLInterface.a"))
    try write(
        "-lswiftCore",
        staging.appendingPathComponent(
            "usr/lib/swift_static/linux/static-stdlib-args.lnk"))
    let assembly = TaskDeclaration(
        id: TaskID(rawValue: "fixture.assemble-host-toolchain"),
        component: ComponentID(rawValue: "fixture"),
        outputs: [
            OutputDeclaration(
                path: FilePath(toolchain.appendingPathComponent(
                    "bin/swift").path),
                validation: .executableFile),
        ],
        cachePolicy: .always,
        operation: .assembleHostToolchain(HostToolchainAssembly(
            workspace: FilePath(workspace.path),
            stagingRoot: FilePath(staging.path),
            toolchain: FilePath(toolchain.path),
            platform: .linux)))
    _ = try await ColliderRuntime().execute(
        graph: TaskGraph([assembly]),
        selected: [assembly.id],
        stateRoot: state)
    #expect(FileManager.default.fileExists(
        atPath: toolchain.appendingPathComponent(
            "lib/swift/linux/lib_CFXMLInterface.a").path))
    let staticArguments = try String(
        contentsOf: toolchain.appendingPathComponent(
            "lib/swift_static/linux/static-stdlib-args.lnk"),
        encoding: .utf8)
    #expect(staticArguments.contains("-lswift_StringProcessing"))
    #expect(staticArguments.contains("-l_CFXMLInterface"))
    #expect(staticArguments.contains("-lxml2"))
}

@Test func androidRuntimeLinkageValidationRequiresLibcxxWithoutLibstdcxxABI() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-android-runtime-linkage-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let installRoot = directory.appendingPathComponent("build")
    let core = installRoot.appendingPathComponent(
        "install-aarch64/usr/lib/swift/android/libswiftCore.so")
    try FileManager.default.createDirectory(
        at: core.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    try Data("ELF".utf8).write(to: core)
    let tools = directory.appendingPathComponent(
        "ndk/toolchains/llvm/prebuilt/linux-x86_64/bin")
    try FileManager.default.createDirectory(
        at: tools, withIntermediateDirectories: true)
    for (name, source) in [
        (
            "llvm-readelf",
            "#!/bin/sh\nprintf 'Shared library: [libc++_shared.so]\\n'\n"
        ),
        (
            "llvm-nm",
            "#!/bin/sh\nprintf '0000 T swift_runtime_symbol\\n'\n"
        ),
    ] {
        let executable = tools.appendingPathComponent(name)
        try Data(source.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path)
    }
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.validate-android-runtime-linkage"),
        component: ComponentID(rawValue: "fixture"),
        cachePolicy: .always,
        operation: .validateAndroidRuntimeLinkage(
            AndroidRuntimeLinkageValidation(
                installRoot: FilePath(installRoot.path),
                ndk: FilePath(
                    directory.appendingPathComponent("ndk").path),
                architectures: ["aarch64"],
                environment: [
                    "PATH": ProcessInfo.processInfo.environment["PATH"]
                        ?? "/usr/bin:/bin",
                ])))
    let report = try await ColliderRuntime().execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: FilePath(directory.appendingPathComponent("state").path))
    #expect(report.executed == [task.id])
}

@Test func androidSDKValidationBuildsDynamicAndStaticConsumersWithoutAShellAdapter() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-android-sdk-validation-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let toolchain = directory.appendingPathComponent("toolchain")
    let swift = toolchain.appendingPathComponent("bin/swift")
    try FileManager.default.createDirectory(
        at: swift.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    try Data(
        """
        #!/bin/sh
        build=
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--build-path" ]; then
            build="$2"
            shift 2
          else
            shift
          fi
        done
        mkdir -p "$build/products"
        printf '#!/bin/sh\\n' > "$build/products/hello"
        printf '#!/bin/sh\\n' > "$build/products/FoundationXMLHostPlugin"
        chmod 755 "$build/products/hello" "$build/products/FoundationXMLHostPlugin"
        """.utf8
    ).write(to: swift)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: swift.path)

    let ndk = directory.appendingPathComponent("ndk")
    let readelf = ndk.appendingPathComponent(
        "toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf")
    try FileManager.default.createDirectory(
        at: readelf.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    try Data(
        "#!/bin/sh\nprintf '  Machine: AArch64\\n'\n".utf8
    ).write(to: readelf)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: readelf.path)

    let sdkRoot = directory.appendingPathComponent("sdks")
    let bundleName = "swift-test_android.artifactbundle"
    try FileManager.default.createDirectory(
        at: sdkRoot.appendingPathComponent(bundleName),
        withIntermediateDirectories: true)
    let work = directory.appendingPathComponent("validation-work")
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.validate-android-sdk"),
        component: ComponentID(rawValue: "fixture"),
        cachePolicy: .always,
        operation: .validateAndroidSDK(AndroidSDKValidation(
            toolchain: FilePath(toolchain.path),
            sdkSearchRoot: FilePath(sdkRoot.path),
            bundleName: bundleName,
            ndk: FilePath(ndk.path),
            architecture: "aarch64",
            apiLevel: 36,
            workDirectory: FilePath(work.path),
            environment: [
                "PATH": ProcessInfo.processInfo.environment["PATH"]
                    ?? "/usr/bin:/bin",
            ])))
    let report = try await ColliderRuntime().execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: FilePath(directory.appendingPathComponent("state").path))
    #expect(report.executed == [task.id])
    #expect(!FileManager.default.fileExists(atPath: work.path))
}

@Test func androidHostValidationChecksELFAndKotlinJNIContracts() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-android-host-validation-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
    let library = directory.appendingPathComponent("libnucleus-android.so")
    try Data("fixture".utf8).write(to: library)
    let kotlin = directory.appendingPathComponent("NucleusNative.kt")
    try Data(
        "object NucleusNative { external fun frame() }\n".utf8
    ).write(to: kotlin)
    let readelf = directory.appendingPathComponent(
        "ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf")
    try FileManager.default.createDirectory(
        at: readelf.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    let thunks = (0..<20).map {
        "1: 0 FUNC GLOBAL DEFAULT 1 "
            + "Java_dev_nucleus_android_AndroidHost__thunk\($0)"
    }.joined(separator: "\\n")
    try Data(
        """
        #!/bin/sh
        case "$1" in
          -h) printf '  Machine: AArch64\\n' ;;
          -d) printf 'NEEDED [libandroid.so]\\nNEEDED [libvulkan.so]\\nNEEDED [libSwiftJava.so]\\n' ;;
          -Ws) printf '  FUNC GLOBAL DEFAULT JNI_OnLoad\\n  FUNC LOCAL PROTECTED 1 swift_retain\\n  FUNC GLOBAL DEFAULT Java_dev_nucleus_android_NucleusNative_frame\\n\(thunks)\\n' ;;
        esac
        """.utf8
    ).write(to: readelf)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: readelf.path)
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.validate-android-host"),
        component: ComponentID(rawValue: "fixture"),
        cachePolicy: .always,
        operation: .validateAndroidHost(AndroidHostValidation(
            library: FilePath(library.path),
            kotlinContract: FilePath(kotlin.path),
            ndk: FilePath(directory.appendingPathComponent("ndk").path),
            environment: [
                "PATH": ProcessInfo.processInfo.environment["PATH"]
                    ?? "/usr/bin:/bin",
            ])))
    let report = try await ColliderRuntime().execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: FilePath(directory.appendingPathComponent("state").path))
    #expect(report.executed == [task.id])
}

@Test func linkMetadataSanitizationRemovesForbiddenAndroidHostFlags() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-link-metadata-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let metadata = directory.appendingPathComponent(
        "usr/lib/pkgconfig/fixture.pc")
    try FileManager.default.createDirectory(
        at: metadata.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    try Data(
        "Libs: -lfixture $<LINK_ONLY:-pthread> -pthread\n".utf8
    ).write(to: metadata)
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.sanitize-link-metadata"),
        component: ComponentID(rawValue: "fixture"),
        outputs: [
            OutputDeclaration(
                path: FilePath(metadata.path),
                validation: .regularFile),
        ],
        operation: .sanitizeLinkMetadata(LinkMetadataSanitization(
            root: FilePath(directory.path),
            removedLinkerOptions: ["-pthread"])))
    _ = try await ColliderRuntime().execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: FilePath(directory.appendingPathComponent("state").path))
    let contents = try String(contentsOf: metadata, encoding: .utf8)
    #expect(contents.contains("-lfixture"))
    #expect(!contents.contains("-pthread"))
    #expect(!contents.contains("LINK_ONLY"))
}

@Test func symlinkPublicationPreservesADisplacedMutableInstallation() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-symlink-publication-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let link = directory.appendingPathComponent("active")
    let displaced = directory.appendingPathComponent("legacy-active")
    try FileManager.default.createDirectory(
        at: link, withIntermediateDirectories: true)
    try Data("legacy".utf8).write(
        to: link.appendingPathComponent("payload"))
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.publish-symlink"),
        component: ComponentID(rawValue: "fixture"),
        outputs: [
            OutputDeclaration(
                path: FilePath(link.path),
                validation: .exists),
        ],
        operation: .publishSymlink(SymlinkPublication(
            path: FilePath(link.path),
            target: "/immutable/generation",
            displacedItem: FilePath(displaced.path))))
    _ = try await ColliderRuntime().execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: FilePath(directory.appendingPathComponent("state").path))
    #expect(try FileManager.default.destinationOfSymbolicLink(
        atPath: link.path) == "/immutable/generation")
    #expect(try String(
        contentsOf: displaced.appendingPathComponent("payload"),
        encoding: .utf8) == "legacy")
}

@Test func directoryPublicationAtomicallyReplacesThePreviousGeneration() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-directory-publication-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let prepared = directory.appendingPathComponent("prepared")
    let destination = directory.appendingPathComponent("destination")
    for path in [prepared, destination] {
        try FileManager.default.createDirectory(
            at: path, withIntermediateDirectories: true)
    }
    try Data("new".utf8).write(
        to: prepared.appendingPathComponent("payload"))
    try Data("old".utf8).write(
        to: destination.appendingPathComponent("payload"))
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.publish-directory"),
        component: ComponentID(rawValue: "fixture"),
        outputs: [
            OutputDeclaration(
                path: FilePath(destination.path),
                validation: .nonEmptyDirectory),
        ],
        cachePolicy: .always,
        operation: .publishDirectory(DirectoryPublication(
            prepared: FilePath(prepared.path),
            destination: FilePath(destination.path))))
    _ = try await ColliderRuntime().execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: FilePath(directory.appendingPathComponent("state").path))
    #expect(try String(
        contentsOf: destination.appendingPathComponent("payload"),
        encoding: .utf8) == "new")
    #expect(!FileManager.default.fileExists(atPath: prepared.path))
}

@Test func directoryRetentionKeepsNewestAndCurrentContentIdentities() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-directory-retention-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let generations = directory.appendingPathComponent("generations")
    try FileManager.default.createDirectory(
        at: generations, withIntermediateDirectories: true)
    let names = [
        "111111111111111111111111",
        "222222222222222222222222",
        "333333333333333333333333",
    ]
    for (index, name) in names.enumerated() {
        let path = generations.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: path, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: Double(index))],
            ofItemAtPath: path.path)
    }
    let current = directory.appendingPathComponent("current")
    try FileManager.default.createSymbolicLink(
        atPath: current.path,
        withDestinationPath: "generations/\(names[0])")
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.prune-directories"),
        component: ComponentID(rawValue: "fixture"),
        cachePolicy: .always,
        operation: .pruneDirectories(DirectoryRetentionPlan(
            safetyRoot: FilePath(directory.path),
            rules: [
                DirectoryRetentionRule(
                    root: FilePath(generations.path),
                    current: FilePath(current.path),
                    retain: 1,
                    naming: .contentIdentity),
            ])))
    _ = try await ColliderRuntime().execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: FilePath(directory.appendingPathComponent("state").path))
    #expect(FileManager.default.fileExists(
        atPath: generations.appendingPathComponent(names[0]).path))
    #expect(!FileManager.default.fileExists(
        atPath: generations.appendingPathComponent(names[1]).path))
    #expect(FileManager.default.fileExists(
        atPath: generations.appendingPathComponent(names[2]).path))
}

@Test func chromiumSourcePreparationValidatesAndActivatesAnImmutableGeneration() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-chromium-source-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let generations = directory.appendingPathComponent("generations")
    let sourceID = "1234567890abcdef12345678"
    let source = generations.appendingPathComponent(sourceID)
    let chromium = source.appendingPathComponent("chromium/src")
    let cef = chromium.appendingPathComponent("cef")
    let dawn = chromium.appendingPathComponent("third_party/dawn")
    let depot = directory.appendingPathComponent("depot_tools")
    let environment = [
        "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        "GIT_AUTHOR_NAME": "Collider Test",
        "GIT_AUTHOR_EMAIL": "collider@example.invalid",
        "GIT_COMMITTER_NAME": "Collider Test",
        "GIT_COMMITTER_EMAIL": "collider@example.invalid",
    ]
    let runtime = ColliderRuntime()
    func git(_ repository: URL) async throws -> String {
        try FileManager.default.createDirectory(
            at: repository, withIntermediateDirectories: true)
        let marker = repository.appendingPathComponent("marker")
        try Data("source".utf8).write(to: marker)
        for arguments in [
            ["init", "-q"],
            ["add", "marker"],
            ["commit", "-qm", "fixture"],
        ] {
            let result = try await runtime.execute(CommandSpec(
                executable: .named("git"),
                arguments: arguments,
                workingDirectory: FilePath(repository.path),
                environment: environment))
            #expect(result.status == 0)
        }
        let result = try await runtime.execute(CommandSpec(
            executable: .named("git"),
            arguments: ["rev-parse", "HEAD"],
            workingDirectory: FilePath(repository.path),
            environment: environment,
            output: .captured(limit: 4_096)))
        #expect(result.status == 0)
        return result.standardOutput.trimmingCharacters(
            in: .whitespacesAndNewlines)
    }
    let chromiumRevision = try await git(chromium)
    let cefRevision = try await git(cef)
    let dawnRevision = try await git(dawn)
    let depotRevision = try await git(depot)
    let automate = directory.appendingPathComponent("automate-git.py")
    try Data("automation".utf8).write(to: automate)
    let manifest: [String: Any] = [
        "schema": 1,
        "sourceID": sourceID,
        "cefBranch": "fixture",
        "cefCheckout": cefRevision,
        "chromiumCheckout": chromiumRevision,
        "depotToolsRevision": depotRevision,
        "revisions": [
            "chromium": chromiumRevision,
            "cef": cefRevision,
            "dawn": dawnRevision,
            "depot_tools": depotRevision,
        ],
        "automateGitSHA256": try ArtifactHasher.digest(
            file: FilePath(automate.path)).description,
    ]
    try JSONSerialization.data(
        withJSONObject: manifest,
        options: [.sortedKeys]).write(
            to: source.appendingPathComponent(
                "nucleus-source-manifest.json"))
    let current = generations.appendingPathComponent("current")
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.prepare-chromium-source"),
        component: ComponentID(rawValue: "fixture"),
        outputs: [
            OutputDeclaration(
                path: FilePath(source.appendingPathComponent(
                    "nucleus-source-manifest.json").path),
                validation: .json),
        ],
        cachePolicy: .always,
        operation: .prepareChromiumSource(ChromiumSourcePreparation(
            workspace: FilePath(directory.path),
            sourceID: sourceID,
            sourceRoot: FilePath(source.path),
            sourceGenerations: FilePath(generations.path),
            current: FilePath(current.path),
            depotTools: FilePath(depot.path),
            automateScript: FilePath(automate.path),
            cefBranch: "fixture",
            cefCheckout: cefRevision,
            chromiumCheckout: chromiumRevision,
            depotToolsRevision: depotRevision,
            patchStacks: [],
            environment: environment)))
    _ = try await runtime.execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: FilePath(directory.appendingPathComponent("state").path))
    #expect(try FileManager.default.destinationOfSymbolicLink(
        atPath: current.path) == sourceID)
}

@Test func chromiumProductBuildOwnsGNMetadataAndAutoninjaExecution() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-chromium-product-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source")
    let chromium = source.appendingPathComponent("chromium/src")
    let output = chromium.appendingPathComponent("out/Browser")
    let depot = directory.appendingPathComponent("depot_tools")
    let gn = chromium.appendingPathComponent("buildtools/linux64/gn")
    let clang = chromium.appendingPathComponent(
        "third_party/llvm-build/Release+Asserts/bin/clang")
    let autoninja = depot.appendingPathComponent("autoninja")
    for executable in [gn, clang, autoninja] {
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true)
    }
    try FileManager.default.createDirectory(
        at: source, withIntermediateDirectories: true)
    try JSONSerialization.data(
        withJSONObject: ["sourceID": "source-fixture"],
        options: [.sortedKeys]).write(
            to: source.appendingPathComponent(
                "nucleus-source-manifest.json"))
    try Data(
        """
        #!/bin/sh
        mkdir -p "$2"
        printf 'is_official_build=true\\ntarget_cpu="x64"\\n' > "$2/args.gn"
        """.utf8
    ).write(to: gn)
    try Data(
        "#!/bin/sh\nprintf 'clang fixture 1.0\\n'\n".utf8
    ).write(to: clang)
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: autoninja)
    for executable in [gn, clang, autoninja] {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path)
    }
    let built = output.appendingPathComponent(
        ".nucleus-built-build.json")
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.build-chromium-product"),
        component: ComponentID(rawValue: "fixture"),
        outputs: [
            OutputDeclaration(
                path: FilePath(built.path),
                validation: .json),
        ],
        cachePolicy: .always,
        operation: .buildChromiumProduct(ChromiumProductBuild(
            product: .browser,
            sourceRoot: FilePath(source.path),
            output: FilePath(output.path),
            depotTools: FilePath(depot.path),
            gnArguments: #"is_official_build=true target_cpu="x64""#,
            targets: ["chrome", "chrome_sandbox"],
            jobs: 2,
            environment: [
                "PATH": ProcessInfo.processInfo.environment["PATH"]
                    ?? "/usr/bin:/bin",
            ])))
    _ = try await ColliderRuntime().execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: FilePath(directory.appendingPathComponent("state").path))
    let object = try JSONSerialization.jsonObject(
        with: Data(contentsOf: built)) as? [String: Any]
    #expect((object?["buildID"] as? String)?.count == 24)
}

@Test func browserArtifactAssemblyPublishesAValidatedImmutableGeneration() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-browser-artifact-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("chromium")
    let output = directory.appendingPathComponent("out")
    let distribution = directory.appendingPathComponent("dist")
    try FileManager.default.createDirectory(
        at: output.appendingPathComponent("locales"),
        withIntermediateDirectories: true)
    let required = [
        "chrome", "chrome_crashpad_handler", "chrome_sandbox",
        "icudtl.dat", "resources.pak", "chrome_100_percent.pak",
        "chrome_200_percent.pak", "v8_context_snapshot.bin",
        "libEGL.so", "libGLESv2.so", "libvulkan.so.1",
    ]
    for name in required {
        try Data(name.utf8).write(
            to: output.appendingPathComponent(name))
    }
    try Data("locale".utf8).write(
        to: output.appendingPathComponent("locales/en-US.pak"))
    let icon = source.appendingPathComponent(
        "chrome/app/theme/chromium/linux/product_logo_128.png")
    try FileManager.default.createDirectory(
        at: icon.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    try Data("icon".utf8).write(to: icon)
    let launcher = directory.appendingPathComponent("nucleus-browser")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: launcher)
    let desktop = directory.appendingPathComponent("browser.desktop.in")
    try Data(
        "Exec=@NUCLEUS_BROWSER_LAUNCHER@\n".utf8
    ).write(to: desktop)
    let buildID = "abcdefabcdefabcdefabcdef"
    try JSONSerialization.data(
        withJSONObject: ["buildID": buildID],
        options: [.sortedKeys]).write(
            to: output.appendingPathComponent(
                ".nucleus-built-build.json"))
    let tools = directory.appendingPathComponent("tools")
    try FileManager.default.createDirectory(
        at: tools, withIntermediateDirectories: true)
    let ldd = tools.appendingPathComponent("ldd")
    try Data("#!/bin/sh\nprintf 'all resolved\\n'\n".utf8).write(to: ldd)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: ldd.path)
    let assembly = BrowserArtifactAssembly(
        chromiumSource: FilePath(source.path),
        buildOutput: FilePath(output.path),
        distributionRoot: FilePath(distribution.path),
        launcher: FilePath(launcher.path),
        desktopTemplate: FilePath(desktop.path),
        environment: [
            "PATH": tools.path + ":"
                + (ProcessInfo.processInfo.environment["PATH"]
                    ?? "/usr/bin:/bin"),
        ])
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.assemble-browser-artifact"),
        component: ComponentID(rawValue: "fixture"),
        outputs: [
            OutputDeclaration(
                path: FilePath(distribution.appendingPathComponent(
                    "current").path),
                validation: .exists),
        ],
        cachePolicy: .always,
        operation: .sequence([
            .assembleBrowserArtifact(assembly),
            .validateBrowserArtifact(assembly),
        ]))
    _ = try await ColliderRuntime().execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: FilePath(directory.appendingPathComponent("state").path))
    #expect(try FileManager.default.destinationOfSymbolicLink(
        atPath: distribution.appendingPathComponent("current").path)
        == "generations/\(buildID)")
}

@Test func aptPackageValidationReportsTheUserOwnedInstallCommand() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-apt-validation-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let tools = directory.appendingPathComponent("tools")
    try FileManager.default.createDirectory(
        at: tools, withIntermediateDirectories: true)
    let query = tools.appendingPathComponent("dpkg-query")
    try Data(
        """
        #!/bin/sh
        case "$3" in
          installed) printf 'ii ' ;;
          *) exit 1 ;;
        esac
        """.utf8
    ).write(to: query)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755], ofItemAtPath: query.path)
    let packages = directory.appendingPathComponent("apt-deps.txt")
    try Data("installed\nmissing\n".utf8).write(to: packages)
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.validate-apt-packages"),
        component: ComponentID(rawValue: "fixture"),
        cachePolicy: .always,
        operation: .validateAptPackages(AptPackageValidation(
            packageList: FilePath(packages.path),
            environment: ["PATH": tools.path])))
    do {
        _ = try await ColliderRuntime().execute(
            graph: TaskGraph([task]),
            selected: [task.id],
            stateRoot: FilePath(directory.appendingPathComponent("state").path))
        Issue.record("missing apt package unexpectedly passed validation")
    } catch {
        let description = String(describing: error)
        #expect(description.contains(
            "sudo apt-get install -y missing"))
        #expect(!description.contains(
            "sudo apt-get install -y installed"))
    }
}

@Test func cefArtifactAssemblyPublishesSDKAndChecksummedArchive() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-cef-artifact-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source")
    let chromium = source.appendingPathComponent("chromium/src")
    let output = chromium.appendingPathComponent("out/Release_GN_x64")
    let depot = directory.appendingPathComponent("depot_tools")
    let distribution = directory.appendingPathComponent("dist")
    try FileManager.default.createDirectory(
        at: output, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: depot, withIntermediateDirectories: true)
    let buildID = "1234567890abcdef12345678"
    try JSONSerialization.data(
        withJSONObject: ["buildID": buildID],
        options: [.sortedKeys]).write(
            to: output.appendingPathComponent(
                ".nucleus-built-build.json"))
    let checkout = "abcdefa000000000000000000000000000000000"
    let version = "1.2.3.4"
    let produced = chromium.appendingPathComponent(
        "cef/binary_distrib/"
            + "cef_binary_fixture+gabcdefa+chromium-\(version)"
            + "_linux64_minimal")
    let automate = source.appendingPathComponent("automate-git.py")
    try FileManager.default.createDirectory(
        at: automate.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    let escapedProduced = produced.path.replacingOccurrences(
        of: "'", with: "\\'")
    try Data(
        """
        from pathlib import Path
        root = Path('\(escapedProduced)')
        for path in [
            root / 'Release',
            root / 'Resources',
            root / 'include',
        ]:
            path.mkdir(parents=True, exist_ok=True)
        for relative in [
            'Release/libcef.so',
            'Release/chrome-sandbox',
            'Release/icudtl.dat',
            'include/cef_version_info.h',
            'Resources/resources.pak',
        ]:
            path = root / relative
            path.write_text('fixture')
        """.utf8
    ).write(to: automate)
    let versionManager = chromium.appendingPathComponent(
        "cef/tools/version_manager.py")
    try FileManager.default.createDirectory(
        at: versionManager.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    try Data("raise SystemExit(0)\n".utf8).write(to: versionManager)
    let tools = directory.appendingPathComponent("tools")
    try FileManager.default.createDirectory(
        at: tools, withIntermediateDirectories: true)
    let ldd = tools.appendingPathComponent("ldd")
    try Data("#!/bin/sh\nprintf 'all resolved\\n'\n".utf8).write(to: ldd)
    let cc = tools.appendingPathComponent("cc")
    try Data(
        """
        #!/bin/sh
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "-o" ]; then
            out="$2"
            break
          fi
          shift
        done
        printf '#!/bin/sh\\nexit 0\\n' > "$out"
        chmod 755 "$out"
        """.utf8
    ).write(to: cc)
    for executable in [ldd, cc] {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path)
    }
    let environment = [
        "PATH": tools.path + ":"
            + (ProcessInfo.processInfo.environment["PATH"]
                ?? "/usr/bin:/bin"),
    ]
    let assembly = CEFArtifactAssembly(
        sourceRoot: FilePath(source.path),
        chromiumSource: FilePath(chromium.path),
        buildOutput: FilePath(output.path),
        depotTools: FilePath(depot.path),
        distributionRoot: FilePath(distribution.path),
        cefBranch: "fixture",
        cefCheckout: checkout,
        chromiumVersion: version,
        environment: environment)
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.assemble-cef-artifact"),
        component: ComponentID(rawValue: "fixture"),
        outputs: [
            OutputDeclaration(
                path: FilePath(distribution.appendingPathComponent(
                    "current").path),
                validation: .exists),
        ],
        cachePolicy: .always,
        operation: .sequence([
            .assembleCEFArtifact(assembly),
            .validateCEFArtifact(assembly),
        ]))
    _ = try await ColliderRuntime().execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: FilePath(directory.appendingPathComponent("state").path))
    #expect(try FileManager.default.destinationOfSymbolicLink(
        atPath: distribution.appendingPathComponent(
            "current-release").path) == "releases/\(buildID)")
    let artifactNames = try FileManager.default.contentsOfDirectory(
        atPath: distribution.appendingPathComponent(
            "artifacts-current").path)
    #expect(artifactNames.contains {
        $0.hasSuffix(".tar.gz.sha256")
    })
}

@Test func browserInstallationPublishesOneVersionedPrefixGeneration() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-browser-install-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let distribution = directory.appendingPathComponent("distribution")
    let buildID = "fedcbafedcbafedcbafedcba"
    let artifact = distribution.appendingPathComponent(
        "generations/\(buildID)")
    let runtime = artifact.appendingPathComponent("runtime")
    let widevine = runtime.appendingPathComponent("WidevineCdm")
    try FileManager.default.createDirectory(
        at: widevine.appendingPathComponent(
            "_platform_specific/linux_x64"),
        withIntermediateDirectories: true)
    for (path, value) in [
        (runtime.appendingPathComponent("nucleus-browser-bin"), "browser"),
        (runtime.appendingPathComponent("chrome_sandbox"), "sandbox"),
        (widevine.appendingPathComponent("manifest.json"), "{}"),
        (
            widevine.appendingPathComponent(
                "_platform_specific/linux_x64/libwidevinecdm.so"),
            "widevine"
        ),
    ] {
        try Data(value.utf8).write(to: path)
    }
    let launcher = artifact.appendingPathComponent("bin/nucleus-browser")
    try FileManager.default.createDirectory(
        at: launcher.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: launcher)
    let desktop = artifact.appendingPathComponent(
        "share/applications/dev.nucleus.Browser.desktop.in")
    try FileManager.default.createDirectory(
        at: desktop.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    try Data(
        "[Desktop Entry]\nType=Application\n"
            .appending("Exec=@NUCLEUS_BROWSER_LAUNCHER@\n").utf8
    ).write(to: desktop)
    let icon = artifact.appendingPathComponent(
        "share/icons/hicolor/128x128/apps/dev.nucleus.Browser.png")
    try FileManager.default.createDirectory(
        at: icon.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    try Data("icon".utf8).write(to: icon)
    try JSONSerialization.data(
        withJSONObject: ["buildID": buildID],
        options: [.sortedKeys]).write(
            to: artifact.appendingPathComponent(
                "nucleus-build-manifest.json"))
    try FileManager.default.createSymbolicLink(
        atPath: distribution.appendingPathComponent("current").path,
        withDestinationPath: "generations/\(buildID)")

    let tools = directory.appendingPathComponent("tools")
    try FileManager.default.createDirectory(
        at: tools, withIntermediateDirectories: true)
    for (name, source) in [
        ("ldd", "#!/bin/sh\nprintf 'all resolved\\n'\n"),
        ("unshare", "#!/bin/sh\nexit 0\n"),
        ("bash", "#!/bin/sh\nexec /bin/bash \"$@\"\n"),
    ] {
        let executable = tools.appendingPathComponent(name)
        try Data(source.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path)
    }
    let prefix = directory.appendingPathComponent("prefix")
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.install-browser"),
        component: ComponentID(rawValue: "fixture"),
        outputs: [
            OutputDeclaration(
                path: FilePath(prefix.appendingPathComponent(
                    "lib/nucleus-browser/current").path),
                validation: .exists),
        ],
        cachePolicy: .always,
        operation: .installBrowser(BrowserInstallation(
            distributionRoot: FilePath(distribution.path),
            prefix: FilePath(prefix.path),
            environment: ["PATH": tools.path])))
    _ = try await ColliderRuntime().execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: FilePath(directory.appendingPathComponent("state").path))
    let current = prefix.appendingPathComponent(
        "lib/nucleus-browser/current")
    let target = try FileManager.default.destinationOfSymbolicLink(
        atPath: current.path)
    #expect(target.hasPrefix("generations/"))
    #expect(try FileManager.default.destinationOfSymbolicLink(
        atPath: prefix.appendingPathComponent(
            "bin/nucleus-browser").path)
        == "../lib/nucleus-browser/current/bin/nucleus-browser")
}

@Test func invalidGenerationCandidateNeverReplacesTheActivePointer() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-generation-rollback-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let previous = directory.appendingPathComponent("generation-previous")
    let candidate = directory.appendingPathComponent("candidate")
    let generation = directory.appendingPathComponent("generation-invalid")
    let active = directory.appendingPathComponent("active")
    try FileManager.default.createDirectory(at: previous, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        atPath: active.path,
        withDestinationPath: "generation-previous")
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.publish-invalid"),
        component: ComponentID(rawValue: "fixture"),
        outputs: [
            OutputDeclaration(
                path: FilePath(generation.path),
                validation: .nonEmptyDirectory),
            OutputDeclaration(path: FilePath(active.path), validation: .exists),
        ],
        operation: .activateGeneration(
            candidate: FilePath(candidate.path),
            generation: FilePath(generation.path),
            active: FilePath(active.path)))

    await #expect(throws: (any Error).self) {
        try await ColliderRuntime().execute(
            graph: TaskGraph([task]),
            selected: [task.id],
            stateRoot: FilePath(directory.appendingPathComponent("state").path))
    }
    #expect(FileManager.default.fileExists(atPath: candidate.path))
    #expect(!FileManager.default.fileExists(atPath: generation.path))
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: active.path)
        == "generation-previous")
}

@Test func taskEnginePublishesAndAtomicallyActivatesImmutableGeneration() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-generation-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let candidate = directory.appendingPathComponent("candidate")
    let generation = directory.appendingPathComponent("generation-1")
    let active = directory.appendingPathComponent("active")
    try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
    try Data("artifact".utf8).write(to: candidate.appendingPathComponent("payload"))
    let task = TaskDeclaration(
        id: TaskID(rawValue: "fixture.publish"),
        component: ComponentID(rawValue: "fixture"),
        outputs: [
            OutputDeclaration(
                path: FilePath(generation.path),
                validation: .nonEmptyDirectory),
            OutputDeclaration(path: FilePath(active.path), validation: .exists),
        ],
        operation: .activateGeneration(
            candidate: FilePath(candidate.path),
            generation: FilePath(generation.path),
            active: FilePath(active.path)))

    let report = try await ColliderRuntime().execute(
        graph: TaskGraph([task]),
        selected: [task.id],
        stateRoot: FilePath(directory.appendingPathComponent("state").path))
    #expect(report.executed == [task.id])
    #expect(!FileManager.default.fileExists(atPath: candidate.path))
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: active.path)
        == "generation-1")
    #expect(try String(
        contentsOf: generation.appendingPathComponent("payload"),
        encoding: .utf8) == "artifact")
}

@Test func generationPublicationCutsOverMutableLayoutAndReusesIdenticalGeneration() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-generation-cutover-\(UUID().uuidString)")
    let candidate = directory.appendingPathComponent("candidate")
    let generation = directory.appendingPathComponent("generation")
    let active = directory.appendingPathComponent("active")
    try FileManager.default.createDirectory(
        at: candidate, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: active, withIntermediateDirectories: true)
    try Data("obsolete".utf8).write(
        to: active.appendingPathComponent("mutable"))
    try Data("artifact".utf8).write(
        to: candidate.appendingPathComponent("payload"))
    defer { try? FileManager.default.removeItem(at: directory) }

    try GenerationPublisher.publish(
        candidate: FilePath(candidate.path),
        generation: FilePath(generation.path),
        active: FilePath(active.path))
    #expect(try FileManager.default.destinationOfSymbolicLink(
        atPath: active.path) == "generation")

    try FileManager.default.createDirectory(
        at: candidate, withIntermediateDirectories: true)
    try Data("artifact".utf8).write(
        to: candidate.appendingPathComponent("payload"))
    try GenerationPublisher.publish(
        candidate: FilePath(candidate.path),
        generation: FilePath(generation.path),
        active: FilePath(active.path))
    #expect(!FileManager.default.fileExists(atPath: candidate.path))
    #expect(try FileManager.default.destinationOfSymbolicLink(
        atPath: active.path) == "generation")
}

@Test func publicationFaultsPreserveACompleteOldOrNewActiveGeneration() throws {
    struct InjectedPublicationFault: Error {}

    for boundary in GenerationPublicationBoundary.allCases {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "collider-generation-fault-\(UUID().uuidString)")
        let previous = directory.appendingPathComponent("previous")
        let candidate = directory.appendingPathComponent("candidate")
        let generation = directory.appendingPathComponent("generation")
        let active = directory.appendingPathComponent("active")
        try FileManager.default.createDirectory(
            at: previous, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: candidate, withIntermediateDirectories: true)
        try Data("old".utf8).write(
            to: previous.appendingPathComponent("payload"))
        try Data("new".utf8).write(
            to: candidate.appendingPathComponent("payload"))
        try FileManager.default.createSymbolicLink(
            atPath: active.path, withDestinationPath: "previous")
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(throws: InjectedPublicationFault.self) {
            try GenerationPublisher.publish(
                candidate: FilePath(candidate.path),
                generation: FilePath(generation.path),
                active: FilePath(active.path),
                after: {
                    if $0 == boundary { throw InjectedPublicationFault() }
                })
        }

        let cutoverCompleted = switch boundary {
        case .activePointerReplaced, .activeDirectorySynchronized:
            true
        default:
            false
        }
        let target = try FileManager.default.destinationOfSymbolicLink(
            atPath: active.path)
        #expect(target == (cutoverCompleted ? "generation" : "previous"))
        let activePayload = active
            .resolvingSymlinksInPath()
            .appendingPathComponent("payload")
        #expect(try String(contentsOf: activePayload, encoding: .utf8)
            == (cutoverCompleted ? "new" : "old"))
        #expect(FileManager.default.fileExists(atPath: previous.path))
    }
}
