import ColliderCore
import ColliderPersistence
import ColliderRuntime
import SystemPackage

/// The single authoritative map from a Nucleus checkout root to paths owned or
/// consumed by Collider. Package recipes receive these resolved roots and own
/// their internal build layouts.
struct WorkspaceLayout: Sendable {
    let root: FilePath

    var state: FilePath { root.appending(".nucleus") }
    var runs: FilePath { state.appending("runs") }
    var tasks: FilePath { state.appending("tasks") }
    var runtimeState: FilePath { state.appending("runtime") }
    var androidAddonStore: FilePath { runtimeState.appending("android-addon") }
    var androidPersistentState: FilePath { runtimeState.appending("android-state") }
    var locks: FilePath { state.appending("locks") }
    var work: FilePath { state.appending("work") }
    func swiftScratch(for context: SwiftBuildContext) -> FilePath {
        let identity = ArtifactHasher.digest(bytes: context.identityBytes)
            .description
            .replacingOccurrences(of: ":", with: "-")
        return state.appending("swiftpm")
            .appending(context.sanitizer ?? "unsanitized")
            .appending(identity)
    }
    var benchmarkBuilds: FilePath { state.appending("benchmarks") }
    var nativeSanitizerBuilds: FilePath { state.appending("native-sanitizers") }
    var installPrefix: FilePath { root.appending(".install") }

    var swiftSDK: FilePath { root.appending("swift-sdk") }
    var swiftTracy: FilePath { root.appending("swift-tracy") }
    var swiftVulkan: FilePath { root.appending("swift-vulkan") }
    var swiftWayland: FilePath { root.appending("swift-wayland") }
    var core: FilePath { root.appending("core") }
    var config: FilePath { root.appending("config") }
    var ipc: FilePath { root.appending("ipc") }
    var reactNative: FilePath { root.appending("react-native") }
    var androidRuntime: FilePath { root.appending("android-runtime") }
    var chromium: FilePath { root.appending("chromium") }
    var platformLinux: FilePath { root.appending("platform-linux") }
    var platformLinuxDesktop: FilePath { platformLinux.appending("desktop") }
    var platformLinuxSession: FilePath { platformLinux.appending("session") }
    var compositor: FilePath { root.appending("compositor") }
    var compositorCore: FilePath { compositor.appending("compositor-core") }
    var compositorApp: FilePath { compositor.appending("compositor") }
    var compositorSessionPackage: FilePath {
        compositor.appending("packages").appending("session")
    }
    var shell: FilePath { root.appending("shell") }
    var tools: FilePath { root.appending("tools") }

    var tracyBuild: FilePath { compositor.appending(".tracy-build") }
}

extension WorkspaceContext {
    var layout: WorkspaceLayout { WorkspaceLayout(root: root) }
}
