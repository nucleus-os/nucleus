import Foundation
import Testing

@testable import ColliderCommands

@Test func repositoryCachePrunesAbandonedCandidatesAndInactiveSwiftSDKGenerations() async throws {
    let workspace = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-storage-workspace-\(UUID().uuidString)", isDirectory: true)
    let cache = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-storage-cache-\(UUID().uuidString)", isDirectory: true)
    defer {
        try? FileManager.default.removeItem(at: workspace)
        try? FileManager.default.removeItem(at: cache)
    }
    try FileManager.default.createDirectory(
        at: workspace, withIntermediateDirectories: true)
    let generations = cache.appendingPathComponent(
        "nucleus/swift-target-sdks/generations", isDirectory: true)
    try FileManager.default.createDirectory(
        at: generations, withIntermediateDirectories: true)
    let candidate = generations.appendingPathComponent(
        ".candidate-1234567890abcdef12345678-2026-08-02T01-42-29Z-38631")
    let active = generations.appendingPathComponent("1234567890abcdef12345678")
    let inactive = generations.appendingPathComponent("abcdef1234567890abcdef12")
    let unrelated = generations.appendingPathComponent(".candidate-user-directory")
    for directory in [candidate, active, inactive, unrelated] {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try Data("payload".utf8).write(
            to: directory.appendingPathComponent("payload"))
    }
    try FileManager.default.createSymbolicLink(
        atPath: cache.appendingPathComponent(
            "nucleus/swift-target-sdks/current"
        ).path,
        withDestinationPath: "generations/\(active.lastPathComponent)")
    let context = WorkspaceContext(
        root: workspace,
        environment: [
            "HOME": workspace.path,
            "XDG_CACHE_HOME": cache.path,
            "NUCLEUS_NATIVE_SDK_ROOT": cache.appendingPathComponent(
                "nucleus/nucleus-native-sdk"
            ).path,
            "ANDROID_SDK_ROOT": cache.appendingPathComponent("android-sdk").path,
        ])

    try await RepositoryCache(context: context).prune(
        keepingRuns: 0,
        dryRun: false,
        json: true)

    #expect(!FileManager.default.fileExists(atPath: candidate.path))
    #expect(FileManager.default.fileExists(atPath: active.path))
    #expect(!FileManager.default.fileExists(atPath: inactive.path))
    #expect(FileManager.default.fileExists(atPath: unrelated.path))
}

@Test func apfsInventoryRejectsAmbiguousNamesWithoutLosingUniqueVolumes() throws {
    let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict><key>Containers</key><array>
          <dict><key>Volumes</key><array>
            <dict><key>Name</key><string>Recovery</string><key>CapacityInUse</key><integer>1</integer><key>CapacityQuota</key><integer>0</integer><key>CapacityReserve</key><integer>0</integer></dict>
            <dict><key>Name</key><string>NucleusCache</string><key>CapacityInUse</key><integer>2</integer><key>CapacityQuota</key><integer>350</integer><key>CapacityReserve</key><integer>0</integer></dict>
          </array></dict>
          <dict><key>Volumes</key><array>
            <dict><key>Name</key><string>Recovery</string><key>CapacityInUse</key><integer>3</integer><key>CapacityQuota</key><integer>0</integer><key>CapacityReserve</key><integer>0</integer></dict>
          </array></dict>
        </array></dict></plist>
        """

    let inventory = try APFSStorageInventory.decode(plist)

    #expect(inventory["Recovery"] == nil)
    #expect(inventory["NucleusCache"]?.capacityInUse == 2)
    #expect(inventory["NucleusCache"]?.capacityQuota == 350)
}
