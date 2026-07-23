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

private extension Optional where Wrapped == String {
    var orEmpty: String { self ?? "" }
}

public enum AndroidRuntimeRecipeFailure: Error, CustomStringConvertible {
    case missingSwiftToolchain

    public var description: String {
        switch self {
        case .missingSwiftToolchain:
            "SWIFT_TOOLCHAIN is required to build gfxstream"
        }
    }
}
