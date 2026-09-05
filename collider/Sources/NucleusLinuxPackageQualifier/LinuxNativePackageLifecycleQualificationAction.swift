import ColliderCore
import ColliderPersistence
import Foundation
import LinuxPackageAssembly
import LinuxPackageContracts
import SystemPackage

package struct QualifyLinuxNativePackageLifecycleAction: ColliderAction {
    package struct Identity: ColliderActionIdentity {
        let family: LinuxDistributionFamily
        let architecture: PlatformArchitecture
        let packagePublicationRoot: FilePath
        let qualificationRoot: FilePath
        let assemblerExecutable: FilePath
        let builderImageID: FilePath

        package func encode(into encoder: inout IdentityEncoder) {
            encoder.append(family.rawValue)
            encoder.append(architecture.rawValue)
            encoder.append(path: packagePublicationRoot)
            encoder.append(path: qualificationRoot)
            encoder.append(path: assemblerExecutable)
            encoder.append(path: builderImageID)
        }
    }

    package static let kind: ActionKind =
        "linux.qualify-native-package-lifecycle"

    private let family: LinuxDistributionFamily
    private let architecture: PlatformArchitecture
    private let packagePublicationRoot: FilePath
    private let qualificationRoot: FilePath
    private let assemblerExecutable: FilePath
    private let builderImageID: FilePath
    package let environment: [String: String]

    package init(
        family: LinuxDistributionFamily,
        architecture: PlatformArchitecture,
        packagePublicationRoot: FilePath,
        qualificationRoot: FilePath,
        assemblerExecutable: FilePath,
        builderImageID: FilePath,
        environment: [String: String]
    ) {
        self.family = family
        self.architecture = architecture
        self.packagePublicationRoot = packagePublicationRoot
        self.qualificationRoot = qualificationRoot
        self.assemblerExecutable = assemblerExecutable
        self.builderImageID = builderImageID
        self.environment = environment
    }

    package var identity: Identity {
        Identity(
            family: family,
            architecture: architecture,
            packagePublicationRoot: packagePublicationRoot,
            qualificationRoot: qualificationRoot,
            assemblerExecutable: assemblerExecutable,
            builderImageID: builderImageID)
    }

    package var requirements: ActionRequirements {
        ActionRequirements(
            tools: [
                ActionToolRequirement(
                    "dpkg", executable: .named("dpkg"), role: .semantic),
                ActionToolRequirement(
                    "dpkg-deb", executable: .named("dpkg-deb"), role: .semantic),
                ActionToolRequirement(
                    "dpkg-query", executable: .named("dpkg-query"), role: .semantic),
                ActionToolRequirement(
                    "gzip", executable: .named("gzip"), role: .semantic),
                ActionToolRequirement(
                    "pacman", executable: .named("pacman"), role: .semantic),
                ActionToolRequirement(
                    "rpm", executable: .named("rpm"), role: .semantic),
                ActionToolRequirement(
                    "rpmbuild", executable: .named("rpmbuild"), role: .semantic),
                ActionToolRequirement(
                    "tar", executable: .named("tar"), role: .semantic),
                ActionToolRequirement(
                    "zstd", executable: .named("zstd"), role: .semantic),
            ],
            effects: [
                ActionEffect(
                    .read, scope: .input(packagePublicationRoot)),
                ActionEffect(.read, scope: .input(assemblerExecutable)),
                ActionEffect(.read, scope: .input(builderImageID)),
                ActionEffect(
                    .readWrite,
                    scope: .unrestricted(FilePath("/"))),
                ActionEffect(
                    .readWrite, scope: .output(qualificationRoot)),
            ],
            executionPlatform: .linuxARM64OCI,
            artifactTarget: ArtifactTarget(
                operatingSystem: .linux,
                architecture: architecture,
                abi: "glibc"))
    }

    package func execute(in context: ActionContext) async throws {
        let publicationRoot = try activePackagePublicationRoot(files: context.files)
        let publication: LinuxNativePackageCohortPublication = try decodeLifecycleJSON(
            context.files.read(
                publicationRoot.appending("linux-native-package-cohort.json")))
        guard publication.architecture == architecture else {
            throw LinuxNativePackageLifecycleFailure(
                "package publication architecture does not match qualification")
        }
        let productionProducts = publication.products.filter {
            $0.family == family && $0.package != nil
        }
        guard productionProducts.count == lifecyclePackageNames.count else {
            throw LinuxNativePackageLifecycleFailure(
                "production package cohort is incomplete for (family.rawValue)")
        }
        let productionArtifacts = productionProducts.map(\.productArtifact).sorted {
            $0.rawValue.hexadecimal < $1.rawValue.hexadecimal
        }
        let productionCohort: LinuxNativePackageCohortManifest =
            try decodeLifecycleJSON(
                context.files.read(
                    publicationRoot.appending(
                        "manifests/\(family.rawValue)-cohort.json")))
        guard productionCohort.family == family,
            productionCohort.architecture == architecture
        else {
            throw LinuxNativePackageLifecycleFailure(
                "production cohort manifest does not match qualification")
        }

        let baseEnvelopeName =
            "\(LinuxNativePackageName.runtime.rawValue)-\(family.rawValue).product.json"
        let baseEnvelope: ProductArtifactEnvelope = try decodeLifecycleJSON(
            context.files.read(
                publicationRoot.appending("manifests/\(baseEnvelopeName)")))
        let assemblerIdentity = try context.files.digest(
            file: assemblerExecutable)
        let builderImageIdentity = try context.files.digest(file: builderImageID)
        let work = FilePath(
            "/tmp/nucleus-package-lifecycle-\(family.rawValue)-"
                + architecture.rawValue)
        try context.files.remove(work)
        try context.files.createDirectory(work)
        defer { try? context.files.remove(work) }
        let fixtureStore = LocalProductArtifactStore(
            root: work.appending("product-store"))
        let oldCohort = lifecycleFixtureCohort(
            productionCohort,
            canonicalVersion: "0.0.0-dev.0000000000000001")
        let newCohort = lifecycleFixtureCohort(
            productionCohort,
            canonicalVersion: "0.0.0-dev.0000000000000002")
        let oldArtifacts = try await assembleLifecycleFixture(
            cohort: oldCohort,
            label: "old",
            baseEnvelope: baseEnvelope,
            assemblerIdentity: assemblerIdentity,
            builderImageIdentity: builderImageIdentity,
            store: fixtureStore,
            work: work,
            context: context)
        let newArtifacts = try await assembleLifecycleFixture(
            cohort: newCohort,
            label: "new",
            baseEnvelope: baseEnvelope,
            assemblerIdentity: assemblerIdentity,
            builderImageIdentity: builderImageIdentity,
            store: fixtureStore,
            work: work,
            context: context)

        let lifecycleLog = work.appending("lifecycle.log")
        let toolRoot = FilePath("/usr/bin")
        let desktopRefresh = toolRoot.appending("update-desktop-database")
        try context.files.write(
            Array(
                "#!/bin/sh\nset -eu\nprintf '%s\\n' \"$*\" >> \"${NUCLEUS_LIFECYCLE_LOG:?}\"\n"
                    .utf8),
            to: desktopRefresh)
        try context.files.setPermissions(0o755, for: desktopRefresh)
        let commandEnvironment = lifecycleCommandEnvironment(
            toolRoot: toolRoot,
            lifecycleLog: lifecycleLog,
            home: work)
        let operations = try await exercisePackageManager(
            family: family,
            architecture: architecture,
            oldCohort: oldCohort,
            newCohort: newCohort,
            oldArtifacts: oldArtifacts,
            newArtifacts: newArtifacts,
            work: work,
            lifecycleLog: lifecycleLog,
            environment: commandEnvironment,
            context: context)
        let fixtureArtifacts = (oldArtifacts + newArtifacts).map {
            $0.envelope.identity
        }.sorted { $0.rawValue.hexadecimal < $1.rawValue.hexadecimal }
        let report = LinuxNativePackageLifecycleQualificationReport(
            family: family,
            architecture: architecture,
            oldVersion: oldCohort.packages[0].version,
            newVersion: newCohort.packages[0].version,
            productionArtifacts: productionArtifacts,
            fixtureArtifacts: fixtureArtifacts,
            operations: operations,
            lifecycleInvocations: try lifecycleLineCount(
                lifecycleLog,
                files: context.files))
        try context.files.createDirectory(qualificationRoot)
        try context.files.write(
            try encodeLifecycleJSON(report),
            to: qualificationReportPath(
                family: family,
                root: qualificationRoot))
    }

    package func validateOutputs(using files: ActionFileSystem) throws {
        let report: LinuxNativePackageLifecycleQualificationReport =
            try decodeLifecycleJSON(
                files.read(
                    qualificationReportPath(
                        family: family,
                        root: qualificationRoot)))
        guard report.family == family,
            report.architecture == architecture,
            report.productionArtifacts.count == lifecyclePackageNames.count,
            report.fixtureArtifacts.count == lifecyclePackageNames.count * 2,
            report.operations == lifecycleOperations,
            report.lifecycleInvocations >= lifecycleOperations.count
        else {
            throw LinuxNativePackageLifecycleFailure(
                "package lifecycle qualification report is incomplete")
        }
    }

    private func activePackagePublicationRoot(
        files: ActionFileSystem
    ) throws -> FilePath {
        let current = packagePublicationRoot.appending("current")
        guard
            try files.metadataWithoutFollowingSymlinks(for: current)?.type
                == .symbolicLink
        else {
            throw LinuxNativePackageLifecycleFailure(
                "package publication is missing")
        }
        let target = try files.readSymbolicLink(current)
        guard target.hasPrefix("generations/sha256-") else {
            throw LinuxNativePackageLifecycleFailure(
                "package publication is not content addressed")
        }
        return packagePublicationRoot.appending(target)
    }
}

private struct LifecycleFixtureArtifact {
    let package: LinuxNativePackageManifest
    let envelope: ProductArtifactEnvelope
    let archive: FilePath
    let payloadRoot: FilePath
}

private let lifecyclePackageNames: [LinuxNativePackageName] = [
    .runtime, .session, .browser, .androidPackage, .developmentHost, .complete,
]

private let lifecycleOperations = [
    "install-old", "upgrade-new", "downgrade-old", "remove-old",
    "reinstall-new", "remove-new",
]

private func lifecycleFixtureCohort(
    _ production: LinuxNativePackageCohortManifest,
    canonicalVersion: String
) -> LinuxNativePackageCohortManifest {
    let packageVersion = LinuxNativePackageCohortContract.packageVersion(
        canonicalVersion: canonicalVersion,
        family: production.family)
    let packages = production.packages.map { package in
        LinuxNativePackageManifest(
            family: package.family,
            name: package.name,
            version: packageVersion,
            architecture: package.architecture,
            summary: package.summary + " lifecycle fixture",
            relationships: package.relationships.map { relationship in
                LinuxNativePackageRelationship(
                    package: relationship.package,
                    requirement: relationship.requirement,
                    version: relationship.requirement == .exactCohort
                        ? packageVersion : nil)
            },
            conflicts: package.conflicts,
            ownedPaths: package.ownedPaths,
            lifecycle: package.lifecycle)
    }
    return LinuxNativePackageCohortManifest(
        family: production.family,
        canonicalVersion: canonicalVersion,
        architecture: production.architecture,
        runtimeArtifactDigest: production.runtimeArtifactDigest,
        browserPayloadDigest: production.browserPayloadDigest,
        browserBuildManifestDigest: production.browserBuildManifestDigest,
        packages: packages)
}

private func assembleLifecycleFixture(
    cohort: LinuxNativePackageCohortManifest,
    label: String,
    baseEnvelope: ProductArtifactEnvelope,
    assemblerIdentity: ArtifactDigest,
    builderImageIdentity: ArtifactDigest,
    store: LocalProductArtifactStore,
    work: FilePath,
    context: ActionContext
) async throws -> [LifecycleFixtureArtifact] {
    let fixtureRoot = work.appending(label)
    let archives = fixtureRoot.appending("archives")
    let staging = fixtureRoot.appending("staging")
    try context.files.createDirectory(archives)
    try context.files.createDirectory(staging)
    var artifacts: [LifecycleFixtureArtifact] = []
    for package in cohort.packages {
        let payload = staging.appending(package.name.rawValue)
        try materializeLifecycleFixture(
            package: package,
            cohort: cohort,
            root: payload,
            files: context.files)
        let archive = archives.appending(nativeArchiveName(package))
        try await AssembleLinuxNativePackagesAction.assemble(
            package: package,
            root: payload,
            archive: archive,
            workRoot: fixtureRoot,
            assemblerIdentity: assemblerIdentity,
            stageRecorder: LinuxNativePackageStageRecorder(),
            context: context)
        try await AssembleLinuxNativePackagesAction.validate(
            package: package,
            archive: archive,
            context: context)
        let envelope = try ProductArtifactBuilder.createEnvelope(
            payloadRoot: payload,
            archive: archive,
            sourceClosure: baseEnvelope.manifest.sourceClosure,
            submoduleClosures: baseEnvelope.manifest.submoduleClosures,
            producingTask: TaskID(
                rawValue:
                    "linux.\(cohort.architecture.rawValue).package-lifecycle-qualification"),
            runnerPlatform: baseEnvelope.manifest.runnerPlatform,
            executionPlatform: .linuxARM64OCI,
            artifactTarget: baseEnvelope.manifest.artifactTarget,
            toolchainIdentity: assemblerIdentity,
            builderImageIdentity: builderImageIdentity,
            buildConfiguration: .release,
            semanticBuildArguments: [
                "fixture=package-lifecycle", "family=\(cohort.family.rawValue)",
                "package=\(package.name.rawValue)", "version=\(package.version)",
            ],
            targetFilesystemRoots: baseEnvelope.manifest.targetFilesystemRoots.map {
                FilePath($0)
            },
            executables: [],
            producerTrustDomain: baseEnvelope.manifest.producerTrustDomain,
            requiredQualificationRoles: [.bundleIntegrity],
            provenance: baseEnvelope.provenance)
        let stored = try store.publish(
            envelope,
            payloadRoot: payload,
            archive: archive)
        artifacts.append(
            LifecycleFixtureArtifact(
                package: package,
                envelope: stored.envelope,
                archive: archive,
                payloadRoot: stored.payloadRoot))
        try context.files.remove(payload)
    }
    return artifacts
}

private func materializeLifecycleFixture(
    package: LinuxNativePackageManifest,
    cohort: LinuxNativePackageCohortManifest,
    root: FilePath,
    files: ActionFileSystem
) throws {
    try files.remove(root)
    try files.createDirectory(root)
    for owned in package.ownedPaths {
        let destination = try installedLinuxPackagePath(owned.path, in: root)
        try files.createDirectory(destination.removingLastComponent())
        switch owned.kind {
        case .tree:
            try files.createDirectory(destination)
            let marker = destination.appending(".nucleus-lifecycle-fixture")
            try files.write(
                Array("\(cohort.canonicalVersion)\n".utf8),
                to: marker)
            try files.setPermissions(0o644, for: marker)
        case .file:
            let contents =
                if owned.path.hasSuffix(".desktop") {
                    "[Desktop Entry]\nType=Application\nName=Nucleus\nExec=/usr/bin/true\n"
                } else {
                    "\(package.name.rawValue) \(package.version)\n"
                }
            try files.write(Array(contents.utf8), to: destination)
            try files.setPermissions(owned.permissions ?? 0o644, for: destination)
        case .symbolicLink:
            guard let target = owned.symbolicLinkTarget else {
                throw LinuxNativePackageLifecycleFailure(
                    "fixture symlink has no target: \(owned.path)")
            }
            try files.replaceSymlink(at: destination, target: target)
        }
    }
}

private func exercisePackageManager(
    family: LinuxDistributionFamily,
    architecture: PlatformArchitecture,
    oldCohort: LinuxNativePackageCohortManifest,
    newCohort: LinuxNativePackageCohortManifest,
    oldArtifacts: [LifecycleFixtureArtifact],
    newArtifacts: [LifecycleFixtureArtifact],
    work: FilePath,
    lifecycleLog: FilePath,
    environment: [String: String],
    context: ActionContext
) async throws -> [String] {
    try await packageManagerInstall(
        family: family,
        architecture: architecture,
        artifacts: oldArtifacts,
        work: work,
        environment: environment,
        context: context)
    try validateInstalledLifecycleCohort(
        oldCohort,
        files: context.files)
    try await validateInstalledVersions(
        family: family,
        architecture: architecture,
        packages: oldCohort.packages,
        work: work,
        environment: environment,
        context: context)
    var lifecycleCount = try lifecycleLineCount(lifecycleLog, files: context.files)
    guard lifecycleCount >= 1 else {
        throw LinuxNativePackageLifecycleFailure(
            "package manager did not execute the install lifecycle hook")
    }

    let androidState = FilePath("/var/lib/nucleus/android/retained")
    let persistentAndroidState = Array("persistent-android-state\n".utf8)
    try context.files.createDirectory(androidState.removingLastComponent())
    try context.files.write(persistentAndroidState, to: androidState)

    let configurationPath = FilePath("/etc/pam.d/nucleus")
    let operatorConfiguration = Array("operator-preserved\n".utf8)
    try context.files.write(operatorConfiguration, to: configurationPath)
    try await packageManagerUpgrade(
        family: family,
        architecture: architecture,
        artifacts: newArtifacts,
        work: work,
        downgrade: false,
        environment: environment,
        context: context)
    try validateInstalledLifecycleCohort(newCohort, files: context.files)
    try requirePreservedConfiguration(
        operatorConfiguration,
        at: configurationPath,
        files: context.files)
    try requirePreservedAndroidState(
        persistentAndroidState,
        at: androidState,
        files: context.files)
    try await validateInstalledVersions(
        family: family,
        architecture: architecture,
        packages: newCohort.packages,
        work: work,
        environment: environment,
        context: context)
    var nextCount = try lifecycleLineCount(lifecycleLog, files: context.files)
    guard nextCount > lifecycleCount else {
        throw LinuxNativePackageLifecycleFailure(
            "package manager did not execute the upgrade lifecycle hook")
    }
    lifecycleCount = nextCount

    try await packageManagerUpgrade(
        family: family,
        architecture: architecture,
        artifacts: oldArtifacts,
        work: work,
        downgrade: true,
        environment: environment,
        context: context)
    try validateInstalledLifecycleCohort(oldCohort, files: context.files)
    try requirePreservedConfiguration(
        operatorConfiguration,
        at: configurationPath,
        files: context.files)
    try requirePreservedAndroidState(
        persistentAndroidState,
        at: androidState,
        files: context.files)
    try await validateInstalledVersions(
        family: family,
        architecture: architecture,
        packages: oldCohort.packages,
        work: work,
        environment: environment,
        context: context)
    nextCount = try lifecycleLineCount(lifecycleLog, files: context.files)
    guard nextCount > lifecycleCount else {
        throw LinuxNativePackageLifecycleFailure(
            "package manager did not execute the downgrade lifecycle hook")
    }
    lifecycleCount = nextCount

    let sessionArtifact = try requireLifecycle(
        oldArtifacts.first { $0.package.name == .session })
    let packagedConfiguration = sessionArtifact.payloadRoot.appending(
        "etc/pam.d/nucleus")
    try context.files.copy(from: packagedConfiguration, to: configurationPath)
    try await packageManagerRemove(
        family: family,
        architecture: architecture,
        packages: oldCohort.packages,
        work: work,
        environment: environment,
        context: context)
    try validateRemovedLifecycleCohort(oldCohort, files: context.files)
    try requirePreservedAndroidState(
        persistentAndroidState,
        at: androidState,
        files: context.files)
    nextCount = try lifecycleLineCount(lifecycleLog, files: context.files)
    guard nextCount > lifecycleCount else {
        throw LinuxNativePackageLifecycleFailure(
            "package manager did not execute the removal lifecycle hook")
    }
    lifecycleCount = nextCount

    try await packageManagerInstall(
        family: family,
        architecture: architecture,
        artifacts: newArtifacts,
        work: work,
        environment: environment,
        context: context)
    try validateInstalledLifecycleCohort(newCohort, files: context.files)
    try requirePreservedAndroidState(
        persistentAndroidState,
        at: androidState,
        files: context.files)
    nextCount = try lifecycleLineCount(lifecycleLog, files: context.files)
    guard nextCount > lifecycleCount else {
        throw LinuxNativePackageLifecycleFailure(
            "package manager did not execute the reinstall lifecycle hook")
    }
    lifecycleCount = nextCount

    try await packageManagerRemove(
        family: family,
        architecture: architecture,
        packages: newCohort.packages,
        work: work,
        environment: environment,
        context: context)
    try validateRemovedLifecycleCohort(newCohort, files: context.files)
    try requirePreservedAndroidState(
        persistentAndroidState,
        at: androidState,
        files: context.files)
    nextCount = try lifecycleLineCount(lifecycleLog, files: context.files)
    guard nextCount > lifecycleCount else {
        throw LinuxNativePackageLifecycleFailure(
            "package manager did not execute the final removal lifecycle hook")
    }
    return lifecycleOperations
}

private func requirePreservedAndroidState(
    _ expected: [UInt8],
    at path: FilePath,
    files: ActionFileSystem
) throws {
    guard try files.read(path) == expected else {
        throw LinuxNativePackageLifecycleFailure(
            "package transaction changed persistent Android state")
    }
}

private func packageManagerInstall(
    family: LinuxDistributionFamily,
    architecture: PlatformArchitecture,
    artifacts: [LifecycleFixtureArtifact],
    work: FilePath,
    environment: [String: String],
    context: ActionContext
) async throws {
    if family == .rpm {
        let database = work.appending("rpmdb")
        try context.files.createDirectory(database)
        _ = try await requireLifecycleCommand(
            "rpm",
            ["--dbpath", database.string, "--initdb"],
            environment: environment,
            context: context)
    }
    try await packageManagerUpgrade(
        family: family,
        architecture: architecture,
        artifacts: artifacts,
        work: work,
        downgrade: false,
        environment: environment,
        context: context)
}

private func packageManagerUpgrade(
    family: LinuxDistributionFamily,
    architecture: PlatformArchitecture,
    artifacts: [LifecycleFixtureArtifact],
    work: FilePath,
    downgrade: Bool,
    environment: [String: String],
    context: ActionContext
) async throws {
    let archives = artifacts.map(\.archive.string)
    switch family {
    case .debian:
        _ = try await requireLifecycleCommand(
            "dpkg",
            [
                "--force-architecture", "--force-depends", "--force-confold",
                "--install",
            ] + archives,
            environment: environment,
            context: context)
    case .rpm:
        let database = work.appending("rpmdb")
        var arguments = [
            "--dbpath", database.string, "--upgrade", "--nodeps",
            "--ignorearch", "--replacepkgs", "--noplugins", "--nocontexts",
        ]
        if downgrade { arguments.append("--oldpackage") }
        _ = try await requireLifecycleCommand(
            "rpm",
            arguments + archives,
            environment: environment,
            context: context)
    case .arch:
        try preparePacman(work: work, files: context.files)
        _ = try await requireLifecycleCommand(
            "pacman",
            pacmanArguments(
                architecture: architecture,
                work: work) + ["--noconfirm", "-Udd"] + archives,
            environment: environment,
            context: context)
    }
}

private func packageManagerRemove(
    family: LinuxDistributionFamily,
    architecture: PlatformArchitecture,
    packages: [LinuxNativePackageManifest],
    work: FilePath,
    environment: [String: String],
    context: ActionContext
) async throws {
    let names = packages.reversed().map { $0.name.rawValue }
    switch family {
    case .debian:
        _ = try await requireLifecycleCommand(
            "dpkg",
            ["--force-depends", "--purge"] + names,
            environment: environment,
            context: context)
    case .rpm:
        _ = try await requireLifecycleCommand(
            "rpm",
            [
                "--dbpath", work.appending("rpmdb").string, "--erase", "--nodeps",
                "--noplugins",
            ] + names,
            environment: environment,
            context: context)
    case .arch:
        _ = try await requireLifecycleCommand(
            "pacman",
            pacmanArguments(
                architecture: architecture,
                work: work) + ["--noconfirm", "-Rdd", "--nosave"] + names,
            environment: environment,
            context: context)
    }
}

private func validateInstalledVersions(
    family: LinuxDistributionFamily,
    architecture: PlatformArchitecture,
    packages: [LinuxNativePackageManifest],
    work: FilePath,
    environment: [String: String],
    context: ActionContext
) async throws {
    for package in packages {
        let result: CommandResult
        switch family {
        case .debian:
            result = try await requireLifecycleCommand(
                "dpkg-query",
                ["--show", "--showformat=${Version}", package.name.rawValue],
                environment: environment,
                context: context)
        case .rpm:
            result = try await requireLifecycleCommand(
                "rpm",
                [
                    "--dbpath", work.appending("rpmdb").string, "--query",
                    "--queryformat", "%{VERSION}-%{RELEASE}", package.name.rawValue,
                ],
                environment: environment,
                context: context)
        case .arch:
            result = try await requireLifecycleCommand(
                "pacman",
                pacmanArguments(
                    architecture: architecture,
                    work: work) + ["-Q", package.name.rawValue],
                environment: environment,
                context: context)
        }
        let output = result.standardOutput.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard
            family == .arch
                ? output == "\(package.name.rawValue) \(package.version)"
                : output == package.version
        else {
            throw LinuxNativePackageLifecycleFailure(
                "\(family.rawValue) installed \(package.name.rawValue) at "
                    + "unexpected version '\(output)'")
        }
    }
}

private func validateInstalledLifecycleCohort(
    _ cohort: LinuxNativePackageCohortManifest,
    files: ActionFileSystem
) throws {
    for package in cohort.packages {
        for owned in package.ownedPaths {
            let path = FilePath(owned.path)
            guard let metadata = try files.metadataWithoutFollowingSymlinks(for: path)
            else {
                throw LinuxNativePackageLifecycleFailure(
                    "installed package path is missing: \(owned.path)")
            }
            let expected: ActionFileSystem.FileType =
                switch owned.kind {
                case .file: .regular
                case .symbolicLink: .symbolicLink
                case .tree: .directory
                }
            guard metadata.type == expected else {
                throw LinuxNativePackageLifecycleFailure(
                    "installed package path has the wrong type: \(owned.path)")
            }
            if let permissions = owned.permissions,
                metadata.permissions & 0o7777 != permissions
            {
                throw LinuxNativePackageLifecycleFailure(
                    "installed package path has the wrong mode: \(owned.path)")
            }
            if let target = owned.symbolicLinkTarget,
                try files.readSymbolicLink(path) != target
            {
                throw LinuxNativePackageLifecycleFailure(
                    "installed package symlink has the wrong target: \(owned.path)")
            }
        }
    }
}

private func validateRemovedLifecycleCohort(
    _ cohort: LinuxNativePackageCohortManifest,
    files: ActionFileSystem
) throws {
    for package in cohort.packages {
        for owned in package.ownedPaths
        where
            try files.metadataWithoutFollowingSymlinks(for: FilePath(owned.path)) != nil
        {
            throw LinuxNativePackageLifecycleFailure(
                "removed package path remains installed: \(owned.path)")
        }
    }
}

private func requirePreservedConfiguration(
    _ expected: [UInt8],
    at path: FilePath,
    files: ActionFileSystem
) throws {
    guard try files.read(path) == expected else {
        throw LinuxNativePackageLifecycleFailure(
            "package manager replaced the operator-modified configuration")
    }
}

private func lifecycleCommandEnvironment(
    toolRoot: FilePath,
    lifecycleLog: FilePath,
    home: FilePath
) -> [String: String] {
    [
        "DEBIAN_FRONTEND": "noninteractive",
        "DPKG_COLORS": "never",
        "HOME": home.string,
        "LANG": "C.UTF-8",
        "LC_ALL": "C.UTF-8",
        "NUCLEUS_LIFECYCLE_LOG": lifecycleLog.string,
        "PATH": toolRoot.string
            + ":/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
    ]
}

private func preparePacman(
    work: FilePath,
    files: ActionFileSystem
) throws {
    for path in ["pacman-db/local", "pacman-cache", "pacman-hooks"] {
        try files.createDirectory(work.appending(path))
    }
    let configuration = work.appending("pacman.conf")
    if try files.metadata(for: configuration) == nil {
        try files.write(
            Array(
                "[options]\nArchitecture = auto\nSigLevel = Never\nLocalFileSigLevel = Never\n"
                    .utf8),
            to: configuration)
    }
}

private func pacmanArguments(
    architecture: PlatformArchitecture,
    work: FilePath
) -> [String] {
    [
        "--config", work.appending("pacman.conf").string,
        "--root", "/",
        "--dbpath", work.appending("pacman-db").string,
        "--cachedir", work.appending("pacman-cache").string,
        "--hookdir", work.appending("pacman-hooks").string,
        "--logfile", work.appending("pacman.log").string,
        "--arch", architecture == .arm64 ? "aarch64" : "x86_64",
    ]
}

private func lifecycleLineCount(
    _ path: FilePath,
    files: ActionFileSystem
) throws -> Int {
    guard try files.metadata(for: path) != nil else { return 0 }
    return String(decoding: try files.read(path), as: UTF8.self)
        .split(separator: "\n").count
}

@discardableResult
private func requireLifecycleCommand(
    _ executable: String,
    _ arguments: [String],
    environment: [String: String],
    context: ActionContext
) async throws -> CommandResult {
    let result = try await context.commands.execute(
        CommandSpec(
            executable: .named(executable),
            arguments: arguments,
            workingDirectory: FilePath("/"),
            environment: nativePackageSubprocessEnvironment(environment),
            output: .captured(limit: 4 * 1_024 * 1_024)))
    guard result.succeeded else {
        throw result.executionFailure(
            reason: "Linux native package lifecycle command failed")
    }
    return result
}

private func qualificationReportPath(
    family: LinuxDistributionFamily,
    root: FilePath
) -> FilePath {
    root.appending("\(family.rawValue).json")
}

private func encodeLifecycleJSON<T: Encodable>(_ value: T) throws -> [UInt8] {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [
        .prettyPrinted, .sortedKeys, .withoutEscapingSlashes,
    ]
    var bytes = Array(try encoder.encode(value))
    bytes.append(0x0a)
    return bytes
}

private func decodeLifecycleJSON<T: Decodable>(_ bytes: [UInt8]) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(bytes))
}

private func requireLifecycle<T>(_ value: T?) throws -> T {
    guard let value else {
        throw LinuxNativePackageLifecycleFailure(
            "package lifecycle fixture is incomplete")
    }
    return value
}

private struct LinuxNativePackageLifecycleFailure: Error,
    CustomStringConvertible, Sendable
{
    let description: String

    init(_ description: String) {
        self.description =
            "Linux native package lifecycle qualification failed: \(description)"
    }
}
