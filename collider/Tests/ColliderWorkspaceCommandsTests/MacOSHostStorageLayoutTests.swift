import SystemPackage
import Testing

@testable import ColliderWorkspaceCommands

@Test
func macOSHostStorageLayoutUsesConventionalUserDirectories() {
    let layout = MacOSHostStorageLayout(
        homeDirectory: FilePath("/Users/Developer With Spaces"))

    #expect(
        layout.applicationSupportRoot
            == FilePath(
                "/Users/Developer With Spaces/Library/Application Support/Nucleus/Collider"))
    #expect(
        layout.developerRoot
            == FilePath("/Users/Developer With Spaces/Library/Developer/Nucleus/Collider"))
    #expect(
        layout.cacheRoot
            == FilePath("/Users/Developer With Spaces/Library/Caches/Nucleus/Collider"))
    #expect(
        layout.logsRoot
            == FilePath("/Users/Developer With Spaces/Library/Logs/Nucleus/Collider"))
    #expect(
        layout.launchAgentsDirectory
            == FilePath("/Users/Developer With Spaces/Library/LaunchAgents"))

    #expect(layout.serviceSupport == layout.applicationSupportRoot.appending("service"))
    #expect(
        layout.containerServiceStarter
            == layout.serviceSupport.appending("container-system-start"))
    #expect(
        layout.launchAgentPlist(label: "com.nucleus.container-system-start")
            == layout.launchAgentsDirectory.appending(
                "com.nucleus.container-system-start.plist"))
    #expect(
        layout.appleContainerApplicationRoot
            == layout.developerRoot.appending("apple-container"))
    #expect(
        layout.appleContainerVolumes
            == layout.appleContainerApplicationRoot.appending("volumes"))
    #expect(layout.hostBuildState == layout.developerRoot.appending("build"))
    #expect(layout.artifacts == layout.developerRoot.appending("artifacts"))
    #expect(layout.downloads == layout.cacheRoot.appending("downloads"))
    #expect(layout.nativeSDKs == layout.cacheRoot.appending("native-sdks"))
    #expect(layout.androidSDKs == layout.cacheRoot.appending("android-sdks"))
    #expect(layout.runLogs == layout.logsRoot.appending("runs"))
    #expect(layout.serviceLogs == layout.logsRoot.appending("service"))
    #expect(
        layout.containerServiceStandardOutput
            == layout.serviceLogs.appending("apple-container-apiserver.log"))
    #expect(
        layout.containerServiceStandardError
            == layout.serviceLogs.appending("apple-container-apiserver.error.log"))
}

/// Two accounts execute on a provisioned host, so the state they share resolves
/// outside both homes. Launch agents do not: a launchd agent belongs to a login
/// session rather than to the data it manages.
@Test
func machineBuildStoreSupersedesPerUserDataRootsButNotLaunchAgents() {
    let store = MacOSHostStorageLayout(
        buildStore: FilePath("/Library/Nucleus/Collider"),
        libraryDirectory: FilePath("/Users/fixture/Library"))

    #expect(store.developerRoot == FilePath("/Library/Nucleus/Collider/state"))
    #expect(store.cacheRoot == FilePath("/Library/Nucleus/Collider/cache"))
    #expect(store.logsRoot == FilePath("/Library/Nucleus/Collider/logs"))
    #expect(
        store.applicationSupportRoot == FilePath("/Library/Nucleus/Collider/configuration"))
    #expect(
        store.appleContainerApplicationRoot
            == FilePath("/Library/Nucleus/Collider/state/apple-container"))
    #expect(store.launchAgentsDirectory == FilePath("/Users/fixture/Library/LaunchAgents"))

    // No data root may resolve back into a home once a store exists, or the two
    // accounts stop sharing the warm state the store exists to share.
    for root in [
        store.developerRoot, store.cacheRoot, store.logsRoot, store.applicationSupportRoot,
    ] {
        #expect(!root.starts(with: FilePath("/Users")))
    }
}

/// Warm state is shared between the CI checkout and the authoritative checkout
/// only if both select the same volumes, which is decided by this value alone.
@Test
func persistentWorkspaceOwnerFollowsTheStoreRatherThanTheCheckout() {
    let store = FilePath("/Library/Nucleus/Collider")
    let ciCheckout = FilePath("/Users/nucleus-builder/actions-runner-work/nucleus/nucleus")
    let authoritative = FilePath("/Users/maddy/Developer/nucleus")

    #expect(
        nucleusPersistentWorkspaceOwner(workspaceRoot: ciCheckout, buildStore: store)
            == nucleusPersistentWorkspaceOwner(
                workspaceRoot: authoritative, buildStore: store))
    // Without a store nothing is shared, so each checkout owns its own.
    #expect(
        nucleusPersistentWorkspaceOwner(workspaceRoot: ciCheckout, buildStore: nil)
            != nucleusPersistentWorkspaceOwner(
                workspaceRoot: authoritative, buildStore: nil))
    // Volume names carry this value, so it stays a digest: two domains sharing
    // one application root must not collide on name while their labels differ.
    let owner = nucleusPersistentWorkspaceOwner(
        workspaceRoot: authoritative, buildStore: store)
    let isHexadecimal = owner.allSatisfy { $0.isHexDigit }
    #expect(owner.count == 64)
    #expect(isHexadecimal)
}

/// The migration renames every existing volume to this exact value, computed in
/// shell from the same path. If the two ever disagree, a terabyte of warm state
/// becomes invisible rather than adopted, so the crossing point is pinned here.
@Test
func buildStoreWorkspaceOwnerIsStableAcrossLanguages() {
    #expect(
        nucleusPersistentWorkspaceOwner(
            workspaceRoot: FilePath("/any/checkout"),
            buildStore: MacOSMachineStorageLayout.buildStore)
            == "bc6d2c59588b3c9a1018f35be10bb546ad43c7dfefadce2c1fc50451b2f16103")
}
