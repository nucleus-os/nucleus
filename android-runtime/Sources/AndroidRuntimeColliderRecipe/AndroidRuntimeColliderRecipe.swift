import ColliderCore
import Foundation
import SystemPackage

public enum AndroidRuntimeColliderRecipe {
    private static let component = ComponentID(rawValue: "android-runtime")

    public static func tasks(
        root: FilePath,
        repositoryRoot: FilePath,
        environment: [String: String]
    ) throws -> [TaskDeclaration] {
        [
            try gfxstream(
                root: root,
                repositoryRoot: repositoryRoot,
                environment: environment),
            build(root: root, environment: environment),
        ]
    }

    public static func test(
        root: FilePath,
        environment: [String: String]
    ) -> TaskDeclaration {
        swiftTask(
            id: "android-runtime.test",
            root: root,
            environment: environment,
            arguments: ["test"],
            dependencies: [TaskID(rawValue: "android-runtime.build")])
    }

    public static func verifyAOSPSourceLock(
        root: FilePath,
        environment: [String: String]
    ) throws -> TaskDeclaration {
        let lockPath = root.appending("aosp.lock.json")
        let script = root.appending("scripts/verify-aosp-source-lock")
        let launcher = try aospRepoLauncherPath(root: root)
        let report = root.appending(
            ".aosp-tools/source-lock-verification.json")
        let lock = try loadAOSPSourceLock(root: root)
        try lock.validate()
        return TaskDeclaration(
            id: TaskID(rawValue: "android-runtime.aosp-source-lock"),
            component: component,
            schemaVersion: 1,
            dependencies: [
                TaskID(rawValue: "android-runtime.aosp-repo-launcher"),
            ],
            inputs: [
                .file(lockPath),
                .file(script),
                .dependencyOutput(launcher),
                .tool(.named("git")),
                .tool(.named("python3")),
            ],
            outputs: [
                OutputDeclaration(path: report, validation: .json),
            ],
            locks: [.checkout("android-runtime-aosp-source-lock")],
            cachePolicy: .always,
            operation: .command(CommandSpec(
                executable: .named("python3"),
                arguments: [
                    script.string,
                    "--lock", lockPath.string,
                    "--repo-launcher", launcher.string,
                    "--output", report.string,
                ],
                workingDirectory: root,
                environment: environment)))
    }

    public static func aospSourceTasks(
        root: FilePath,
        environment: [String: String]
    ) throws -> [TaskDeclaration] {
        let launcher = try aospRepoLauncher(
            root: root,
            environment: environment)
        let verification = try verifyAOSPSourceLock(
            root: root,
            environment: environment)
        let source = try aospSource(
            root: root,
            environment: environment)
        return [launcher, verification, source]
    }

    private static func aospRepoLauncher(
        root: FilePath,
        environment _: [String: String]
    ) throws -> TaskDeclaration {
        let lock = try loadAOSPSourceLock(root: root)
        try lock.validate()
        guard let digest = ArtifactDigest(sha256Hex: lock.repo.launcherSHA256),
              let url = URL(string: lock.repo.launcherURL)
        else {
            throw AndroidRuntimeRecipeFailure.invalidAOSPSourceLock(
                "Repo launcher download specification is invalid")
        }
        let launcher = try aospRepoLauncherPath(root: root)
        let specification = try DownloadSpec(
            url: url,
            permittedRedirectOrigins: ["https://storage.googleapis.com"],
            expectedDigest: digest,
            maximumResponseSize: 2 * 1_024 * 1_024,
            acceptedMediaTypes: [
                "application/octet-stream",
                "text/plain",
            ])
        return TaskDeclaration(
            id: TaskID(rawValue: "android-runtime.aosp-repo-launcher"),
            component: component,
            schemaVersion: 1,
            inputs: [
                .file(root.appending("aosp.lock.json")),
            ],
            outputs: [
                OutputDeclaration(path: launcher, validation: .regularFile),
            ],
            locks: [.checkout("android-runtime-aosp-downloads")],
            operation: .download(specification, candidate: launcher))
    }

    private static func aospSource(
        root: FilePath,
        environment: [String: String]
    ) throws -> TaskDeclaration {
        let lock = try loadAOSPSourceLock(root: root)
        try lock.validate()
        let lockPath = root.appending("aosp.lock.json")
        let launcher = try aospRepoLauncherPath(root: root)
        let verification = root.appending(
            ".aosp-tools/source-lock-verification.json")
        let source = root.appending(".aosp-source")
        let script = root.appending("scripts/prepare-aosp-source")
        return TaskDeclaration(
            id: TaskID(rawValue: "android-runtime.aosp-source"),
            component: component,
            schemaVersion: 1,
            dependencies: [
                TaskID(rawValue: "android-runtime.aosp-repo-launcher"),
                TaskID(rawValue: "android-runtime.aosp-source-lock"),
            ],
            inputs: [
                .file(lockPath),
                .file(script),
                .dependencyOutput(launcher),
                .dependencyOutput(verification),
                .tool(.named("git")),
                .tool(.named("python3")),
            ],
            outputs: [
                OutputDeclaration(
                    path: source.appending(
                        ".nucleus/resolved-manifest.xml"),
                    validation: .regularFile),
                OutputDeclaration(
                    path: source.appending(".nucleus/source-provenance.json"),
                    validation: .json),
            ],
            locks: [.checkout("android-runtime-aosp-source")],
            operation: .command(CommandSpec(
                executable: .named("python3"),
                arguments: [
                    script.string,
                    "--lock", lockPath.string,
                    "--repo-launcher", launcher.string,
                    "--source", source.string,
                    "--minimum-free-gib", "400",
                ],
                workingDirectory: root,
                environment: environment)))
    }

    private static func loadAOSPSourceLock(
        root: FilePath
    ) throws -> AOSPSourceLock {
        try JSONDecoder().decode(
            AOSPSourceLock.self,
            from: Data(contentsOf: URL(
                fileURLWithPath: root.appending("aosp.lock.json").string)))
    }

    private static func aospRepoLauncherPath(
        root: FilePath
    ) throws -> FilePath {
        let lock = try loadAOSPSourceLock(root: root)
        try lock.validate()
        return root.appending(
            ".aosp-tools/repo-\(lock.repo.launcherVersion)")
    }

    private static func gfxstream(
        root: FilePath,
        repositoryRoot: FilePath,
        environment: [String: String]
    ) throws -> TaskDeclaration {
        let lockPath = root.appending("gfxstream.lock.json")
        let lock = try JSONDecoder().decode(
            GfxstreamLock.self,
            from: Data(contentsOf: URL(fileURLWithPath: lockPath.string)))
        let buildRoot = root.appending(".gfxstream-build")
        let hostSource = repositoryRoot.appending("third-party/gfxstream")
        let guestSource = repositoryRoot.appending("third-party/mesa")
        let hostBuild = buildRoot.appending("host")
        let guestBuild = buildRoot.appending("guest")
        guard let toolchain = environment["SWIFT_TOOLCHAIN"] else {
            throw AndroidRuntimeRecipeFailure.missingSwiftToolchain
        }
        let buildEnvironment = environment.merging([
            "CC": "\(toolchain)/bin/clang",
            "CXX": "\(toolchain)/bin/clang++",
            "LDFLAGS": "-Wl,-rpath,\(toolchain)/lib"
                + environment["LDFLAGS"].map { " \($0)" }.orEmpty,
        ]) { _, required in required }
        return TaskDeclaration(
            id: TaskID(rawValue: "android-runtime.gfxstream"),
            component: component,
            inputs: [
                .file(lockPath),
                .tree(hostSource),
                .tree(guestSource),
                .tool(.named("git")),
                .tool(.named("meson")),
            ],
            outputs: [
                OutputDeclaration(
                    path: buildRoot.appending("host/host/libgfxstream_backend.a"),
                    validation: .regularFile),
                OutputDeclaration(
                    path: buildRoot.appending(
                        "guest/src/gfxstream/guest/vulkan/libvulkan_gfxstream.so"),
                    validation: .regularFile),
            ],
            locks: [
                .checkout("android-runtime"),
                .checkout("gfxstream"),
                .checkout("mesa"),
            ],
            operation: .sequence([
                .validateGitCheckout(GitCheckoutValidation(
                    repository: hostSource,
                    expectedCommit: lock.gfxstream.commit,
                    environment: buildEnvironment)),
                .validateGitCheckout(GitCheckoutValidation(
                    repository: guestSource,
                    expectedCommit: lock.mesa.commit,
                    environment: buildEnvironment)),
                .configureMeson(MesonSetup(
                    source: hostSource,
                    build: hostBuild,
                    arguments: [
                        "-Dbuildtype=release",
                        "-Ddefault_library=static",
                        "-Ddecoders=gles,vulkan,composer",
                        "-Dgfxstream-build=host",
                    ],
                    environment: buildEnvironment)),
                .command(CommandSpec(
                    executable: .named("meson"),
                    arguments: [
                        "compile", "-C", hostBuild.string,
                        "gfxstream_backend",
                    ],
                    workingDirectory: root,
                    environment: buildEnvironment)),
                .configureMeson(MesonSetup(
                    source: guestSource,
                    build: guestBuild,
                    arguments: [
                        "-Dbuildtype=release",
                        "-Dvulkan-drivers=gfxstream",
                        "-Dgallium-drivers=[]",
                        "-Dplatforms=[]",
                        "-Dglx=disabled",
                        "-Degl=disabled",
                        "-Dgbm=disabled",
                        "-Dgles1=disabled",
                        "-Dgles2=disabled",
                        "-Dopengl=false",
                        "-Dllvm=disabled",
                        "-Dshared-glapi=disabled",
                        "-Dvalgrind=disabled",
                        "-Dlibunwind=disabled",
                        "-Dbuild-tests=false",
                        "-Dvideo-codecs=[]",
                        "-Dc_args=[]",
                        "-Dcpp_args=[]",
                    ],
                    environment: buildEnvironment)),
                .command(CommandSpec(
                    executable: .named("meson"),
                    arguments: [
                        "compile", "-C", guestBuild.string,
                        "vulkan_gfxstream",
                        "gfxstream_vk_icd",
                        "gfxstream_vk_devenv_icd",
                    ],
                    workingDirectory: root,
                    environment: buildEnvironment)),
            ]))
    }

    private static func build(
        root: FilePath,
        environment: [String: String]
    ) -> TaskDeclaration {
        swiftTask(
            id: "android-runtime.build",
            root: root,
            environment: environment,
            arguments: ["build"],
            dependencies: [
                TaskID(rawValue: "linux.build"),
                TaskID(rawValue: "android-runtime.gfxstream"),
            ])
    }

    private static func swiftTask(
        id: String,
        root: FilePath,
        environment: [String: String],
        arguments: [String],
        dependencies: [TaskID]
    ) -> TaskDeclaration {
        TaskDeclaration(
            id: TaskID(rawValue: id),
            component: component,
            dependencies: dependencies,
            inputs: [
                .file(root.appending("Package.swift")),
                .tree(root.appending("Sources")),
                .tree(root.appending("Tests")),
                .tool(.named("swift")),
            ],
            outputs: [
                OutputDeclaration(
                    path: root.appending(".build"),
                    validation: .nonEmptyDirectory),
            ],
            locks: [.checkout("android-runtime")],
            operation: .command(CommandSpec(
                executable: .named("swift"),
                arguments: arguments,
                workingDirectory: root,
                environment: environment)))
    }
}

private struct GfxstreamLock: Decodable {
    struct Checkout: Decodable { let commit: String }
    let gfxstream: Checkout
    let mesa: Checkout
}

private struct AOSPSourceLock: Decodable {
    struct Platform: Decodable {
        let revision: String
        let manifestURL: String
        let manifestTagObject: String
        let manifestCommit: String
        let defaultManifestSHA256: String
        let superprojectURL: String
        let superprojectRevision: String
        let superprojectCommit: String
    }

    struct Repo: Decodable {
        let launcherURL: String
        let launcherVersion: String
        let launcherSHA256: String
        let repositoryURL: String
        let revision: String
        let tagObject: String
        let commit: String
    }

    let schemaVersion: Int
    let platform: Platform
    let repo: Repo

    func validate() throws {
        guard schemaVersion == 1 else {
            throw AndroidRuntimeRecipeFailure.invalidAOSPSourceLock(
                "unsupported schema version \(schemaVersion)")
        }
        guard platform.revision == "refs/tags/android-17.0.0_r1" else {
            throw AndroidRuntimeRecipeFailure.invalidAOSPSourceLock(
                "platform revision must be refs/tags/android-17.0.0_r1")
        }
        guard platform.manifestURL
                == "https://android.googlesource.com/platform/manifest",
              platform.superprojectURL
                == "https://android.googlesource.com/platform/superproject",
              repo.launcherURL
                == "https://storage.googleapis.com/git-repo-downloads/repo",
              repo.repositoryURL
                == "https://gerrit.googlesource.com/git-repo"
        else {
            throw AndroidRuntimeRecipeFailure.invalidAOSPSourceLock(
                "source URLs do not match the approved upstreams")
        }
        for (name, value, count) in [
            ("manifest tag object", platform.manifestTagObject, 40),
            ("manifest commit", platform.manifestCommit, 40),
            ("manifest digest", platform.defaultManifestSHA256, 64),
            ("superproject commit", platform.superprojectCommit, 40),
            ("Repo launcher digest", repo.launcherSHA256, 64),
            ("Repo tag object", repo.tagObject, 40),
            ("Repo commit", repo.commit, 40),
        ] {
            guard value.utf8.count == count,
                  value.utf8.allSatisfy({ byte in
                      (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                          || (UInt8(ascii: "a")...UInt8(ascii: "f"))
                              .contains(byte)
                  })
            else {
                throw AndroidRuntimeRecipeFailure.invalidAOSPSourceLock(
                    "\(name) must be \(count) lowercase hexadecimal digits")
            }
        }
        guard repo.revision == "refs/tags/v\(repo.launcherVersion)" else {
            throw AndroidRuntimeRecipeFailure.invalidAOSPSourceLock(
                "Repo revision and launcher version disagree")
        }
    }
}

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}

public enum AndroidRuntimeRecipeFailure: Error, CustomStringConvertible {
    case invalidAOSPSourceLock(String)
    case missingSwiftToolchain

    public var description: String {
        switch self {
        case .invalidAOSPSourceLock(let detail):
            "invalid AOSP source lock: \(detail)"
        case .missingSwiftToolchain:
            "SWIFT_TOOLCHAIN is required to build gfxstream"
        }
    }
}
