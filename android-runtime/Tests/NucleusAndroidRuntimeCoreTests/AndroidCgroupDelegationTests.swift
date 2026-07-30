import Testing

@testable import NucleusAndroidRuntimeCore

@Test
func androidCgroupDelegationResolvesTheOwnedPayloadRoot() throws {
    let delegation = try AndroidCgroupDelegation(
        containerName: "nucleus-android-runtime-3970820",
        mappedSystemUser: 166_536,
        mappedSystemGroup: 166_536)

    #expect(
        delegation.cgroupPath
            == "/sys/fs/cgroup/system.slice/"
            + "nucleus-android-runtime-3970820.scope/payload/android")
}
@Test
func androidCgroupDelegationRejectsPathsOutsideItsPrivilegeBoundary() {
    for name in [
        "nucleus-android-runtime-",
        "nucleus-android-runtime-current",
        "../nucleus-android-runtime-1",
        "other-1",
    ] {
        #expect(throws: AndroidCgroupDelegationFailure.self) {
            try AndroidCgroupDelegation(
                containerName: name,
                mappedSystemUser: 166_536,
                mappedSystemGroup: 166_536)
        }
    }
}

@Test
func androidCgroupDelegationRequiresAMappedSystemIdentity() {
    #expect(throws: AndroidCgroupDelegationFailure.self) {
        try AndroidCgroupDelegation(
            containerName: "nucleus-android-runtime-1",
            mappedSystemUser: 1_000,
            mappedSystemGroup: 1_000)
    }
}

@Test
func androidCgroupDelegationRequiresControllersAndProcessFreeParents() throws {
    let delegation = try AndroidCgroupDelegation(
        containerName: "nucleus-android-runtime-1",
        mappedSystemUser: 166_536,
        mappedSystemGroup: 166_536)

    #expect(
        try delegation.validatePreconditions(
            payloadProcesses: "",
            rootProcesses: "42\n",
            controllers: "cpuset cpu io memory pids") == [42])
    #expect(throws: AndroidCgroupDelegationFailure.self) {
        try delegation.validatePreconditions(
            payloadProcesses: "7\n",
            rootProcesses: "42\n",
            controllers: "cpuset cpu io memory pids")
    }
    #expect(throws: AndroidCgroupDelegationFailure.self) {
        try delegation.validatePreconditions(
            payloadProcesses: "",
            rootProcesses: "42\n",
            controllers: "cpuset cpu memory pids")
    }
    #expect(throws: AndroidCgroupDelegationFailure.self) {
        try delegation.validatePreconditions(
            payloadProcesses: "",
            rootProcesses: "",
            controllers: "cpuset cpu io memory pids")
    }
}

@Test
func androidCgroupDelegationRequiresMappedSystemOwnership() throws {
    let delegation = try AndroidCgroupDelegation(
        containerName: "nucleus-android-runtime-1",
        mappedSystemUser: 166_536,
        mappedSystemGroup: 166_536)

    try delegation.validateDelegatedRoot(
        owner: 166_536,
        group: 166_536,
        permissions: 0o775)
    #expect(throws: AndroidCgroupDelegationFailure.self) {
        try delegation.validateDelegatedRoot(
            owner: 165_536,
            group: 165_536,
            permissions: 0o775)
    }
}
