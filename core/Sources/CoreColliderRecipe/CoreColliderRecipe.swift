import ColliderCore
import SystemPackage

public enum CoreColliderRecipe {
    public static func build(root: FilePath, environment: [String: String]) -> TaskDeclaration { task("core.build", root, environment, ["build"], [TaskID(rawValue: "tracy.build"), TaskID(rawValue: "vulkan.build"), TaskID(rawValue: "wayland.build")]) }
    public static func test(root: FilePath, environment: [String: String]) -> TaskDeclaration { task("core.test", root, environment, ["test"], [TaskID(rawValue: "core.build")]) }

    public static func synchronizeSources(
        root: FilePath,
        repositoryRoot: FilePath,
        sourceIdentity: [UInt8],
        environment: [String: String]
    ) -> TaskDeclaration {
        let skia = root.appending("third-party/skia")
        let patch = root.appending(
            "third-party/patches/skia-graphite-vulkan-render-pass-dependencies.patch")
        return TaskDeclaration(
            id: TaskID(rawValue: "core.sources"),
            component: ComponentID(rawValue: "core"),
            inputs: [
                .file(repositoryRoot.appending(".gitmodules")),
                .file(patch),
                .optionalTree(skia, fallback: sourceIdentity),
                .tool(.named("git")),
                .tool(.named("python3")),
            ],
            outputs: [
                OutputDeclaration(
                    path: skia.appending("DEPS"),
                    validation: .regularFile),
                OutputDeclaration(
                    path: skia.appending("third_party/externals"),
                    validation: .nonEmptyDirectory),
            ],
            locks: [.checkout("core-sources")],
            operation: .sequence([
                .command(CommandSpec(
                    executable: .named("git"),
                    arguments: [
                        "submodule", "update", "--init", "--recursive",
                        "core/third-party",
                        "third-party/swift-java",
                        "third-party/swift-java-jni-core",
                    ],
                    workingDirectory: repositoryRoot,
                    environment: environment)),
                .command(CommandSpec(
                    executable: .named("python3"),
                    arguments: [
                        skia.appending("tools/git-sync-deps").string,
                    ],
                    workingDirectory: root,
                    environment: environment)),
                .applyGitPatch(GitPatchApplication(
                    repository: skia,
                    patch: patch,
                    environment: environment)),
            ]))
    }

    public static func buildSkia(
        root: FilePath,
        environment: [String: String]
    ) -> TaskDeclaration {
        skiaTask(
            id: "core.skia.host",
            root: root,
            environment: environment,
            buildDirectory: root.appending(".skia-build/graphite"),
            gnArguments: hostGNArguments)
    }

    public static func buildSkiaAndroid(
        root: FilePath,
        environment: [String: String]
    ) -> TaskDeclaration {
        let ndk = androidNDKPath(environment)
        return skiaTask(
            id: "core.skia.android-arm64",
            root: root,
            environment: environment,
            buildDirectory: root.appending(".skia-build/android-arm64"),
            gnArguments: [
                #"target_os="android""#,
                #"target_cpu="arm64""#,
                #"ndk="\#(ndk)""#,
                "ndk_api=24",
                "skia_use_fontconfig=false",
            ] + commonGNArguments)
    }

    public static func buildAndroidHost(
        root: FilePath,
        sourceID: String,
        environment: [String: String],
        dependencies: [TaskID] = [TaskID(rawValue: "core.native-sdk")]
    ) -> TaskDeclaration {
        let package = root.appending("platform-android")
        let product = package.appending(
            ".build/out/Products/Release-android-aarch64/"
                + "libnucleus-android.so")
        return TaskDeclaration(
            id: TaskID(rawValue: "core.android-host.build"),
            component: ComponentID(rawValue: "core"),
            dependencies: dependencies,
            inputs: [
                .file(package.appending("Package.swift")),
                .tree(package.appending("c")),
                .tree(package.appending("swift-core")),
                .tree(package.appending("swift-jni")),
                .value(name: "swift-source-id", bytes: Array(sourceID.utf8)),
                .tool(.named("swift")),
            ],
            outputs: [
                OutputDeclaration(path: product, validation: .regularFile),
            ],
            locks: [.checkout("core-android-host")],
            operation: .command(CommandSpec(
                executable: .named("swift"),
                arguments: [
                    "build",
                    "--package-path", package.string,
                    "--swift-sdk", "swift-\(sourceID)_android",
                    "--static-swift-stdlib",
                    "-c", "release",
                ],
                workingDirectory: root,
                environment: environment)))
    }

    public static func validateAndroidHost(
        root: FilePath,
        library: FilePath? = nil,
        environment: [String: String],
        dependencies: [TaskID] = [TaskID(rawValue: "core.android-host.build")]
    ) -> TaskDeclaration {
        let hostLibrary = library ?? root.appending(
            "platform-android/.build/out/Products/"
                + "Release-android-aarch64/libnucleus-android.so")
        let kotlinContract = root.appending(
            "android/nucleus/src/main/kotlin/dev/nucleus/android/"
                + "NucleusNative.kt")
        let ndk = FilePath(androidNDKPath(environment))
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
            operation: .validateAndroidHost(AndroidHostValidation(
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
                .shared(sdkRoot.appending(".render.lock")),
            ],
            operation: .sequence(links.map {
                .replaceSymlink(
                    path: sdk.appending($0.0),
                    target: $0.1.string)
            }))
    }
}

private let androidNDKVersion = "30.0.14904198"
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
private let hostGNArguments = [
    "skia_use_partition_alloc=false",
    "skia_use_fontconfig=true",
    #"cc="clang""#,
    #"cxx="clang++""#,
] + commonGNArguments

private func androidNDKPath(_ environment: [String: String]) -> String {
    if let path = environment["NUCLEUS_ANDROID_NDK_HOME"] {
        return path
    }
    if let path = environment["ANDROID_NDK_HOME"] {
        return path
    }
    if let sdk = environment["ANDROID_SDK_ROOT"] ?? environment["ANDROID_HOME"] {
        return "\(sdk)/ndk/\(androidNDKVersion)"
    }
    if let home = environment["HOME"] {
        return "\(home)/Android/Sdk/ndk/\(androidNDKVersion)"
    }
    return "/Android/Sdk/ndk/\(androidNDKVersion)"
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
    gnArguments: [String]
) -> TaskDeclaration {
    let skia = root.appending("third-party/skia")
    return TaskDeclaration(
        id: TaskID(rawValue: id),
        component: ComponentID(rawValue: "core"),
        dependencies: [TaskID(rawValue: "core.sources")],
        inputs: [
            .file(root.appending("Package.swift")),
            .dependencyOutput(skia),
            .value(
                name: "gn-arguments",
                bytes: Array(gnArguments.joined(separator: "\u{0}").utf8)),
            .tool(.named("ninja")),
        ],
        outputs: requiredArchives.map {
            OutputDeclaration(
                path: buildDirectory.appending($0),
                validation: .regularFile)
        },
        locks: [.checkout("core-skia")],
        operation: .sequence([
            .command(CommandSpec(
                executable: .path(skia.appending("bin/gn")),
                arguments: [
                    "gen", buildDirectory.string,
                    "--args=" + gnArguments.joined(separator: " "),
                ],
                workingDirectory: skia,
                environment: environment)),
            .command(CommandSpec(
                executable: .named("ninja"),
                arguments: ["-C", buildDirectory.string] + ninjaTargets,
                workingDirectory: skia,
                environment: environment)),
        ]))
}

private func task(_ id: String, _ root: FilePath, _ environment: [String: String], _ arguments: [String], _ dependencies: [TaskID]) -> TaskDeclaration {
    TaskDeclaration(id: TaskID(rawValue: id), component: ComponentID(rawValue: "core"), dependencies: dependencies, inputs: [.file(root.appending("Package.swift")), .tree(root.appending("swift")), .tree(root.appending("render-cxx")), .tool(.named("swift"))], outputs: [OutputDeclaration(path: root.appending(".build"), validation: .nonEmptyDirectory)], locks: [.checkout("core")], operation: .command(CommandSpec(executable: .named("swift"), arguments: arguments, workingDirectory: root, environment: environment)))
}
