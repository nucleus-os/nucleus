import Foundation
import NucleusAndroidRuntimeCore

struct AndroidAddonInstallCommand {
    func install(
        artifact: URL,
        trustKey: URL,
        basePrefix: URL,
        storeRoot: URL,
        persistentStateRoot: URL
    ) throws {
        try AndroidAddonManager(
            basePrefix: basePrefix,
            storeRoot: storeRoot,
            persistentStateRoot: persistentStateRoot,
            trustKey: trustKey
        ).install(artifact: artifact)
    }

    func deactivate(storeRoot: URL, persistentStateRoot: URL) throws {
        try AndroidAddonManager(
            basePrefix: URL(fileURLWithPath: "/", isDirectory: true),
            storeRoot: storeRoot,
            persistentStateRoot: persistentStateRoot
        ).deactivate()
    }

    func uninstall(storeRoot: URL, persistentStateRoot: URL) throws {
        try AndroidAddonManager(
            basePrefix: URL(fileURLWithPath: "/", isDirectory: true),
            storeRoot: storeRoot,
            persistentStateRoot: persistentStateRoot
        ).uninstall()
    }
}
