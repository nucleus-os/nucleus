import ColliderCore
import SystemPackage

public enum CompositorColliderRecipe {
    public static func build(
        root: FilePath,
        environment: [String: String]
    ) -> TaskDeclaration {
        packageTask(
            "compositor-core.build", root, environment, ["build"],
            [
                TaskID(rawValue: "rn.build"),
            ],
            isTest: false)
    }

    public static func test(
        root: FilePath,
        environment: [String: String]
    ) -> TaskDeclaration {
        packageTask(
            "compositor-core.test", root, environment,
            ["test", "--skip", "gpu(Loader|Headless|DRM)_"],
            [TaskID(rawValue: "compositor-core.build")], isTest: true)
    }

    public static func testVulkanLoader(
        root: FilePath,
        environment: [String: String]
    ) -> TaskDeclaration {
        packageTask(
            "compositor-core.test-loader", root, environment,
            ["test", "--filter", "gpuLoader_"],
            [TaskID(rawValue: "compositor-core.preflight-loader")],
            isTest: true)
    }

    public static func preflightVulkanLoader(
        root: FilePath,
        environment: [String: String]
    ) -> TaskDeclaration {
        preflightTask(
            "compositor-core.preflight-loader", root, environment, "loader",
            [TaskID(rawValue: "compositor-core.build")])
    }

    public static func testHeadlessGPU(
        root: FilePath,
        environment: [String: String]
    ) -> TaskDeclaration {
        packageTask(
            "compositor-core.test-gpu-headless", root, environment,
            ["test", "--filter", "gpuHeadless_"],
            [TaskID(rawValue: "compositor-core.preflight-gpu-headless")],
            isTest: true)
    }

    public static func preflightHeadlessGPU(
        root: FilePath,
        environment: [String: String],
        lavapipeTask: TaskID
    ) -> TaskDeclaration {
        preflightTask(
            "compositor-core.preflight-gpu-headless", root, environment,
            "gpu-headless",
            [TaskID(rawValue: "compositor-core.build"), lavapipeTask])
    }

    public static func testDRMGPU(
        root: FilePath,
        environment: [String: String]
    ) -> TaskDeclaration {
        packageTask(
            "compositor-core.test-gpu-drm", root, environment,
            ["test", "--filter", "gpuDRM_"],
            [TaskID(rawValue: "compositor-core.preflight-gpu-drm")],
            isTest: true)
    }

    public static func preflightDRMGPU(
        root: FilePath,
        environment: [String: String]
    ) -> TaskDeclaration {
        preflightTask(
            "compositor-core.preflight-gpu-drm", root, environment, "gpu-drm",
            [TaskID(rawValue: "compositor-core.build")])
    }
}

private func preflightTask(
    _ id: String,
    _ root: FilePath,
    _ environment: [String: String],
    _ lane: String,
    _ dependencies: [TaskID]
) -> TaskDeclaration {
    TaskDeclaration(
        id: TaskID(rawValue: id),
        component: ComponentID(rawValue: "compositor"),
        dependencies: dependencies,
        inputs: [
            .file(root.appending("Package.swift")),
            .tree(root.appending("Sources")),
            .tool(.named("swift")),
        ],
        outputs: [],
        locks: [.checkout("compositor-core")],
        cachePolicy: .always,
        operation: .command(CommandSpec(
            executable: .named("swift"),
            arguments: ["run", "NucleusVulkanLaneProbe", lane],
            workingDirectory: root,
            environment: environment)))
}

private func packageTask(
    _ id: String,
    _ root: FilePath,
    _ environment: [String: String],
    _ arguments: [String],
    _ dependencies: [TaskID],
    isTest: Bool
) -> TaskDeclaration {
    TaskDeclaration(
        id: TaskID(rawValue: id),
        component: ComponentID(rawValue: "compositor"),
        dependencies: dependencies,
        inputs: [
            .file(root.appending("Package.swift")),
            .tree(root.appending("Sources")),
        ] + (isTest ? [.tree(root.appending("Tests"))] : [])
            + [.tool(.named("swift"))],
        outputs: isTest
            ? []
            : [OutputDeclaration(
                path: root.appending(".build"),
                validation: .nonEmptyDirectory)],
        locks: [.checkout("compositor-core")],
        cachePolicy: isTest ? .always : .contentAddressed,
        operation: .command(CommandSpec(
            executable: .named("swift"),
            arguments: arguments,
            workingDirectory: root,
            environment: environment)))
}
