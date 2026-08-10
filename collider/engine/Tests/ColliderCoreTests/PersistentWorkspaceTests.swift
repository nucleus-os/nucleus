import ColliderCore
import SystemPackage
import Testing

private struct PersistentWorkspaceFixtureAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: "fixture")
        }
    }

    static let kind: ActionKind = "fixture.persistent-workspace"

    let identity = Identity()
    let requirements: ActionRequirements

    func execute(in _: ActionContext) async throws {}
}

private func fixtureWorkspace(
    key: String = "build-output",
    target: ArtifactTarget = .linuxARM64,
    role: String = "build",
    capacityBytes: UInt64 = 100 * 1_024 * 1_024 * 1_024,
    journal: PersistentWorkspaceJournal = .writeback64MiB
) -> PersistentWorkspaceDeclaration {
    PersistentWorkspaceDeclaration(
        identity: PersistentWorkspaceIdentity(
            key: key,
            artifactTarget: target,
            role: role),
        capacityBytes: capacityBytes,
        filesystem: .ext4,
        journal: journal)
}

private func fixtureWorkspaceEffect(
    workspace: PersistentWorkspaceDeclaration = fixtureWorkspace(),
    target: String = "/build",
    access: OCIPersistentWorkspaceMount.Access = .readWrite
) -> ActionPersistentWorkspaceEffect {
    ActionPersistentWorkspaceEffect(
        workspace: workspace,
        target: target,
        access: access)
}

@Test func persistentWorkspaceDeclarationIsAcceptedAsASeparateActionEffect() throws {
    let effect = fixtureWorkspaceEffect(access: .readOnly)
    let action = try AnyColliderAction(
        PersistentWorkspaceFixtureAction(
            requirements: ActionRequirements(
                persistentWorkspaceEffects: [effect],
                executionPlatform: .linuxARM64OCI,
                artifactTarget: .linuxARM64)))

    #expect(action.requirements.effects.isEmpty)
    #expect(action.requirements.persistentWorkspaceEffects == [effect])
}

@Test(arguments: ["", "/host/path", "Uppercase", ".hidden"])
func persistentWorkspaceRejectsInvalidLogicalKeys(_ key: String) {
    #expect(throws: ActionDeclarationFailure.self) {
        _ = try AnyColliderAction(
            PersistentWorkspaceFixtureAction(
                requirements: ActionRequirements(
                    persistentWorkspaceEffects: [
                        fixtureWorkspaceEffect(
                            workspace: fixtureWorkspace(key: key))
                    ],
                    executionPlatform: .linuxARM64OCI,
                    artifactTarget: .linuxARM64)))
    }
}

@Test func persistentWorkspaceRejectsInvalidCapacityAndJournal() {
    let declarations = [
        fixtureWorkspace(capacityBytes: 0),
        fixtureWorkspace(
            capacityBytes: 64,
            journal: PersistentWorkspaceJournal(mode: .writeback, sizeBytes: 64)),
        fixtureWorkspace(
            journal: PersistentWorkspaceJournal(mode: .writeback, sizeBytes: 0)),
    ]

    for workspace in declarations {
        #expect(throws: ActionDeclarationFailure.self) {
            _ = try AnyColliderAction(
                PersistentWorkspaceFixtureAction(
                    requirements: ActionRequirements(
                        persistentWorkspaceEffects: [
                            fixtureWorkspaceEffect(workspace: workspace)
                        ],
                        executionPlatform: .linuxARM64OCI,
                        artifactTarget: .linuxARM64)))
        }
    }
}

@Test func persistentWorkspaceRejectsTargetMismatchAndInvalidGuestPaths() {
    let effects = [
        fixtureWorkspaceEffect(target: "build"),
        fixtureWorkspaceEffect(target: "/build/../host"),
        fixtureWorkspaceEffect(target: "/"),
    ]
    for effect in effects {
        #expect(throws: ActionDeclarationFailure.self) {
            _ = try AnyColliderAction(
                PersistentWorkspaceFixtureAction(
                    requirements: ActionRequirements(
                        persistentWorkspaceEffects: [effect],
                        executionPlatform: .linuxARM64OCI,
                        artifactTarget: .linuxARM64)))
        }
    }

    #expect(throws: ActionDeclarationFailure.self) {
        _ = try AnyColliderAction(
            PersistentWorkspaceFixtureAction(
                requirements: ActionRequirements(
                    persistentWorkspaceEffects: [fixtureWorkspaceEffect()],
                    executionPlatform: .linuxARM64OCI,
                    artifactTarget: .linuxX86_64)))
    }
}

@Test func persistentWorkspaceRejectsDuplicateAndOverlappingMounts() {
    #expect(throws: ActionDeclarationFailure.self) {
        let effect = fixtureWorkspaceEffect()
        _ = try AnyColliderAction(
            PersistentWorkspaceFixtureAction(
                requirements: ActionRequirements(
                    persistentWorkspaceEffects: [effect, effect],
                    executionPlatform: .linuxARM64OCI,
                    artifactTarget: .linuxARM64)))
    }

    #expect(throws: ActionDeclarationFailure.self) {
        _ = try AnyColliderAction(
            PersistentWorkspaceFixtureAction(
                requirements: ActionRequirements(
                    persistentWorkspaceEffects: [
                        fixtureWorkspaceEffect(target: "/build"),
                        fixtureWorkspaceEffect(
                            workspace: fixtureWorkspace(key: "compiler-cache", role: "cache"),
                            target: "/build/cache"),
                    ],
                    executionPlatform: .linuxARM64OCI,
                    artifactTarget: .linuxARM64)))
    }
}

@Test func persistentWorkspaceConfigurationDoesNotAffectOCIActionIdentity() throws {
    func identity(
        capacityBytes: UInt64,
        journalBytes: UInt64
    ) throws -> [UInt8] {
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
                    workspace: fixtureWorkspace(
                        capacityBytes: capacityBytes,
                        journal: PersistentWorkspaceJournal(
                            mode: .writeback,
                            sizeBytes: journalBytes)),
                    target: "/build",
                    access: .readWrite)
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
        var encoder = ActionIdentityEncoder()
        OCIExecutionActionIdentity(execution).encode(into: &encoder)
        return try encoder.encodedBytes()
    }

    #expect(
        try identity(capacityBytes: 100, journalBytes: 10)
            == identity(capacityBytes: 200, journalBytes: 20))
}

@Test func OCIRequirementsDeclareEveryPersistentWorkspaceMount() {
    let workspace = fixtureWorkspace()
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
                workspace: workspace,
                target: "/build",
                access: .readWrite)
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

    #expect(
        ociActionRequirements(execution: execution).persistentWorkspaceEffects
            == [fixtureWorkspaceEffect(workspace: workspace)])
}

@Test func OCIRequirementsDistinguishInputsFromBoundedExports() {
    let input = FilePath("/fixture/source")
    let output = FilePath("/fixture/artifact")
    let execution = OCIExecution(
        executionPlatform: .linuxARM64OCI,
        artifactTarget: .linuxARM64,
        imageID: FilePath("/fixture/image-id"),
        hostname: "fixture",
        workingDirectory: "/src",
        hostWorkingDirectory: FilePath("/fixture"),
        mounts: [
            OCIMount(source: input, target: "/src", access: .readOnly),
            OCIMount(boundedExport: output, target: "/export"),
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

    let effects = ociActionRequirements(execution: execution).effects
    #expect(effects.contains(ActionEffect(.read, scope: .input(input))))
    #expect(effects.contains(ActionEffect(.readWrite, scope: .output(output))))
    #expect(!effects.contains(ActionEffect(.readWrite, scope: .scratch(output))))
}
