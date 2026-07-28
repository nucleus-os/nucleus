import ColliderCore
import ColliderRuntime
import Foundation
import SystemPackage

/// The single authoritative map from a Nucleus checkout root to paths owned or
/// consumed by Collider. Package recipes receive these resolved roots and own
/// their internal build layouts.
struct WorkspaceLayout: Sendable {
    let root: URL

    var rootPath: FilePath { FilePath(root.path) }

    var state: URL {
        root.appendingPathComponent(".nucleus", isDirectory: true)
    }
    var runs: URL {
        state.appendingPathComponent("runs", isDirectory: true)
    }
    var tasks: URL {
        state.appendingPathComponent("tasks", isDirectory: true)
    }
    var runtimeState: URL {
        state.appendingPathComponent("runtime", isDirectory: true)
    }
    var locks: URL {
        state.appendingPathComponent("locks", isDirectory: true)
    }
    var work: URL {
        state.appendingPathComponent("work", isDirectory: true)
    }
    func swiftScratch(for context: SwiftBuildContext) -> URL {
        let identity = ArtifactHasher.digest(bytes: context.identityBytes)
            .description
            .replacingOccurrences(of: ":", with: "-")
        return state
            .appendingPathComponent("swiftpm", isDirectory: true)
            .appendingPathComponent(
                context.sanitizer ?? "unsanitized",
                isDirectory: true)
            .appendingPathComponent(identity, isDirectory: true)
    }
    var benchmarkBuilds: URL {
        state.appendingPathComponent(
            "benchmarks",
            isDirectory: true)
    }
    var nativeSanitizerBuilds: URL {
        state.appendingPathComponent(
            "native-sanitizers",
            isDirectory: true)
    }
    var androidPresentationQualifications: URL {
        state.appendingPathComponent(
            "qualifications/android-presentation",
            isDirectory: true)
    }
    var androidFrameworkFallbackRun: URL {
        state.appendingPathComponent(
            "android-framework-boot",
            isDirectory: true)
    }

    var installPrefix: URL {
        root.appendingPathComponent(".install", isDirectory: true)
    }

    var swiftToolchain: URL {
        root.appendingPathComponent("swift-toolchain", isDirectory: true)
    }
    var swiftTracy: URL {
        root.appendingPathComponent("swift-tracy", isDirectory: true)
    }
    var swiftVulkan: URL {
        root.appendingPathComponent("swift-vulkan", isDirectory: true)
    }
    var swiftWayland: URL {
        root.appendingPathComponent("swift-wayland", isDirectory: true)
    }
    var core: URL {
        root.appendingPathComponent("core", isDirectory: true)
    }
    var config: URL {
        root.appendingPathComponent("config", isDirectory: true)
    }
    var ipc: URL {
        root.appendingPathComponent("ipc", isDirectory: true)
    }
    var reactNative: URL {
        root.appendingPathComponent("react-native", isDirectory: true)
    }
    var androidRuntime: URL {
        root.appendingPathComponent("android-runtime", isDirectory: true)
    }
    var chromium: URL {
        root.appendingPathComponent("chromium", isDirectory: true)
    }
    var platformLinux: URL {
        root.appendingPathComponent("platform-linux", isDirectory: true)
    }
    var compositor: URL {
        root.appendingPathComponent("compositor", isDirectory: true)
    }
    var compositorCore: URL {
        compositor.appendingPathComponent(
            "compositor-core",
            isDirectory: true)
    }
    var compositorApp: URL {
        compositor.appendingPathComponent(
            "compositor",
            isDirectory: true)
    }
    var compositorSessionPackage: URL {
        compositor.appendingPathComponent(
            "packages/session",
            isDirectory: true)
    }
    var shell: URL {
        root.appendingPathComponent("shell", isDirectory: true)
    }
    var tools: URL {
        root.appendingPathComponent("tools", isDirectory: true)
    }

    var compositorInstallPrefix: URL {
        compositorApp.appendingPathComponent(".install", isDirectory: true)
    }
    var shellInstallPrefix: URL {
        shell.appendingPathComponent(".install", isDirectory: true)
    }
    var tracyBuild: URL {
        compositor.appendingPathComponent(".tracy-build", isDirectory: true)
    }
}

extension WorkspaceContext {
    var layout: WorkspaceLayout { WorkspaceLayout(root: root) }
}
