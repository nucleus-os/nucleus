import Foundation

enum WorkspaceComponent: String, CaseIterable, Hashable, Sendable {
    case tracy
    case vulkan
    case wayland
    case core
    case rn
    case compositor
    case shell

    var directoryName: String {
        switch self {
        case .tracy: "swift-tracy"
        case .vulkan: "swift-vulkan"
        case .wayland: "swift-wayland"
        case .core: "core"
        case .rn: "react-native"
        case .compositor: "compositor"
        case .shell: "shell"
        }
    }
}

struct Orchestrator {
    let context: WorkspaceContext

    func bootstrap(_ selection: String?) throws {
        let selected = try components(selection)
        if !Set(selected).isDisjoint(with: [.tracy, .core, .rn, .compositor, .shell]) {
            try context.run(
                "git",
                ["submodule", "update", "--init", "--recursive", "swift-tracy/third-party/tracy"],
                directory: context.root
            )
        }
        let runtimeComponents = Set(selected).intersection([.core, .rn, .compositor, .shell])
        if runtimeComponents.isEmpty {
            for component in selected {
                print("==> resolve \(component.rawValue)")
                try context.run("swift", ["package", "resolve"], directory: context.repository(component.directoryName))
            }
            return
        }
        try StageEngine(context: context).execute(bootstrapStages(for: Set(selected)))
    }

    private func bootstrapStages(for selected: Set<WorkspaceComponent>) -> [BootstrapStage] {
        let core = context.repository("core")
        let rn = context.repository("react-native")
        let shell = context.repository("shell")
        let needsCore = !selected.isDisjoint(with: [.core, .rn, .compositor, .shell])
        let needsRN = !selected.isDisjoint(with: [.rn, .shell])
        var stages: [BootstrapStage] = []

        if needsCore {
            stages.append(BootstrapStage(name: "core-source-sync", inputs: [
                "core/third-party/sync-deps.sh",
                "core/third-party/libxkbcommon", "core/third-party/skia",
                "core/third-party/swift-system", "third-party/swift-java", "third-party/swift-java-jni-core",
            ], outputs: ["core/third-party/skia/.git", "third-party/swift-java/.git"], run: {
                try context.run("third-party/sync-deps.sh", [], directory: core)
                try context.run("git", ["submodule", "update", "--init", "--recursive", "core/third-party", "third-party/swift-java", "third-party/swift-java-jni-core"], directory: context.root)
            }))
            stages.append(BootstrapStage(name: "dawn-generation", inputs: ["core"], outputs: ["core/build_zig/generated/dawn_gen/include"], run: {
                try context.run("swift", ["package", "generate-dawn", "--allow-writing-to-package-directory"], directory: core)
            }))
            stages.append(BootstrapStage(name: "render-sdk", inputs: ["core"], outputs: ["core/.skia-build/graphite/libskia.a"], run: {
                try context.run("swift", ["package", "build-skia", "--allow-writing-to-package-directory"], directory: core)
            }))
        }

        if needsRN {
            stages.append(BootstrapStage(name: "rn-source-sync", inputs: [
                "react-native/third-party/double-conversion", "react-native/third-party/fast_float",
                "react-native/third-party/fmt", "react-native/third-party/folly", "react-native/third-party/glog",
                "react-native/third-party/hermes", "react-native/third-party/react-native",
            ], outputs: ["react-native/third-party/react-native/.git", "react-native/third-party/boost/version.hpp"], run: {
                try context.run("git", ["submodule", "update", "--init", "--recursive", "react-native/third-party"], directory: context.root)
                try provisionBoost(in: rn)
                try context.run("corepack", ["yarn", "--cwd", "third-party/react-native", "install", "--frozen-lockfile"], directory: rn)
            }))
            stages.append(BootstrapStage(name: "rn-codegen", inputs: ["react-native"], outputs: ["react-native/.rn-build/generated/FBReactNativeSpec/FBReactNativeSpecJSI.h"], run: {
                try context.run("swift", ["package", "generate-rn-spec", "--allow-writing-to-package-directory"], directory: rn)
            }))
            stages.append(BootstrapStage(name: "rn-sdk", inputs: ["react-native"], outputs: ["react-native/.rn-build/reactnative/libreact_native.a", "react-native/.cxx-build/debug/libNucleusReactRuntimeHostCxx.a"], run: {
                for command in ["build-hermes", "build-rn-support", "build-rn-cxx"] { try context.run("swift", ["package", command, "--allow-writing-to-package-directory"], directory: rn) }
                try context.run("swift", ["build", "--target", "NucleusReactRuntimeCxx"], directory: rn)
                try context.run("swift", ["build"], directory: rn)
                try context.run("swift", ["package", "provision-cxx-libs", "--allow-writing-to-package-directory"], directory: rn)
            }))
        }

        let buildInputs = selected.map(\.directoryName).sorted()
        stages.append(BootstrapStage(name: "swift-products-" + selected.map(\.rawValue).sorted().joined(separator: "-"), inputs: buildInputs, outputs: buildOutputs(for: selected), run: {
            for component in WorkspaceComponent.allCases where selected.contains(component) { try build(component.rawValue) }
        }))

        if selected.contains(.shell) {
            stages.append(BootstrapStage(name: "js-bundles", inputs: ["shell"], outputs: ["shell/.rn-build/bundles/bar.hbc"], run: {
                try context.run("bun", ["install", "--cwd", "js", "--frozen-lockfile"], directory: shell)
                try context.run("swift", ["package", "build-shell-bundle", "--allow-writing-to-package-directory"], directory: shell)
            }))
        }
        return stages
    }

    private func buildOutputs(for selected: Set<WorkspaceComponent>) -> [String] {
        selected.map { component in
            switch component {
            case .compositor: "compositor/compositor-core/.build/out"
            default: component.directoryName + "/.build/out"
            }
        }
    }

    private func provisionBoost(in rn: URL) throws {
        let manager = FileManager.default
        let destination = rn.appendingPathComponent("third-party/boost")
        if !manager.fileExists(atPath: destination.appendingPathComponent("version.hpp").path) {
            let temporary = manager.temporaryDirectory.appendingPathComponent("nucleus-boost-" + UUID().uuidString)
            try manager.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? manager.removeItem(at: temporary) }
            let archive = temporary.appendingPathComponent("boost.tar.gz")
            try context.run("curl", ["-fsSL", "https://archives.boost.io/release/1.84.0/source/boost_1_84_0.tar.gz", "-o", archive.path])
            try context.run("tar", ["xzf", archive.path, "-C", temporary.path])
            try manager.createDirectory(at: destination, withIntermediateDirectories: true)
            for item in try manager.contentsOfDirectory(atPath: temporary.appendingPathComponent("boost_1_84_0/boost").path) {
                let target = destination.appendingPathComponent(item)
                if manager.fileExists(atPath: target.path) { try manager.removeItem(at: target) }
                try manager.copyItem(at: temporary.appendingPathComponent("boost_1_84_0/boost/" + item), to: target)
            }
        }
        let compatibilityLink = destination.appendingPathComponent("boost")
        if !manager.fileExists(atPath: compatibilityLink.path) {
            try manager.createSymbolicLink(atPath: compatibilityLink.path, withDestinationPath: ".")
        }
    }

    func build(_ selection: String?) throws {
        for component in try components(selection) {
            print("==> build \(component.rawValue)")
            switch component {
            case .tracy, .vulkan, .wayland:
                try context.run("swift", ["build"], directory: context.repository(component.directoryName))
            case .core:
                try context.run("swift", ["build"], directory: context.repository(component.directoryName))
            case .rn:
                try context.run("swift", ["build", "--target", "NucleusReactRuntimeCxx"], directory: context.repository(component.directoryName))
                try context.run("swift", ["build"], directory: context.repository(component.directoryName))
            case .compositor:
                let directory = context.repository(component.directoryName)
                try context.run("swift", ["build", "--package-path", "compositor-core"], directory: directory)
                try context.run("swift", ["build", "--package-path", "compositor"], directory: directory)
            case .shell:
                try context.run("swift", ["build"], directory: context.repository(component.directoryName))
            }
        }
    }

    func test(_ selection: String?) throws {
        for component in try components(selection) {
            print("==> test \(component.rawValue)")
            let directory = context.repository(component.directoryName)
            switch component {
            case .tracy, .wayland:
                try context.run("swift", ["test", "-Xswiftc", "-cxx-interoperability-mode=default"], directory: directory)
            case .vulkan:
                try context.run("swift", ["test"], directory: directory)
            case .core, .rn:
                try context.run("swift", ["test", "-Xswiftc", "-cxx-interoperability-mode=default"], directory: directory)
            case .compositor:
                try context.run("swift", ["test", "--package-path", "compositor-core", "-Xswiftc", "-cxx-interoperability-mode=default"], directory: directory)
            case .shell:
                try context.run("swift", ["build"], directory: directory)
            }
        }
    }

    private func components(_ selection: String?) throws -> [WorkspaceComponent] {
        guard let selection, selection != "all" else { return WorkspaceComponent.allCases }
        guard let component = WorkspaceComponent(rawValue: selection) else {
            throw WorkspaceFailure.message("unknown component '\(selection)'; expected all, tracy, vulkan, wayland, core, rn, compositor, or shell")
        }
        return [component]
    }
}
