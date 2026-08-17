import ColliderCore
import ColliderPersistence
import ColliderRuntime
import SystemPackage

/// The single authoritative map from a Nucleus checkout root to paths owned or
/// consumed by Collider. Package recipes receive these resolved roots and own
/// their internal build layouts.
package struct WorkspaceLayout: Sendable {
    package let root: FilePath

    package init(root: FilePath) {
        self.root = root
    }

    package var state: FilePath { root.appending(".nucleus") }
    package var runtimeState: FilePath { state.appending("runtime") }
    func swiftScratch(
        for context: SwiftBuildContext,
        under scratchRoot: FilePath
    ) -> FilePath {
        let identity = ArtifactHasher.digest(bytes: context.identityBytes)
            .description
            .replacingOccurrences(of: ":", with: "-")
        return
            scratchRoot
            .appending(context.sanitizer ?? "unsanitized")
            .appending(identity)
    }
    package var developmentRuntimeCurrent: FilePath {
        runtimeState.appending("development-runtime/current")
    }

    var swiftSDK: FilePath { root.appending("swift-sdk") }
    var swiftTracy: FilePath { root.appending("swift-tracy") }
    var swiftVulkan: FilePath { root.appending("swift-vulkan") }
    var swiftWayland: FilePath { root.appending("swift-wayland") }
    var core: FilePath { root.appending("core") }
    var config: FilePath { root.appending("config") }
    var ipc: FilePath { root.appending("ipc") }
    var reactNative: FilePath { root.appending("react-native") }
    package var androidRuntime: FilePath { root.appending("android-runtime") }
    var chromium: FilePath { root.appending("chromium") }
    var platformLinux: FilePath { root.appending("platform-linux") }
    var platformLinuxDesktop: FilePath { platformLinux.appending("desktop") }
    var platformLinuxSession: FilePath { platformLinux.appending("session") }
    package var compositor: FilePath { root.appending("compositor") }
    var compositorCore: FilePath { compositor.appending("compositor-core") }
    var compositorApp: FilePath { compositor.appending("compositor") }
    package var compositorSessionPackage: FilePath {
        compositor.appending("packages").appending("session")
    }
    var shell: FilePath { root.appending("shell") }
    var tools: FilePath { root.appending("tools") }

    var tracyBuild: FilePath { compositor.appending(".tracy-build") }
}

extension WorkspaceContext {
    package var layout: WorkspaceLayout { WorkspaceLayout(root: root) }
}
