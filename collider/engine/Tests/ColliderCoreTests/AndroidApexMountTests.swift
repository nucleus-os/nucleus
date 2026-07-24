import ColliderRuntime
import Testing

@Test
func androidApexMountRequestAcceptsTheContainedFrameworkLayout() throws {
    let request = try AndroidApexMountRequest(
        rootFileSystem:
            "/run/nucleus/android/nucleus-framework-3970820/rootfs",
        source: "/system/apex/com.android.runtime.apex",
        target: "/apex/com.android.runtime@370399999",
        payloadFileSystem: .erofs,
        payloadOffset: 4_096)

    #expect(
        request.rootFileSystem
            == "/run/nucleus/android/nucleus-framework-3970820/rootfs")
    #expect(request.source == "/system/apex/com.android.runtime.apex")
    #expect(request.target == "/apex/com.android.runtime@370399999")
    #expect(request.payloadFileSystem == .erofs)
    #expect(request.payloadOffset == 4_096)
}

@Test
func androidApexMountRequestRejectsPathsOutsideItsPrivilegeBoundary() {
    #expect(throws: AndroidApexMountFailure.self) {
        try AndroidApexMountRequest(
            rootFileSystem: "/",
            source: "/system/apex/com.android.runtime.apex",
            target: "/apex/com.android.runtime@370399999",
            payloadFileSystem: .erofs,
            payloadOffset: 4_096)
    }
    #expect(throws: AndroidApexMountFailure.self) {
        try AndroidApexMountRequest(
            rootFileSystem:
                "/run/nucleus/android/nucleus-framework-1/rootfs",
            source: "/system/apex/../com.android.runtime.apex",
            target: "/apex/com.android.runtime@370399999",
            payloadFileSystem: .erofs,
            payloadOffset: 4_096)
    }
    #expect(throws: AndroidApexMountFailure.self) {
        try AndroidApexMountRequest(
            rootFileSystem:
                "/run/nucleus/android/nucleus-framework-1/rootfs",
            source: "/system/apex/com.android.runtime.apex",
            target: "/system/com.android.runtime@370399999",
            payloadFileSystem: .erofs,
            payloadOffset: 4_096)
    }
}

@Test
func androidApexMountRequestAcceptsTheStockExt4CtsShim() throws {
    let request = try AndroidApexMountRequest(
        rootFileSystem:
            "/run/nucleus/android/nucleus-framework-1/rootfs",
        source: "/system/apex/com.android.apex.cts.shim.apex",
        target: "/apex/com.android.apex.cts.shim@1",
        payloadFileSystem: .ext4,
        payloadOffset: 4_096)

    #expect(request.source == "/system/apex/com.android.apex.cts.shim.apex")
    #expect(request.target == "/apex/com.android.apex.cts.shim@1")
    #expect(request.payloadFileSystem == .ext4)
}

@Test
func androidApexMountRequestRequiresPositiveVersionAndAlignedPayload() {
    #expect(throws: AndroidApexMountFailure.self) {
        try AndroidApexMountRequest(
            rootFileSystem:
                "/run/nucleus/android/nucleus-framework-1/rootfs",
            source: "/product/apex/com.android.runtime.apex",
            target: "/apex/com.android.runtime@0",
            payloadFileSystem: .erofs,
            payloadOffset: 4_096)
    }
    #expect(throws: AndroidApexMountFailure.self) {
        try AndroidApexMountRequest(
            rootFileSystem:
                "/run/nucleus/android/nucleus-framework-1/rootfs",
            source: "/product/apex/com.android.runtime.apex",
            target: "/apex/com.android.runtime@370399999",
            payloadFileSystem: .erofs,
            payloadOffset: 4_097)
    }
}
