import NucleusAndroidRuntimeCore
import Testing
@testable import ColliderCommands

@Test
func frameworkBootUsesTheDedicatedAndroidApexMountHelper() throws {
    let invocation = AndroidApexMountInvocation(
        helperExecutable:
            "/workspace/.build/release/"
            + "nucleus-android-runtime-privileged",
        rootFileSystem:
            "/run/nucleus/android/nucleus-framework-3970820/rootfs",
        source: "/system/apex/com.android.runtime.apex",
        target: "/apex/com.android.runtime@370399999",
        payloadFileSystem: .erofs,
        payloadOffset: 4_096)

    #expect(invocation.executable == "sudo")
    #expect(invocation.arguments == [
        "--non-interactive",
        "/workspace/.build/release/nucleus-android-runtime-privileged",
        "__android-apex-mount",
        "--root-file-system",
        "/run/nucleus/android/nucleus-framework-3970820/rootfs",
        "--source",
        "/system/apex/com.android.runtime.apex",
        "--target",
        "/apex/com.android.runtime@370399999",
        "--payload-file-system",
        "erofs",
        "--payload-offset",
        "4096",
    ])
}
