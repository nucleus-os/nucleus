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
