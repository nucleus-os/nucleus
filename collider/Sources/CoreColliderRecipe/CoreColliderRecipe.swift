import ColliderCore
import Foundation
import SystemPackage

public enum CoreColliderRecipe {
    public static func build(
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation
    ) -> TaskDeclaration {
        task(
            "core.build",
            root,
            environment,
            ["build"],
            [
                TaskID(rawValue: "tracy.build"),
                TaskID(rawValue: "vulkan.build"),
                TaskID(rawValue: "wayland.build"),
            ],
            swiftPM)
    }

    public static func test(
        root: FilePath,
        environment: [String: String],
        swiftPM: SwiftPMInvocation
    ) -> TaskDeclaration {
        let requirement = swiftPM.testProduct(
            package: "core",
            testProduct: "NucleusPackageTests",
            packageRoot: root,
            environment: environment)
        return TaskDeclaration(
            id: TaskID(rawValue: "core.test"),
            component: ComponentID(rawValue: "core"),
            dependencies: [TaskID(rawValue: "core.build")],
            subsumedDependencies: [TaskID(rawValue: "core.build")],
            swiftTests: [requirement],
            locks: [.checkout("core")],
            cachePolicy: .always,
            operation: .runSwiftTest(
                SwiftTestExecution(
                    requirement: requirement)))
    }

    public static func prepareSkiaDependencies(
        root: FilePath,
        environment: [String: String]
    ) throws -> TaskDeclaration {
        let skia = root.appending("third-party/skia")
        let gnArchive = root.appending(".skia-build/downloads/gn-linux-arm64.zip")
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
            id: TaskID(rawValue: "core.sources"),
            component: ComponentID(rawValue: "core"),
            inputs: [
                .file(skia.appending("DEPS")),
                .file(skia.appending("tools/git-sync-deps")),
                .file(skia.appending("bin/fetch-gn")),
                .tool(.named("git")),
                .tool(.named("python3")),
                .tool(.named("unzip")),
                .tool(.named("chmod")),
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
            operation: .sequence([
                .command(
                    CommandSpec(
                        executable: .named("python3"),
                        arguments: [
                            skia.appending("tools/git-sync-deps").string
                        ],
                        workingDirectory: root,
                        environment: environment)),
                .download(gnDownload, candidate: gnArchive),
                .command(
                    CommandSpec(
                        executable: .named("unzip"),
                        arguments: [
                            "-o", gnArchive.string, "gn", "-d",
                            skia.appending("bin").string,
                        ],
                        workingDirectory: root,
                        environment: environment)),
                .command(
                    CommandSpec(
                        executable: .named("chmod"),
                        arguments: ["0755", skia.appending("bin/gn").string],
                        workingDirectory: root,
                        environment: environment)),
            ]))
    }

    public static func buildSkiaLinux(
        root: FilePath,
        environment: [String: String],
        target: NativeLinuxTarget,
        builder: NativeOCIConfiguration
    ) -> TaskDeclaration {
        skiaTask(
            id: "core.skia.\(target.identifier)",
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
            id: "core.skia.android-arm64",
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
        dependencies: [TaskID] = [TaskID(rawValue: "core.native-sdk")]
    ) -> TaskDeclaration {
        let package = root.appending("platform-android")
        let product = swiftPM.configurationProducts.appending(
            "libnucleus-android.so")
        return TaskDeclaration(
            id: TaskID(rawValue: "core.android-host.build"),
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
            id: TaskID(rawValue: "core.android-host.validate"),
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

    public static func publishRenderSDK(
        root: FilePath,
        sdkRoot: FilePath,
        dependencies: [TaskID] = [TaskID(rawValue: "core.skia.host")]
    ) -> TaskDeclaration {
        let sdk = sdkRoot.appending("render")
        let links: [(String, FilePath)] = [
            ("include/skia", root.appending("third-party/skia")),
            ("lib/skia-graphite", root.appending(".skia-build/graphite")),
            ("include/skia-text", root.appending("render-cxx/skia")),
            (
                "lib/skia-graphite-android-arm64",
                root.appending(".skia-build/android-arm64")
            ),
        ]
        return TaskDeclaration(
            id: TaskID(rawValue: "core.native-sdk"),
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
                    validation: .exists)
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
        let sdk = sdkRoot.appending(target.identifier).appending("render")
        let links: [(String, FilePath)] = [
            ("include/skia", root.appending("third-party/skia")),
            (
                "lib/skia-graphite",
                root.appending(".skia-build/\(target.identifier)")
            ),
            ("include/skia-text", root.appending("render-cxx/skia")),
        ]
        return TaskDeclaration(
            id: TaskID(rawValue: "core.native-sdk.\(target.identifier)"),
            component: ComponentID(rawValue: "core"),
            dependencies: [
                TaskID(rawValue: "core.skia.\(target.identifier)")
            ],
            inputs: links.map {
                .value(name: $0.0, bytes: Array($0.1.string.utf8))
            },
            outputs: links.map {
                OutputDeclaration(
                    path: sdk.appending($0.0),
                    validation: .exists)
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
    id: String,
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
        TaskID(rawValue: "core.sources"),
        TaskID(rawValue: "native.builder"),
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
        id: TaskID(rawValue: id),
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
        locks: [.checkout(id)],
        operation: operation)
}

private func task(
    _ id: String,
    _ root: FilePath,
    _ environment: [String: String],
    _ arguments: [String],
    _ dependencies: [TaskID],
    subsumedDependencies: [TaskID] = [],
    _ swiftPM: SwiftPMInvocation
) -> TaskDeclaration {
    let isBuild = arguments == ["build"]
    return TaskDeclaration(
        id: TaskID(rawValue: id),
        component: ComponentID(rawValue: "core"),
        dependencies: dependencies,
        subsumedDependencies: subsumedDependencies,
        swiftProducts: isBuild
            ? [
                swiftPM.product(
                    package: "core",
                    product: "Nucleus",
                    packageRoot: root,
                    environment: environment)
            ] : [],
        inputs: [
            .tree(root.appending("swift")),
            .tree(root.appending("render-cxx")),
            swiftPM.identityInput,
            .tool(.named("swift")),
        ],
        postconditions: [swiftPM.postcondition],
        locks: [.checkout("core")] + (isBuild ? [] : [swiftPM.lock]),
        operation: isBuild
            ? .sequence([])
            : .command(
                swiftPM.command(
                    arguments: arguments,
                    workingDirectory: root,
                    environment: environment)))
}
