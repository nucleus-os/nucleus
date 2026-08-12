import Foundation
import SystemPackage

/// The conventional per-user macOS storage owned by Collider.
///
/// This layout contains no checkout identity, custom-volume policy, or legacy
/// path fallback. Every macOS Collider consumer resolves through these roots.
package struct MacOSHostStorageLayout: Equatable, Sendable {
    package let applicationSupportRoot: FilePath
    package let developerRoot: FilePath
    package let cacheRoot: FilePath
    package let logsRoot: FilePath
    package let launchAgentsDirectory: FilePath

    package init(homeDirectory: FilePath) {
        self.init(
            homeDirectory: homeDirectory,
            applicationSupportDirectory: homeDirectory.appending(
                "Library/Application Support"),
            cachesDirectory: homeDirectory.appending("Library/Caches"),
            libraryDirectory: homeDirectory.appending("Library"))
    }

    package init(
        homeDirectory: FilePath,
        applicationSupportDirectory: FilePath,
        cachesDirectory: FilePath,
        libraryDirectory: FilePath
    ) {
        applicationSupportRoot = applicationSupportDirectory.appending(
            "Nucleus/Collider")
        developerRoot = homeDirectory.appending("Library/Developer/Nucleus/Collider")
        cacheRoot = cachesDirectory.appending("Nucleus/Collider")
        logsRoot = libraryDirectory.appending("Logs/Nucleus/Collider")
        launchAgentsDirectory = libraryDirectory.appending("LaunchAgents")
    }

    package static func current(
        fileManager: FileManager = .default
    ) throws -> MacOSHostStorageLayout {
        let homeDirectory = FilePath(fileManager.homeDirectoryForCurrentUser.path)
        let applicationSupportDirectory = try FilePath(
            fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            ).path)
        let cachesDirectory = try FilePath(
            fileManager.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            ).path)
        let libraryDirectory = try FilePath(
            fileManager.url(
                for: .libraryDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            ).path)
        return MacOSHostStorageLayout(
            homeDirectory: homeDirectory,
            applicationSupportDirectory: applicationSupportDirectory,
            cachesDirectory: cachesDirectory,
            libraryDirectory: libraryDirectory)
    }

    package var serviceSupport: FilePath {
        applicationSupportRoot.appending("service")
    }

    package var containerServiceStarter: FilePath {
        serviceSupport.appending("container-system-start")
    }

    package func launchAgentPlist(label: String) -> FilePath {
        launchAgentsDirectory.appending("\(label).plist")
    }

    package var appleContainerApplicationRoot: FilePath {
        developerRoot.appending("apple-container")
    }

    package var appleContainerVolumes: FilePath {
        appleContainerApplicationRoot.appending("volumes")
    }

    package var hostBuildState: FilePath {
        developerRoot.appending("build")
    }

    package var artifacts: FilePath {
        developerRoot.appending("artifacts")
    }

    package var downloads: FilePath {
        cacheRoot.appending("downloads")
    }

    package var nativeSDKs: FilePath {
        cacheRoot.appending("native-sdks")
    }

    package var androidSDKs: FilePath {
        cacheRoot.appending("android-sdks")
    }

    package var runLogs: FilePath {
        logsRoot.appending("runs")
    }

    package var serviceLogs: FilePath {
        logsRoot.appending("service")
    }

    package var containerServiceStandardOutput: FilePath {
        serviceLogs.appending("apple-container-apiserver.log")
    }

    package var containerServiceStandardError: FilePath {
        serviceLogs.appending("apple-container-apiserver.error.log")
    }
}
