#if os(Linux)
import NucleusAndroidRuntimeCore
import Testing

@Test
func androidRuntimeUsesTheDedicatedAndroidApexMountHelper() throws {
    let invocation = AndroidApexMountInvocation(
        helperExecutable:
            "/workspace/.build/release/"
            + "nucleus-android-runtime-privileged",
        rootFileSystem:
            "/run/nucleus/android/nucleus-android-runtime-3970820/rootfs",
        source: "/system/apex/com.android.runtime.apex",
        target: "/apex/com.android.runtime@370399999",
        payloadFileSystem: .erofs,
        payloadOffset: 4_096)

    #expect(invocation.executable == "sudo")
    #expect(
        invocation.arguments == [
            "--non-interactive",
            "/workspace/.build/release/nucleus-android-runtime-privileged",
            "__android-apex-mount",
            "--root-file-system",
            "/run/nucleus/android/nucleus-android-runtime-3970820/rootfs",
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
#endif
