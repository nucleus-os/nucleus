import ColliderCore
import ColliderRuntime
import ContainerResource
import Foundation
import SystemPackage
import Testing

@testable import ColliderAppleContainer

private let fixtureWorkspaceOwner = String(repeating: "a", count: 64)

private func fixtureVolumeConfiguration() -> OCIRuntimeConfiguration {
    OCIRuntimeConfiguration(
        isolatedNetwork: "fixture-internal",
        guestHome: "/home/fixture",
        managedLabels: ["example.fixture.managed=true"],
        managedLabelNamespace: "example.fixture",
        persistentWorkspaceOwner: fixtureWorkspaceOwner,
        loggerLabel: "example.fixture.container")
}

private func fixtureVolumeDeclaration(
    key: String = "build-output",
    target: ArtifactTarget = .linuxARM64,
    role: String = "build",
    capacityBytes: UInt64 = 2 * 1_024 * 1_024 * 1_024
) -> PersistentWorkspaceDeclaration {
    PersistentWorkspaceDeclaration(
        identity: PersistentWorkspaceIdentity(
            key: key,
            artifactTarget: target,
            role: role),
        capacityBytes: capacityBytes,
        filesystem: .ext4,
        journal: .writeback64MiB)
}

private actor FixtureAppleVolumeStore {
    private var volumes: [String: VolumeConfiguration] = [:]
    private var active: Set<String> = []
    private var deletions: [String] = []

    nonisolated func operations() -> AppleContainerVolumeOperations {
        AppleContainerVolumeOperations(
            create: { [self] name, driver, options, labels in
                try await create(
                    name: name,
                    driver: driver,
                    options: options,
                    labels: labels)
            },
            inspect: { [self] name in try await inspect(name) },
            list: { [self] in await list() },
            delete: { [self] name in try await delete(name) },
            allocatedBytes: { [self] name in try await allocatedBytes(name) },
            activeNames: { [self] in await activeNames() })
    }

    func insert(_ volume: VolumeConfiguration, active: Bool = false) {
        volumes[volume.name] = volume
        if active { self.active.insert(volume.name) }
    }

    func deletedNames() -> [String] { deletions }

    private func create(
        name: String,
        driver: String,
        options: [String: String],
        labels: [String: String]
    ) throws -> VolumeConfiguration {
        guard volumes[name] == nil else {
            throw VolumeError.volumeAlreadyExists(name)
        }
        let size = options["size"].flatMap(UInt64.init)
        let volume = VolumeConfiguration(
            name: name,
            driver: driver,
            format: "ext4",
            source: "/fixture/\(name)/volume.img",
            labels: labels,
            options: options,
            sizeInBytes: size)
        volumes[name] = volume
        return volume
    }

    private func inspect(_ name: String) throws -> VolumeConfiguration {
        guard let volume = volumes[name] else {
            throw VolumeError.volumeNotFound(name)
        }
        return volume
    }

    private func list() -> [VolumeConfiguration] {
        Array(volumes.values)
    }

    private func delete(_ name: String) throws {
        guard !active.contains(name) else {
            throw VolumeError.volumeInUse(name)
        }
        guard volumes.removeValue(forKey: name) != nil else {
            throw VolumeError.volumeNotFound(name)
        }
        deletions.append(name)
    }

    private func allocatedBytes(_ name: String) throws -> UInt64 {
        guard let volume = volumes[name] else {
            throw VolumeError.volumeNotFound(name)
        }
        return (volume.sizeInBytes ?? 0) / 8
    }

    private func activeNames() -> Set<String> { active }
}

@Test func appleVolumeManagerCreatesValidatesAndReusesNamedWorkspaces() async throws {
    let store = FixtureAppleVolumeStore()
    let manager = ApplePersistentWorkspaceManager(
        configuration: fixtureVolumeConfiguration(),
        operations: store.operations())
    let declaration = fixtureVolumeDeclaration()
    let mount = OCIPersistentWorkspaceMount(
        workspace: declaration,
        target: "/build",
        access: .readWrite)

    let first = try await manager.resolve([mount])
    let name = try #require(first.names[declaration.identity])
    #expect(first.created == [mount])
    #expect(name.hasPrefix("collider-\(fixtureWorkspaceOwner)-build-output-"))

    let second = try await manager.resolve([mount])
    #expect(second.names == first.names)
    #expect(second.created.isEmpty)

    let state = try #require(try await manager.states().first)
    #expect(state.name == name)
    #expect(state.identity == declaration.identity)
    #expect(state.capacityBytes == declaration.capacityBytes)
    #expect(state.allocatedBytes == declaration.capacityBytes / 8)
    #expect(!state.active)
}

@Test func appleVolumeManagerRejectsConfigurationDrift() async throws {
    let store = FixtureAppleVolumeStore()
    let manager = ApplePersistentWorkspaceManager(
        configuration: fixtureVolumeConfiguration(),
        operations: store.operations())
    let declaration = fixtureVolumeDeclaration()
    let name = try manager.physicalName(for: declaration.identity)
    await store.insert(
        VolumeConfiguration(
            name: name,
            driver: "local",
            format: "ext4",
            source: "/fixture/\(name)/volume.img",
            labels: try manager.labels(for: declaration.identity),
            options: [
                "size": String(declaration.capacityBytes / 2),
                "journal": "writeback:\(declaration.journal.sizeBytes)",
            ],
            sizeInBytes: declaration.capacityBytes / 2))

    await #expect(throws: AppleContainerFailure.self) {
        _ = try await manager.resolve([
            OCIPersistentWorkspaceMount(
                workspace: declaration,
                target: "/build",
                access: .readWrite)
        ])
    }
}

@Test func appleVolumeManagerDeletesOnlyVolumesOwnedByThisCheckout() async throws {
    let store = FixtureAppleVolumeStore()
    let manager = ApplePersistentWorkspaceManager(
        configuration: fixtureVolumeConfiguration(),
        operations: store.operations())
    let declaration = fixtureVolumeDeclaration()
    let mount = OCIPersistentWorkspaceMount(
        workspace: declaration,
        target: "/build",
        access: .readWrite)
    let resolution = try await manager.resolve([mount])
    let ownedName = try #require(resolution.names[declaration.identity])
    await store.insert(
        VolumeConfiguration(
            name: "foreign-volume",
            source: "/fixture/foreign-volume/volume.img"))

    await #expect(throws: AppleContainerFailure.self) {
        try await manager.deleteOwned(name: "foreign-volume")
    }
    try await manager.deleteOwned(name: ownedName)
    #expect(await store.deletedNames() == [ownedName])
}

@Test func appleVolumeNamesRemainDeterministicAndWithinTheAppleLimit() throws {
    let manager = ApplePersistentWorkspaceManager(
        configuration: fixtureVolumeConfiguration(),
        operations: FixtureAppleVolumeStore().operations())
    let identity = PersistentWorkspaceIdentity(
        key: String(repeating: "k", count: 128),
        artifactTarget: .androidARM64(apiLevel: 37),
        role: String(repeating: "r", count: 128))

    let first = try manager.physicalName(for: identity)
    let second = try manager.physicalName(for: identity)
    #expect(first == second)
    #expect(first.utf8.count <= 255)
    #expect(first.hasPrefix("collider-\(fixtureWorkspaceOwner)-"))
}

@Test func appleContainerFlagsAttachResolvedVolumesWithDeclaredAccess() throws {
    let output = fixtureVolumeDeclaration()
    let cache = fixtureVolumeDeclaration(key: "compiler-cache", role: "cache")
    let execution = OCIExecution(
        executionPlatform: .linuxARM64OCI,
        artifactTarget: .linuxARM64,
        imageID: FilePath("/fixture/image-id"),
        hostname: "fixture",
        workingDirectory: "/src",
        hostWorkingDirectory: FilePath("/fixture"),
        mounts: [],
        persistentWorkspaceMounts: [
            OCIPersistentWorkspaceMount(
                workspace: output,
                target: "/build",
                access: .readWrite),
            OCIPersistentWorkspaceMount(
                workspace: cache,
                target: "/ccache",
                access: .readOnly),
        ],
        userPolicy: .builder,
        capabilityPolicy: .dropAll,
        privilegePolicy: .prohibitAcquisition,
        processFilesystemPolicy: .standard,
        resourceLimits: .build,
        containerEnvironment: [:],
        command: ["true"],
        environment: [:],
        output: .logged)

    let flags = try appleContainerFlags(
        execution,
        name: "fixture",
        configuration: fixtureVolumeConfiguration(),
        persistentWorkspaceNames: [
            output.identity: "output-volume",
            cache.identity: "cache-volume",
        ])

    #expect(flags.management.volumes == ["output-volume:/build", "cache-volume:/ccache:ro"])
}

@Test(
    .enabled(
        if: ProcessInfo.processInfo.environment[
            "COLLIDER_RUN_APPLE_CONTAINER_INTEGRATION_TESTS"] == "1"))
func appleContainerPersistentWorkspaceSurvivesContainersAndCancellation() async throws {
    let owner = String(repeating: "c", count: 64)
    let configuration = OCIRuntimeConfiguration(
        isolatedNetwork: "nucleus-build-internal",
        guestHome: "/home/collider-integration",
        managedLabels: ["dev.nucleus.collider.integration=true"],
        managedLabelNamespace: "dev.nucleus.collider.integration",
        persistentWorkspaceOwner: owner,
        loggerLabel: "dev.nucleus.collider.integration")
    let declaration = fixtureVolumeDeclaration(
        key: "integration-\(UUID().uuidString.lowercased())",
        capacityBytes: 128 * 1_024 * 1_024)
    let mount = OCIPersistentWorkspaceMount(
        workspace: declaration,
        target: "/build",
        access: .readWrite)
    let manager = ApplePersistentWorkspaceManager(configuration: configuration)
    let name = try manager.physicalName(for: declaration.identity)
    let backend = AppleContainerRuntimeBackend()
    let imageReference =
        ProcessInfo.processInfo.environment["COLLIDER_APPLE_CONTAINER_TEST_IMAGE"]
        ?? "docker.io/library/ubuntu:24.04"

    func request(
        command: [String],
        cancellation: RuntimeCancellation = RuntimeCancellation()
    ) -> OCIRuntimeExecutionRequest {
        let execution = OCIExecution(
            executionPlatform: .linuxARM64OCI,
            artifactTarget: .linuxARM64,
            imageID: FilePath("/fixture/image-id"),
            hostname: "collider-volume-integration",
            workingDirectory: "/build",
            hostWorkingDirectory: FilePath("/fixture"),
            mounts: [],
            persistentWorkspaceMounts: [mount],
            userPolicy: .builder,
            capabilityPolicy: .dropAll,
            privilegePolicy: .prohibitAcquisition,
            processFilesystemPolicy: .standard,
            resourceLimits: OCIResourceLimits(
                cpuCount: 2,
                memoryBytes: 1_024 * 1_024 * 1_024,
                processCount: 256),
            containerEnvironment: [:],
            command: command,
            environment: [:],
            output: .captured(limit: 64 * 1_024))
        return OCIRuntimeExecutionRequest(
            execution: execution,
            imageReference: imageReference,
            output: execution.output,
            logging: nil,
            stage: nil,
            cancellation: cancellation,
            configuration: configuration)
    }

    do {
        let write = try await backend.execute(
            request(command: [
                "/bin/sh", "-c", "printf persistent > /build/value",
            ]))
        #expect(write.result.succeeded)

        let read = try await backend.execute(
            request(command: ["/bin/cat", "/build/value"]))
        #expect(read.result.standardOutput == "persistent")

        let cancellation = RuntimeCancellation()
        let interrupted = Task {
            try await backend.execute(
                request(
                    command: [
                        "/bin/sh", "-c",
                        "printf retained > /build/cancelled; exec /bin/sleep 30",
                    ],
                    cancellation: cancellation))
        }
        try await ContinuousClock().sleep(for: .seconds(1))
        await cancellation.interruptAll()
        await #expect(throws: (any Error).self) {
            _ = try await interrupted.value
        }

        let retained = try await backend.execute(
            request(command: ["/bin/cat", "/build/cancelled"]))
        #expect(retained.result.standardOutput == "retained")
        try await manager.deleteOwned(name: name)
    } catch {
        try? await manager.deleteOwned(name: name)
        throw error
    }
}
