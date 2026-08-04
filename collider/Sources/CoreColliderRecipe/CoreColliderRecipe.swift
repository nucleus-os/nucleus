import ColliderCore
import Foundation
import NativeBuilderColliderRecipe
import SystemPackage

package enum CoreTaskIDs {
    package static let sources = TaskID(rawValue: "core.sources")
    package static let androidNativeSDK = TaskID(rawValue: "core.native-sdk.android-arm64")
    package static let androidSkia = TaskID(rawValue: "core.skia.android-arm64")
    package static let androidHostBuild = TaskID(rawValue: "core.android-host.build")
    package static let validateAndroidHost = TaskID(
        rawValue: "core.android-host.validate")
    package static let androidBuild = TaskID(rawValue: "core.android.build")

    package static func skia(_ target: NativeLinuxTarget) -> TaskID {
        TaskID(rawValue: "core.skia.\(target.identifier)")
    }

    package static func nativeSDK(_ target: NativeLinuxTarget) -> TaskID {
        TaskID(rawValue: "core.native-sdk.\(target.identifier)")
    }
}

public enum CoreColliderRecipe: ColliderComponent {
    public static let descriptor = ComponentDescriptor(
        id: ComponentID(rawValue: "core"),
        canonicalName: "core",
        directoryName: "core")

    public static func makeComponent(
        in context: RecipeContext
    ) throws -> ComponentDefinition {
        let root = context.componentRoot(descriptor)
        let source = try prepareSkiaDependencies(
            root: root,
            environment: context.environment)
        var tasks = [source]
        var roots: Set<TaskID> = []
        for architecture in PlatformArchitecture.allCases {
            let target = NativeLinuxTarget(architecture: architecture)
            let skia = buildSkiaLinux(
                root: root,
                environment: context.environment,
                target: target,
                builder: context.nativeBuilder)
            let sdk = publishLinuxRenderSDK(
                root: root,
                sdkRoot: context.nativeSDK(for: target),
                target: target)
            tasks += [skia, sdk]
            roots.insert(sdk.id)
        }
        let androidToolchain = try AndroidToolchainVersions.load(
            workspaceRoot: context.repositoryRoot)
        let ndk = try androidToolchain.ndkRoot(
            environment: context.environment,
            validate: false,
            fallbackHome: context.cacheRoot.appending("nucleus/unconfigured-home"))
        let androidSDKRoot = context.nativeSDKRoot.appending("android-arm64")
        var androidEnvironment = context.environment
        androidEnvironment["NUCLEUS_NATIVE_SDK_ROOT"] = androidSDKRoot.string
        let androidSkia = buildSkiaAndroid(
            root: root,
            minimumAndroidAPI: androidToolchain.minimumSDK,
            environment: androidEnvironment,
            builder: context.nativeBuilder)
        let androidNativeSDK = publishAndroidRenderSDK(
            root: root,
            sdkRoot: androidSDKRoot,
            dependencies: [androidSkia.id])
        let androidSwiftPM = try context.swiftPM(
            .androidARM64(apiLevel: androidToolchain.minimumSDK))
        let androidHost = buildAndroidHost(
            root: root,
            environment: androidEnvironment,
            swiftPM: androidSwiftPM,
            dependencies: [androidNativeSDK.id])
        let androidValidation = validateAndroidHost(
            root: root,
            library: androidSwiftPM.configurationProducts.appending(
                "libnucleus-android.so"),
            ndk: ndk,
            environment: androidEnvironment,
            dependencies: [androidHost.id])
        let androidBuild = buildAndroidProject(
            root: root,
            environment: androidEnvironment,
            dependency: androidValidation.id)
        tasks += [
            androidSkia, androidNativeSDK, androidHost, androidValidation,
            androidBuild,
        ]
        return try ComponentDefinition(
            descriptor: descriptor,
            tasks: tasks,
            entrypoints: [
                ComponentEntrypoint(id: .bootstrap, roots: roots),
                ComponentEntrypoint(id: .androidBuild, roots: [androidBuild.id]),
                ComponentEntrypoint(
                    id: .androidNative,
                    roots: [androidValidation.id]),
                ComponentEntrypoint(
                    id: .androidVerify,
                    roots: [androidValidation.id]),
            ])
    }

    public static func prepareSkiaDependencies(
        root: FilePath,
        environment: [String: String]
    ) throws -> TaskDeclaration {
        let skia = root.appending("third-party/skia")
        let gnArchive = root.appending(".skia-build/downloads/gn-linux-arm64.zip")
        let dependencyVerifier = root.appending(".skia-build/verify-deps.py")
        guard
            let gnURL = URL(
                string:
                    "https://chrome-infra-packages.appspot.com/dl/gn/gn/linux-arm64/+/git_revision:b2afae122eeb6ce09c52d63f67dc53fc517dbdc8"
            ),
            let gnDigest = ArtifactDigest(
                sha256Hex:
                    "376e1358ded109d955b8eb55ba2a7dec0e95ab1f8dfe0e18011e06eed78a011f")
        else {
            preconditionFailure("the pinned Linux arm64 GN artifact is invalid")
        }
        let gnDownload = try DownloadSpec(
            url: gnURL,
            permittedRedirectOrigins: [
                "https://chrome-infra-packages.appspot.com",
                "https://storage.googleapis.com",
            ],
            expectedDigest: gnDigest,
            maximumResponseSize: 16 * 1_024 * 1_024,
            acceptedMediaTypes: ["application/octet-stream"])
        return TaskDeclaration(
            id: CoreTaskIDs.sources,
            component: ComponentID(rawValue: "core"),
            inputs: [
                .file(skia.appending("DEPS")),
                .file(skia.appending("tools/git-sync-deps")),
                .file(skia.appending("bin/fetch-gn")),
            ],
            outputs: [
                OutputDeclaration(
                    path: skia.appending("DEPS"),
                    validation: .regularFile),
                OutputDeclaration(
                    path: skia.appending("third_party/externals"),
                    validation: .nonEmptyDirectory),
                OutputDeclaration(
                    path: skia.appending("bin/gn"),
                    validation: .executableFile),
            ],
            locks: [.checkout("core-sources")],
            cachePolicy: .always,
            operation: .sequence([
                .command(
                    CommandSpec(
                        executable: .operationalNamed("python3"),
                        arguments: [
                            skia.appending("tools/git-sync-deps").string
                        ],
                        workingDirectory: root,
                        environment: environment)),
                .writeFile(
                    dependencyVerifier,
                    bytes: Array(skiaDependencyVerifier.utf8)),
                .command(
                    CommandSpec(
                        executable: .operationalNamed("python3"),
                        arguments: [dependencyVerifier.string, skia.appending("DEPS").string],
                        workingDirectory: skia,
                        environment: environment)),
                .download(gnDownload, candidate: gnArchive),
                .extractZip(
                    ZipExtraction(
                        archive: gnArchive,
                        entry: "gn",
                        destination: skia.appending("bin"),
                        environment: environment)),
                .setPermissions(
                    FilePermissionUpdate(
                        path: skia.appending("bin/gn"),
                        permissions: 0o755)),
            ]))
    }

    public static func buildSkiaLinux(
        root: FilePath,
        environment: [String: String],
        target: NativeLinuxTarget,
        builder: NativeOCIConfiguration
    ) -> TaskDeclaration {
        skiaTask(
            id: CoreTaskIDs.skia(target),
            root: root,
            environment: environment,
            buildDirectory: root.appending(".skia-build/\(target.identifier)"),
            gnArguments: linuxGNArguments(target),
            mode: "linux",
            artifactTarget: target.artifactTarget,
            intelBinaryTranslationPolicy: target.intelBinaryTranslationPolicy,
            containerEnvironment: targetEnvironment(target),
            builder: builder)
    }

    public static func buildSkiaAndroid(
        root: FilePath,
        minimumAndroidAPI: UInt32,
        environment: [String: String],
        builder: NativeOCIConfiguration
    ) -> TaskDeclaration {
        let ndk = "/opt/android-ndk-r30-beta2"
        return skiaTask(
            id: CoreTaskIDs.androidSkia,
            root: root,
            environment: environment,
            buildDirectory: root.appending(".skia-build/android-arm64"),
            gnArguments: [
                #"target_os="android""#,
                #"target_cpu="arm64""#,
                #"ndk="\#(ndk)""#,
                "ndk_api=\(minimumAndroidAPI)",
                "skia_use_fontconfig=false",
            ] + commonGNArguments,
            mode: "android",
            artifactTarget: .androidARM64(apiLevel: minimumAndroidAPI),
            intelBinaryTranslationPolicy: .required,
            containerEnvironment: [:],
            builder: builder)
    }

    public static func buildAndroidHost(
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation,
        dependencies: [TaskID]
    ) -> TaskDeclaration {
        let package = root.appending("platform-android")
        let product = swiftPM.configurationProducts.appending(
            "libnucleus-android.so")
        return TaskDeclaration(
            id: CoreTaskIDs.androidHostBuild,
            component: ComponentID(rawValue: "core"),
            dependencies: dependencies,
            swiftProducts: [
                swiftPM.product(
                    package: "platform-android",
                    product: "nucleus-android",
                    packageRoot: package,
                    environment: environment,
                    expectedOutputs: [
                        PathPostcondition(
                            path: swiftPM.executable("nucleus-android"),
                            validation: .executableFile)
                    ])
            ],
            inputs: [
                .tree(package.appending("c")),
                .tree(package.appending("swift-core")),
                .tree(package.appending("swift-jni")),
                swiftPM.identityInput,
                .tool(.named("swift")),
            ],
            postconditions: [
                swiftPM.postcondition,
                PathPostcondition(
                    path: product,
                    validation: .regularFile),
            ],
            locks: [.checkout("core-android-host")],
            operation: .sequence([]))
    }

    public static func validateAndroidHost(
        root: FilePath,
        library: FilePath,
        ndk: FilePath,
        environment: [String: String],
        dependencies: [TaskID] = [TaskID(rawValue: "core.android-host.build")]
    ) -> TaskDeclaration {
        let hostLibrary = library
        let kotlinContract = root.appending(
            "android/nucleus/src/main/kotlin/dev/nucleus/android/"
                + "NucleusNative.kt")
        return TaskDeclaration(
            id: CoreTaskIDs.validateAndroidHost,
            component: ComponentID(rawValue: "core"),
            dependencies: dependencies,
            inputs: [
                dependencies.isEmpty
                    ? .file(hostLibrary)
                    : .dependencyOutput(hostLibrary),
                .file(kotlinContract),
                .tool(.path(androidNDKReadELFPath(ndk))),
            ],
            cachePolicy: .always,
            operation: .validateAndroidHost(
                AndroidHostValidation(
                    library: hostLibrary,
                    kotlinContract: kotlinContract,
                    ndk: ndk,
                    environment: environment)))
    }

    public static func buildAndroidProject(
        root: FilePath,
        environment: [String: String],
        dependency: TaskID
    ) -> TaskDeclaration {
        let android = root.appending("android")
        return TaskDeclaration(
            id: CoreTaskIDs.androidBuild,
            component: descriptor.id,
            dependencies: [dependency],
            inputs: [
                .file(android.appending("settings.gradle.kts")),
                .file(android.appending("build.gradle.kts")),
                .file(android.appending("gradle/libs.versions.toml")),
                .tree(android.appending("nucleus/src")),
                .tree(android.appending("smoke-app/src")),
                .tool(.path(android.appending("gradlew"))),
            ],
            locks: [.checkout("core-android-gradle")],
            cachePolicy: .always,
            operation: .command(
                CommandSpec(
                    executable: .path(android.appending("gradlew")),
                    arguments: ["verifyDebug"],
                    workingDirectory: android,
                    environment: environment)))
    }

    public static func publishAndroidRenderSDK(
        root: FilePath,
        sdkRoot: FilePath,
        dependencies: [TaskID]
    ) -> TaskDeclaration {
        let sdk = sdkRoot.appending("render")
        let links: [(String, FilePath)] = [
            ("include/skia", root.appending("third-party/skia")),
            ("lib/skia-graphite", root.appending(".skia-build/android-arm64")),
            ("include/skia-text", root.appending("render-cxx/skia")),
        ]
        return TaskDeclaration(
            id: CoreTaskIDs.androidNativeSDK,
            component: ComponentID(rawValue: "core"),
            dependencies: dependencies,
            inputs: links.map {
                .value(
                    name: $0.0,
                    bytes: Array($0.1.string.utf8))
            },
            outputs: links.map {
                OutputDeclaration(
                    path: sdk.appending($0.0),
                    validation: .symlinkTarget)
            },
            locks: [
                .shared(sdkRoot.appending(".render.lock"))
            ],
            operation: .sequence(
                links.map {
                    .replaceSymlink(
                        path: sdk.appending($0.0),
                        target: $0.1.string)
                }))
    }

    public static func publishLinuxRenderSDK(
        root: FilePath,
        sdkRoot: FilePath,
        target: NativeLinuxTarget
    ) -> TaskDeclaration {
        let sdk = sdkRoot.appending("render")
        let links: [(String, FilePath)] = [
            ("include/skia", root.appending("third-party/skia")),
            (
                "lib/skia-graphite",
                root.appending(".skia-build/\(target.identifier)")
            ),
            ("include/skia-text", root.appending("render-cxx/skia")),
        ]
        return TaskDeclaration(
            id: CoreTaskIDs.nativeSDK(target),
            component: ComponentID(rawValue: "core"),
            dependencies: [
                CoreTaskIDs.skia(target)
            ],
            inputs: links.map {
                .value(name: $0.0, bytes: Array($0.1.string.utf8))
            },
            outputs: links.map {
                OutputDeclaration(
                    path: sdk.appending($0.0),
                    validation: .symlinkTarget)
            },
            locks: [.shared(sdkRoot.appending(".render.lock"))],
            operation: .sequence(
                links.map {
                    .replaceSymlink(
                        path: sdk.appending($0.0),
                        target: $0.1.string)
                }))
    }
}

private let skiaDependencyVerifier = #"""
    import os
    import subprocess
    import sys

    deps_path = os.path.abspath(sys.argv[1])
    scope = {}
    with open(deps_path, encoding="utf-8") as source:
        exec("def Var(name): return vars[name]\n" + source.read(), scope)
    for relative, specification in sorted(scope["deps"].items()):
        if not isinstance(specification, str):
            continue
        _, revision = specification.rsplit("@", 1)
        checkout = os.path.join(os.path.dirname(deps_path), relative)
        expected = subprocess.check_output(
            ["git", "rev-parse", f"{revision}^{{commit}}"], cwd=checkout, text=True
        ).strip()
        actual = subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=checkout, text=True
        ).strip()
        if actual != expected:
            raise SystemExit(
                f"{relative}: expected {revision} ({expected}), found {actual}"
            )
        dirty = subprocess.check_output(
            ["git", "status", "--porcelain", "--untracked-files=no"],
            cwd=checkout,
            text=True,
        )
        if dirty:
            raise SystemExit(f"{relative}: tracked source modifications remain")
    """#

private let ninjaTargets = ["skia", "skshaper", "skparagraph", "skunicode", "svg"]
private let requiredArchives = [
    "libskia.a", "libskshaper.a", "libskparagraph.a",
    "libskunicode_core.a", "libskunicode_icu.a", "libsvg.a",
    "libskcms.a", "libskresources.a", "libfreetype2.a",
    "libharfbuzz.a", "libicu.a", "libpng.a", "libjpeg.a",
    "libjpeg12.a", "libjpeg16.a", "libwebp.a", "libwebp_sse41.a",
    "libexpat.a", "libzlib.a", "libwuffs.a", "libdng_sdk.a",
    "libpiex.a",
]
private let commonGNArguments = [
    #"cc_wrapper="ccache""#,
    "is_official_build=true", "skia_enable_tools=false",
    "skia_enable_graphite=true", "skia_use_dawn=false", "skia_use_vulkan=true",
    "skia_use_freetype=true", "skia_use_harfbuzz=true", "skia_use_icu=true",
    "skia_use_expat=true", "skia_use_zlib=true", "skia_use_wuffs=true",
    "skia_use_libpng_decode=true", "skia_use_libpng_encode=true",
    "skia_use_libjpeg_turbo_decode=true",
    "skia_use_libjpeg_turbo_encode=true",
    "skia_use_libwebp_decode=true", "skia_use_libwebp_encode=true",
    "skia_enable_skshaper=true", "skia_enable_skparagraph=true",
    "skia_enable_skunicode=true", "skia_enable_svg=true",
    "skia_enable_pdf=true", "skia_enable_precompile=true",
    "skia_use_system_expat=false", "skia_use_system_freetype2=false",
    "skia_use_system_harfbuzz=false", "skia_use_system_icu=false",
    "skia_use_system_libjpeg_turbo=false", "skia_use_system_libpng=false",
    "skia_use_system_libwebp=false", "skia_use_system_zlib=false",
]
private func linuxGNArguments(_ target: NativeLinuxTarget) -> [String] {
    let sysroot = target.containerSwiftSDKRoot
    return [
        #"target_os="linux""#,
        #"target_cpu="\#(target.skiaCPU)""#,
        "skia_use_partition_alloc=false",
        "skia_use_fontconfig=true",
        #"extra_cflags=["--target=\#(target.targetTriple)","--sysroot=\#(sysroot)","-idirafter/usr/include","-idirafter/usr/include/\#(target.gnuArchitecture)"]"#,
        #"extra_cflags_cc=["--target=\#(target.targetTriple)","--sysroot=\#(sysroot)","-stdlib=libc++","-idirafter/usr/include","-idirafter/usr/include/\#(target.gnuArchitecture)"]"#,
        #"extra_asmflags=["--target=\#(target.targetTriple)","--sysroot=\#(sysroot)"]"#,
        #"extra_ldflags=["--target=\#(target.targetTriple)","--sysroot=\#(sysroot)","-stdlib=libc++","-fuse-ld=lld","-L/usr/lib/\#(target.gnuArchitecture)"]"#,
        #"cc="clang""#,
        #"cxx="clang++""#,
    ] + commonGNArguments
}

private func targetEnvironment(
    _ target: NativeLinuxTarget
) -> [String: String] {
    [
        "PKG_CONFIG_LIBDIR":
            "/usr/lib/\(target.gnuArchitecture)/pkgconfig:/usr/share/pkgconfig"
    ]
}

private func androidNDKReadELFPath(_ ndk: FilePath) -> FilePath {
    #if os(macOS)
    let host = "darwin-x86_64"
    #else
    let host = "linux-x86_64"
    #endif
    return ndk.appending(
        "toolchains/llvm/prebuilt/\(host)/bin/llvm-readelf")
}

private func skiaTask(
    id: TaskID,
    root: FilePath,
    environment: [String: String],
    buildDirectory: FilePath,
    gnArguments: [String],
    mode: String,
    artifactTarget: ArtifactTarget,
    intelBinaryTranslationPolicy: OCIIntelBinaryTranslationPolicy,
    containerEnvironment: [String: String],
    builder: NativeOCIConfiguration
) -> TaskDeclaration {
    let skia = root.appending("third-party/skia")
    let dependencies = [
        CoreTaskIDs.sources,
        NativeBuilderTaskIDs.prepare,
    ]
    let imageInputs: [ArtifactInput] = [
        .dependencyOutput(builder.imageID)
    ]
    let containerBuildDirectory = "/build/\(buildDirectory.lastComponent!)"
    let mounts = [
        OCIMount(
            source: skia,
            target: "/src",
            access: .readOnly),
        OCIMount(
            source: root.appending(".skia-build"),
            target: "/build",
            access: .readWrite),
        OCIMount(
            source: builder.ccache,
            target: "/ccache",
            access: .readWrite),
        OCIMount(
            source: builder.swiftSDKRoot,
            target: "/swift-sdk",
            access: .readOnly),
    ]
    func execution(_ command: [String]) -> TaskOperation {
        .runOCI(
            OCIExecution(
                executionPlatform: .linuxARM64OCI,
                artifactTarget: artifactTarget,
                imageID: builder.imageID,
                hostname: "native-\(mode)-build",
                workingDirectory: "/src",
                hostWorkingDirectory: skia,
                mounts: mounts,
                networkPolicy: .externalDisabled,
                userPolicy: .builder,
                capabilityPolicy: .dropAll,
                privilegePolicy: .prohibitAcquisition,
                processFilesystemPolicy: .standard,
                intelBinaryTranslationPolicy: intelBinaryTranslationPolicy,
                resourceLimits: .parallelBuild,
                containerEnvironment: containerEnvironment.merging(
                    ["CCACHE_LOGFILE": "/ccache/ccache.log"],
                    uniquingKeysWith: { configured, _ in configured }),
                command: ["skia-\(mode)"] + command,
                environment: builder.environment,
                output: .logged))
    }
    let operation = TaskOperation.sequence([
        execution([
            "/src/bin/gn", "gen", containerBuildDirectory,
            "--args=" + gnArguments.joined(separator: " "),
        ]),
        execution(
            ["ninja", "-C", containerBuildDirectory] + ninjaTargets),
    ])
    return TaskDeclaration(
        id: id,
        component: ComponentID(rawValue: "core"),
        dependencies: dependencies,
        inputs: [
            .dependencyOutput(skia),
            .tree(builder.swiftSDKRoot),
            .value(
                name: "gn-arguments",
                bytes: Array(gnArguments.joined(separator: "\u{0}").utf8)),
        ] + imageInputs,
        outputs: requiredArchives.map {
            OutputDeclaration(
                path: buildDirectory.appending($0),
                validation: .regularFile)
        },
        locks: [.checkout(id.rawValue)],
        operation: operation)
}
