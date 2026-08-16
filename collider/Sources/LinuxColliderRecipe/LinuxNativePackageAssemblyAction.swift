import ChromiumColliderRecipe
import ColliderCore
import ColliderPersistence
import Foundation
import ShellColliderRecipe
import SystemPackage

package struct LinuxNativePackagePublication: Hashable, Sendable {
    package let architecture: PlatformArchitecture
    package let sourceSnapshot: FilePath
    package let runtimeArtifactRoot: FilePath
    package let browser: BrowserPackageInputPublication
    package let outputRoot: FilePath
    package let productStoreRoot: FilePath
    package let assemblerExecutable: FilePath
    package let builderImageID: FilePath
    package let producerRunner: RunnerPlatform
    package let environment: [String: String]

    package init(
        architecture: PlatformArchitecture,
        sourceSnapshot: FilePath,
        runtimeArtifactRoot: FilePath,
        browser: BrowserPackageInputPublication,
        outputRoot: FilePath,
        productStoreRoot: FilePath,
        assemblerExecutable: FilePath,
        builderImageID: FilePath,
        producerRunner: RunnerPlatform,
        environment: [String: String]
    ) {
        self.architecture = architecture
        self.sourceSnapshot = sourceSnapshot
        self.runtimeArtifactRoot = runtimeArtifactRoot
        self.browser = browser
        self.outputRoot = outputRoot
        self.productStoreRoot = productStoreRoot
        self.assemblerExecutable = assemblerExecutable
        self.builderImageID = builderImageID
        self.producerRunner = producerRunner
        self.environment = environment
    }
}

package struct LinuxNativePackageCohortPublication: Codable, Equatable, Sendable {
    package struct Product: Codable, Equatable, Sendable {
        package let family: LinuxDistributionFamily
        package let package: LinuxNativePackageName?
        package let archive: String
        package let archiveDigest: ArtifactDigest
        package let productArtifact: ProductArtifactID
    }

    package let architecture: PlatformArchitecture
    package let products: [Product]
}

package struct AssembleLinuxNativePackagesAction: ColliderAction {
    package struct Identity: ColliderActionIdentity {
        let publication: LinuxNativePackagePublication

        package func encode(into encoder: inout IdentityEncoder) {
            encoder.append(publication.architecture.rawValue)
            encoder.append(path: publication.sourceSnapshot)
            encoder.append(path: publication.runtimeArtifactRoot)
            encoder.append(path: publication.browser.distributionRoot)
            encoder.append(path: publication.browser.packageInputRoot)
            encoder.append(path: publication.outputRoot)
            encoder.append(path: publication.productStoreRoot)
            encoder.append(path: publication.assemblerExecutable)
            encoder.append(path: publication.builderImageID)
            encoder.append(publication.producerRunner.operatingSystem.rawValue)
            encoder.append(publication.producerRunner.architecture.rawValue)
        }
    }

    package static let kind: ActionKind = "linux.assemble-native-packages"

    let publication: LinuxNativePackagePublication

    package init(publication: LinuxNativePackagePublication) {
        self.publication = publication
    }

    package var identity: Identity { Identity(publication: publication) }
    package var environment: [String: String] { publication.environment }

    package var requirements: ActionRequirements {
        ActionRequirements(
            tools: [
                ActionToolRequirement(
                    "bash", executable: .named("bash"), role: .operational),
                ActionToolRequirement(
                    "desktop-file-validate",
                    executable: .named("desktop-file-validate"),
                    role: .semantic),
                ActionToolRequirement(
                    "dpkg-deb", executable: .named("dpkg-deb"), role: .semantic),
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
                ActionEffect(.read, scope: .input(publication.sourceSnapshot)),
                ActionEffect(
                    .read,
                    scope: .input(publication.runtimeArtifactRoot)),
                ActionEffect(
                    .read,
                    scope: .input(publication.browser.distributionRoot)),
                ActionEffect(
                    .read,
                    scope: .input(publication.browser.packageInputRoot)),
                ActionEffect(
                    .read,
                    scope: .input(publication.assemblerExecutable)),
                ActionEffect(.read, scope: .input(publication.builderImageID)),
                ActionEffect(
                    .readWrite,
                    scope: .publication(publication.outputRoot)),
                ActionEffect(
                    .readWrite,
                    scope: .publication(publication.productStoreRoot)),
            ],
            executionPlatform: .linuxARM64OCI,
            artifactTarget: ArtifactTarget(
                operatingSystem: .linux,
                architecture: publication.architecture,
                abi: "glibc"))
    }

    package func execute(in context: ActionContext) async throws {
        let browser = try validatedBrowserPackageInput(
            publication.browser,
            files: context.files)
        let browserPayload = publication.browser.distributionRoot.appending(
            browser.payloadGeneration)
        let runtimePublication = try activeRuntimePublication(files: context.files)
        let producerTrustDomain = try producerTrustDomain()
        let source = try JSONDecoder().decode(
            ProductArtifactSourceSnapshot.self,
            from: Data(context.files.read(publication.sourceSnapshot)))
        let toolchainIdentity = try context.files.digest(
            file: publication.assemblerExecutable)
        let builderImageIdentity = try context.files.digest(
            file: publication.builderImageID)

        let generations = publication.outputRoot.appending("generations")
        let candidate = generations.appending(".candidate")
        try context.files.createDirectory(generations)
        try context.files.remove(candidate)
        try context.files.createDirectory(candidate)
        var published = false
        defer {
            if !published { try? context.files.remove(candidate) }
        }

        let archives = candidate.appending("packages")
        let manifests = candidate.appending("manifests")
        let staging = candidate.appending(".staging")
        for directory in [archives, manifests, staging] {
            try context.files.createDirectory(directory)
        }
        var products: [LinuxNativePackageCohortPublication.Product] = []
        for family in LinuxDistributionFamily.allCases {
            let runtime = try runtimeManifest(family, files: context.files)
            try validateRuntimePackageInput(
                runtime,
                activeGeneration: runtimePublication.generation,
                activeDigest: runtimePublication.digest)
            let cohort = try LinuxNativePackageCohortContract(
                runtime: runtime,
                browser: browser,
                architecture: publication.architecture)
            let familyRoot = staging.appending(family.rawValue)
            try context.files.createDirectory(familyRoot)
            var familyProducts: [LinuxNativePackageCohortPublication.Product] = []
            for package in cohort.manifest.packages {
                let root = familyRoot.appending(package.name.rawValue)
                try materialize(
                    package: package,
                    cohort: cohort.manifest,
                    runtimeManifest: runtime,
                    runtimePayload: runtimePublication.payload,
                    browserManifest: browser,
                    browserPayload: browserPayload,
                    root: root,
                    files: context.files)
                let archive = archives.appending(
                    nativeArchiveName(package))
                try await Self.assemble(
                    package: package,
                    root: root,
                    archive: archive,
                    workRoot: familyRoot,
                    assemblerIdentity: toolchainIdentity,
                    context: context)
                try await Self.validate(
                    package: package,
                    archive: archive,
                    context: context)
                let productPayload = familyRoot.appending(
                    ".product-\(package.name.rawValue)")
                try context.files.createDirectory(productPayload)
                try context.files.write(
                    try encodedJSON(package),
                    to: productPayload.appending("package.json"))
                let envelope = try ProductArtifactBuilder.createEnvelope(
                    payloadRoot: productPayload,
                    archive: archive,
                    sourceClosure: source.closure,
                    submoduleClosures: source.submoduleClosures,
                    producingTask: LinuxTaskIDs.packageCohort(
                        publication.architecture),
                    runnerPlatform: publication.producerRunner,
                    executionPlatform: .linuxARM64OCI,
                    artifactTarget: ArtifactTarget(
                        operatingSystem: .linux,
                        architecture: publication.architecture,
                        abi: "glibc"),
                    toolchainIdentity: toolchainIdentity,
                    nativeSDKIdentities: [
                        ProductArtifactNamedIdentity(
                            name: "browser-payload",
                            digest: browser.payloadDigest),
                        ProductArtifactNamedIdentity(
                            name: "runtime-payload",
                            digest: cohort.manifest.runtimeArtifactDigest),
                    ],
                    builderImageIdentity: builderImageIdentity,
                    buildConfiguration: .release,
                    semanticBuildArguments: [
                        "family=\(family.rawValue)",
                        "package=\(package.name.rawValue)",
                        "version=\(package.version)",
                    ],
                    targetFilesystemRoots: [FilePath("/opt/nucleus")],
                    executables: [],
                    producerTrustDomain: producerTrustDomain,
                    requiredQualificationRoles: [.bundleIntegrity],
                    provenance: source.provenance,
                    identityPathMap: .empty)
                _ = try LocalProductArtifactStore(
                    root: publication.productStoreRoot
                ).publish(
                    envelope,
                    payloadRoot: productPayload,
                    archive: archive)
                try context.files.remove(productPayload)
                try context.files.write(
                    try encodedJSON(envelope),
                    to: manifests.appending(
                        "\(package.name.rawValue)-\(family.rawValue).product.json"))
                let product = LinuxNativePackageCohortPublication.Product(
                    family: family,
                    package: package.name,
                    archive: "packages/\(archive.lastComponent!.string)",
                    archiveDigest: envelope.manifest.archiveDigest,
                    productArtifact: envelope.identity)
                products.append(product)
                familyProducts.append(product)
            }
            let cohortProduct = try await assembleCohort(
                cohort: cohort.manifest,
                products: familyProducts,
                candidate: candidate,
                staging: familyRoot,
                source: source,
                toolchainIdentity: toolchainIdentity,
                builderImageIdentity: builderImageIdentity,
                producerTrustDomain: producerTrustDomain,
                context: context)
            products.append(cohortProduct)
            try context.files.write(
                try encodedJSON(cohort.manifest),
                to: manifests.appending("\(family.rawValue)-cohort.json"))
        }
        try context.files.remove(staging)
        let publicationManifest = LinuxNativePackageCohortPublication(
            architecture: publication.architecture,
            products: products.sorted {
                $0.archive.utf8.lexicographicallyPrecedes($1.archive.utf8)
            })
        try context.files.write(
            try encodedJSON(publicationManifest),
            to: candidate.appending("linux-native-package-cohort.json"))
        let digest = try context.files.digest(tree: candidate)
        try context.files.publishGeneration(
            candidate: candidate,
            generation: generations.appending("sha256-\(digest.hexadecimal)"),
            active: publication.outputRoot.appending("current"))
        published = true
    }

    package func validateOutputs(using files: ActionFileSystem) throws {
        try validateLinuxNativePackagePublication(
            architecture: publication.architecture,
            outputRoot: publication.outputRoot,
            productStoreRoot: publication.productStoreRoot,
            files: files)
    }

    private struct ActiveRuntimePublication {
        let payload: FilePath
        let generation: String
        let digest: ArtifactDigest
    }

    private func activeRuntimePublication(files: ActionFileSystem) throws
        -> ActiveRuntimePublication
    {
        let current = publication.runtimeArtifactRoot.appending("current")
        guard
            try files.metadataWithoutFollowingSymlinks(for: current)?.type
                == .symbolicLink
        else {
            throw LinuxNativePackageAssemblyFailure(
                "runtime artifact publication is missing")
        }
        let target = try files.readSymbolicLink(current)
        guard
            target.range(
                of: #"^generations/[0-9a-f]{24}$"#,
                options: .regularExpression) != nil,
            let generation = FilePath(target).lastComponent?.string
        else {
            throw LinuxNativePackageAssemblyFailure(
                "runtime artifact publication has an invalid target")
        }
        let payload = publication.runtimeArtifactRoot.appending(target)
        let digest = try files.digest(tree: payload)
        guard generation == String(digest.hexadecimal.prefix(24)) else {
            throw LinuxNativePackageAssemblyFailure(
                "runtime artifact generation does not match its contents")
        }
        return ActiveRuntimePublication(
            payload: payload,
            generation: generation,
            digest: digest)
    }

    private func runtimeManifest(
        _ family: LinuxDistributionFamily,
        files: ActionFileSystem
    ) throws -> LinuxDistributionPackageManifest {
        let path = publication.runtimeArtifactRoot.appending(
            "package-manifests/current/\(family.rawValue).json")
        let manifest: LinuxDistributionPackageManifest = try decodeJSON(
            files.read(path))
        guard manifest.family == family else {
            throw LinuxNativePackageAssemblyFailure(
                "runtime package manifest family does not match its path")
        }
        return manifest
    }

    private func producerTrustDomain() throws
        -> ProductArtifactProducerTrustDomain
    {
        guard let value = environment["NUCLEUS_PRODUCT_PRODUCER_TRUST_DOMAIN"] else {
            return .localDeveloper
        }
        guard let domain = ProductArtifactProducerTrustDomain(rawValue: value) else {
            throw LinuxNativePackageAssemblyFailure(
                "unknown product producer trust domain: \(value)")
        }
        return domain
    }
}

extension AssembleLinuxNativePackagesAction {
    fileprivate func materialize(
        package: LinuxNativePackageManifest,
        cohort: LinuxNativePackageCohortManifest,
        runtimeManifest: LinuxDistributionPackageManifest,
        runtimePayload: FilePath,
        browserManifest: BrowserPackageInputManifest,
        browserPayload: FilePath,
        root: FilePath,
        files: ActionFileSystem
    ) throws {
        try files.remove(root)
        try files.createDirectory(root)
        switch package.name {
        case .runtime:
            try copyTree(
                runtimePayload,
                to: installedLinuxPackagePath(runtimeManifest.runtimeGeneration, in: root),
                files: files)
        case .session:
            for installation in runtimeManifest.installations
            where installation.kind != .tree {
                let destination = try installedLinuxPackagePath(
                    installation.destination,
                    in: root)
                try files.createDirectory(destination.removingLastComponent())
                switch installation.kind {
                case .file:
                    guard let contents = installation.contents else {
                        throw LinuxNativePackageAssemblyFailure(
                            "session file has no contents: \(installation.destination)")
                    }
                    try files.write(Array(contents.utf8), to: destination)
                    try files.setPermissions(0o644, for: destination)
                case .symbolicLink:
                    guard let target = installation.target else {
                        throw LinuxNativePackageAssemblyFailure(
                            "session symlink has no target: \(installation.destination)")
                    }
                    try files.replaceSymlink(at: destination, target: target)
                case .tree:
                    break
                }
            }
        case .browser:
            let generation = try installedLinuxPackagePath(
                "/usr/lib/nucleus-browser/\(browserManifest.payloadGeneration)",
                in: root)
            try copyTree(browserPayload, to: generation, files: files)
            try files.createDirectory(
                installedLinuxPackagePath("/usr/lib/nucleus-browser", in: root))
            try files.replaceSymlink(
                at: installedLinuxPackagePath(
                    "/usr/lib/nucleus-browser/current",
                    in: root),
                target: browserManifest.payloadGeneration)
            try files.createDirectory(
                installedLinuxPackagePath("/usr/bin", in: root))
            try files.replaceSymlink(
                at: installedLinuxPackagePath("/usr/bin/nucleus-browser", in: root),
                target: "../lib/nucleus-browser/current/bin/nucleus-browser")
            let desktopTemplate = String(
                decoding: try files.read(
                    browserPayload.appending(
                        "share/applications/dev.nucleus.Browser.desktop.in")),
                as: UTF8.self)
            let desktop = try installedLinuxPackagePath(
                "/usr/share/applications/dev.nucleus.Browser.desktop",
                in: root)
            try files.createDirectory(desktop.removingLastComponent())
            try files.write(
                Array(
                    desktopTemplate.replacingOccurrences(
                        of: "@NUCLEUS_BROWSER_LAUNCHER@",
                        with: "/usr/bin/nucleus-browser"
                    ).utf8),
                to: desktop)
            try files.setPermissions(0o644, for: desktop)
            for path in package.ownedPaths
            where path.kind == .symbolicLink
                && path.path.hasPrefix("/usr/share/icons/")
            {
                let destination = try installedLinuxPackagePath(path.path, in: root)
                try files.createDirectory(destination.removingLastComponent())
                try files.replaceSymlink(
                    at: destination,
                    target: path.symbolicLinkTarget!)
            }
            let sandbox = try installedLinuxPackagePath(
                "/usr/libexec/nucleus-browser/chrome-sandbox",
                in: root)
            try files.createDirectory(sandbox.removingLastComponent())
            try files.copy(
                from: browserPayload.appending("runtime/chrome_sandbox"),
                to: sandbox)
            try files.setPermissions(0o4755, for: sandbox)
        case .developmentHost, .complete:
            guard let marker = package.ownedPaths.first else {
                throw LinuxNativePackageAssemblyFailure(
                    "meta package has no cohort marker")
            }
            let destination = try installedLinuxPackagePath(marker.path, in: root)
            try files.createDirectory(destination.removingLastComponent())
            try files.write(
                Array((cohort.canonicalVersion + "\n").utf8),
                to: destination)
            try files.setPermissions(marker.permissions ?? 0o644, for: destination)
        case .androidAddon:
            throw LinuxNativePackageAssemblyFailure(
                "Android add-on packaging belongs to Phase 4")
        }
        try validateMaterializedRoot(package, root: root, files: files)
    }

    package static func assemble(
        package: LinuxNativePackageManifest,
        root: FilePath,
        archive: FilePath,
        workRoot: FilePath,
        assemblerIdentity: ArtifactDigest,
        context: ActionContext
    ) async throws {
        switch package.family {
        case .debian:
            try await assembleDebian(
                package: package,
                root: root,
                archive: archive,
                context: context)
        case .rpm:
            try await assembleRPM(
                package: package,
                root: root,
                archive: archive,
                workRoot: workRoot,
                context: context)
        case .arch:
            try await assembleArch(
                package: package,
                root: root,
                archive: archive,
                assemblerIdentity: assemblerIdentity,
                context: context)
        }
    }

    private static func assembleDebian(
        package: LinuxNativePackageManifest,
        root: FilePath,
        archive: FilePath,
        context: ActionContext
    ) async throws {
        let control = root.appending("DEBIAN")
        try context.files.createDirectory(control)
        try context.files.write(
            Array(debianControl(package).utf8),
            to: control.appending("control"))
        if !package.configurationFiles.isEmpty {
            try context.files.write(
                Array((package.configurationFiles.joined(separator: "\n") + "\n").utf8),
                to: control.appending("conffiles"))
        }
        try writeMaintainerScripts(package, to: control, files: context.files)
        try await requireSuccess(
            .named("dpkg-deb"),
            ["--root-owner-group", "--build", root.string, archive.string],
            environment: reproducibleEnvironment,
            context: context)
        try context.files.remove(control)
    }

    private static func assembleRPM(
        package: LinuxNativePackageManifest,
        root: FilePath,
        archive: FilePath,
        workRoot: FilePath,
        context: ActionContext
    ) async throws {
        let top = workRoot.appending("rpm-\(package.name.rawValue)")
        let sources = top.appending("SOURCES")
        let sourceRoot = sources.appending("root")
        for name in [
            "BUILD", "BUILDROOT", "RPMS", "SOURCES", "SPECS", "SRPMS",
            "rpmdb", "tmp",
        ] {
            try context.files.createDirectory(top.appending(name))
        }
        try copyTree(root, to: sourceRoot, files: context.files)
        let spec = top.appending("SPECS/\(package.name.rawValue).spec")
        try context.files.write(Array(rpmSpec(package).utf8), to: spec)
        let rpmConfiguration = top.appending("rpmrc")
        try context.files.write(
            Array(
                "buildarch_compat: aarch64: \(package.architecture) noarch\n".utf8),
            to: rpmConfiguration)
        try await requireSuccess(
            .named("rpmbuild"),
            [
                "-bb", "--target", package.architecture,
                "--rcfile", "/usr/lib/rpm/rpmrc:\(rpmConfiguration.string)",
                "--dbpath", top.appending("rpmdb").string,
                "--define", "_topdir \(top.string)",
                "--define", "_dbpath \(top.appending("rpmdb").string)",
                "--define", "_tmppath \(top.appending("tmp").string)",
                "--define", "_builddir \(top.appending("BUILD").string)",
                "--define", "_buildrootdir \(top.appending("BUILDROOT").string)",
                "--define", "_rpmdir \(top.appending("RPMS").string)",
                "--define", "_srcrpmdir \(top.appending("SRPMS").string)",
                "--define", "_source_date_epoch 0",
                "--define", "use_source_date_epoch_as_buildtime 1",
                "--define", "_build_mtime_policy clamp_to_source_date_epoch",
                spec.string,
            ],
            environment: reproducibleEnvironment.merging([
                "HOME": top.string,
                "TMPDIR": top.appending("tmp").string,
            ]) { _, scoped in scoped },
            context: context)
        let built = top.appending(
            "RPMS/\(package.architecture)/\(nativeArchiveName(package))")
        try context.files.move(from: built, to: archive)
        try context.files.remove(top)
    }

    private static func assembleArch(
        package: LinuxNativePackageManifest,
        root: FilePath,
        archive: FilePath,
        assemblerIdentity: ArtifactDigest,
        context: ActionContext
    ) async throws {
        let installedSize = try archInstalledSize(root: root, files: context.files)
        let metadata = root.appending(".PKGINFO")
        try context.files.write(
            Array(
                archPackageInfo(
                    package,
                    installedSize: installedSize
                ).utf8),
            to: metadata)
        try context.files.setPermissions(0o644, for: metadata)
        let buildInfo = root.appending(".BUILDINFO")
        try context.files.write(
            Array(
                archBuildInfo(
                    package,
                    assemblerIdentity: assemblerIdentity
                ).utf8),
            to: buildInfo)
        try context.files.setPermissions(0o644, for: buildInfo)
        let install = root.appending(".INSTALL")
        if !package.lifecycle.afterInstall.isEmpty
            || !package.lifecycle.afterRemove.isEmpty
        {
            try context.files.write(
                Array(archInstallScript(package).utf8),
                to: install)
            try context.files.setPermissions(0o644, for: install)
        }
        let mtreeSource = root.appending(".MTREE.source")
        let mtree = root.appending(".MTREE")
        try context.files.write(
            Array(try archMTree(root: root, files: context.files).utf8),
            to: mtreeSource)
        try await requireSuccess(
            .named("gzip"),
            ["-n", "-9", mtreeSource.string],
            workingDirectory: root,
            environment: reproducibleEnvironment,
            context: context)
        try context.files.move(
            from: FilePath(mtreeSource.string + ".gz"),
            to: mtree)
        try context.files.setPermissions(0o644, for: mtree)
        try await requireSuccess(
            .named("tar"),
            [
                "--zstd", "--sort=name", "--mtime=@0", "--owner=0", "--group=0",
                "--numeric-owner", "--format=posix",
                "--pax-option=delete=atime,delete=ctime",
                #"--transform=s,^\./,,"#, "-cf", archive.string, ".",
            ],
            workingDirectory: root,
            environment: reproducibleEnvironment,
            context: context)
        try context.files.remove(metadata)
        try context.files.remove(buildInfo)
        try context.files.remove(mtree)
        try context.files.remove(install)
    }

    package static func validate(
        package: LinuxNativePackageManifest,
        archive: FilePath,
        context: ActionContext
    ) async throws {
        let metadata: CommandResult
        let contents: CommandResult
        let configurationMetadata: String?
        let archBuildMetadata: String?
        let archMTreeMetadata: String?
        switch package.family {
        case .debian:
            metadata = try await requireSuccess(
                .named("dpkg-deb"),
                ["--field", archive.string, "Package", "Version", "Architecture"],
                context: context)
            contents = try await requireSuccess(
                .named("dpkg-deb"),
                ["--contents", archive.string],
                context: context)
            if package.configurationFiles.isEmpty {
                configurationMetadata = nil
            } else {
                configurationMetadata = try await requireSuccess(
                    .named("dpkg-deb"),
                    ["--info", archive.string, "conffiles"],
                    context: context
                ).standardOutput
            }
            archBuildMetadata = nil
            archMTreeMetadata = nil
        case .rpm:
            let queryDatabase = archive.removingLastComponent().appending(
                ".rpm-query-db")
            try context.files.createDirectory(queryDatabase)
            defer { try? context.files.remove(queryDatabase) }
            metadata = try await requireSuccess(
                .named("rpm"),
                [
                    "--dbpath", queryDatabase.string, "-qp", "--qf",
                    "%{NAME}\\n%{VERSION}-%{RELEASE}\\n%{ARCH}\\n", archive.string,
                ],
                context: context)
            contents = try await requireSuccess(
                .named("rpm"),
                [
                    "--dbpath", queryDatabase.string, "-qp", "--dump",
                    archive.string,
                ],
                context: context)
            configurationMetadata = nil
            archBuildMetadata = nil
            archMTreeMetadata = nil
        case .arch:
            let queryDatabase = archive.removingLastComponent().appending(
                ".pacman-query-db")
            try context.files.createDirectory(queryDatabase.appending("local"))
            defer { try? context.files.remove(queryDatabase) }
            _ = try await requireSuccess(
                .named("pacman"),
                [
                    "--dbpath", queryDatabase.string, "--query", "--info",
                    "--file", archive.string,
                ],
                context: context)
            metadata = try await requireSuccess(
                .named("tar"),
                ["--zstd", "-xOf", archive.string, ".PKGINFO"],
                context: context)
            contents = try await requireSuccess(
                .named("tar"),
                ["--zstd", "-tvf", archive.string],
                context: context)
            configurationMetadata = metadata.standardOutput
            archBuildMetadata = try await requireSuccess(
                .named("tar"),
                ["--zstd", "-xOf", archive.string, ".BUILDINFO"],
                context: context
            ).standardOutput
            let inspection = archive.removingLastComponent().appending(
                ".arch-inspection-\(package.name.rawValue)")
            try context.files.remove(inspection)
            try context.files.createDirectory(inspection)
            defer { try? context.files.remove(inspection) }
            try await requireSuccess(
                .named("tar"),
                [
                    "--zstd", "-xf", archive.string, "-C", inspection.string,
                    ".MTREE",
                ],
                context: context)
            archMTreeMetadata = try await requireSuccess(
                .named("gzip"),
                ["-dc", inspection.appending(".MTREE").string],
                context: context
            ).standardOutput
        }
        for required in [package.name.rawValue, package.version, package.architecture] {
            guard metadata.standardOutput.contains(required) else {
                throw LinuxNativePackageAssemblyFailure(
                    "native package metadata is missing \(required): \(archive)")
            }
        }
        if package.family == .arch {
            guard archBuildMetadata?.contains("format = 2") == true,
                archBuildMetadata?.contains("buildtool = collider") == true,
                metadata.standardOutput.contains("xdata = pkgtype=pkg"),
                metadata.standardOutput.range(
                    of: #"(?m)^size = [1-9][0-9]*$"#,
                    options: .regularExpression) != nil,
                archMTreeMetadata?.hasPrefix("#mtree\n") == true
            else {
                throw LinuxNativePackageAssemblyFailure(
                    "Arch package metadata is incomplete: \(archive)")
            }
        }
        let archiveEntries = try parseLinuxNativePackageArchiveEntries(
            family: package.family,
            contents: contents.standardOutput)
        for path in package.ownedPaths {
            guard let entry = archiveEntries[path.path] else {
                throw LinuxNativePackageAssemblyFailure(
                    "native package archive is missing \(path.path): \(archive)")
            }
            guard entry.kind == path.kind, entry.rootOwned else {
                throw LinuxNativePackageAssemblyFailure(
                    "native package archive has incorrect type or ownership for "
                        + "\(path.path): \(entry.raw)")
            }
            if let permissions = path.permissions,
                entry.permissions != permissions
            {
                throw LinuxNativePackageAssemblyFailure(
                    "native package archive has mode "
                        + "\(String(entry.permissions, radix: 8)) for \(path.path), "
                        + "expected \(String(permissions, radix: 8)): \(entry.raw)")
            }
            if entry.symbolicLinkTarget != path.symbolicLinkTarget {
                throw LinuxNativePackageAssemblyFailure(
                    "native package archive has the wrong symlink target for "
                        + "\(path.path): \(entry.raw)")
            }
            if path.configurationFile {
                let configured =
                    switch package.family {
                    case .debian:
                        configurationMetadata?.split(separator: "\n").contains {
                            String($0).trimmingCharacters(in: .whitespaces)
                                == path.path
                        } == true
                    case .rpm:
                        entry.configurationFile
                    case .arch:
                        configurationMetadata?.contains(
                            "backup = \(path.path.dropFirst())") == true
                    }
                guard configured else {
                    throw LinuxNativePackageAssemblyFailure(
                        "native package archive lost configuration-file semantics for "
                            + path.path)
                }
            }
            if package.family == .arch {
                let mtreePath = "./\(mtreeEscaped(String(path.path.dropFirst())))"
                guard
                    let mtreeEntry = archMTreeMetadata?.split(separator: "\n")
                        .first(where: { $0.hasPrefix(mtreePath + " ") })
                else {
                    throw LinuxNativePackageAssemblyFailure(
                        "Arch mtree is missing \(path.path)")
                }
                if let permissions = path.permissions {
                    guard mtreeEntry.contains("mode=\(octalMode(permissions))") else {
                        throw LinuxNativePackageAssemblyFailure(
                            "Arch mtree has the wrong mode for \(path.path)")
                    }
                }
                if let target = path.symbolicLinkTarget {
                    guard mtreeEntry.contains("link=\(mtreeEscaped(target))") else {
                        throw LinuxNativePackageAssemblyFailure(
                            "Arch mtree has the wrong link target for \(path.path)")
                    }
                }
            }
        }
    }

    fileprivate func assembleCohort(
        cohort: LinuxNativePackageCohortManifest,
        products: [LinuxNativePackageCohortPublication.Product],
        candidate: FilePath,
        staging: FilePath,
        source: ProductArtifactSourceSnapshot,
        toolchainIdentity: ArtifactDigest,
        builderImageIdentity: ArtifactDigest,
        producerTrustDomain: ProductArtifactProducerTrustDomain,
        context: ActionContext
    ) async throws -> LinuxNativePackageCohortPublication.Product {
        let payload = staging.appending("cohort-payload")
        try context.files.createDirectory(payload.appending("manifests"))
        for product in products {
            let package = product.package!
            let manifestName =
                "\(package.rawValue)-\(cohort.family.rawValue).product.json"
            try context.files.copy(
                from: candidate.appending("manifests/\(manifestName)"),
                to: payload.appending("manifests/\(manifestName)"))
        }
        try context.files.write(
            try encodedJSON(cohort),
            to: payload.appending("cohort.json"))
        try context.files.write(
            try encodedJSON(products),
            to: payload.appending("products.json"))
        let archive = candidate.appending(
            "packages/nucleus-cohort-\(cohort.canonicalVersion)-"
                + "\(cohort.architecture.rawValue)-\(cohort.family.rawValue).tar.zst")
        try await requireSuccess(
            .named("tar"),
            [
                "--zstd", "--sort=name", "--mtime=@0", "--owner=0", "--group=0",
                "--numeric-owner", "--format=posix",
                "--pax-option=delete=atime,delete=ctime", "-cf", archive.string, ".",
            ],
            workingDirectory: payload,
            environment: reproducibleEnvironment,
            context: context)
        let envelope = try ProductArtifactBuilder.createEnvelope(
            payloadRoot: payload,
            archive: archive,
            sourceClosure: source.closure,
            submoduleClosures: source.submoduleClosures,
            producingTask: LinuxTaskIDs.packageCohort(publication.architecture),
            runnerPlatform: publication.producerRunner,
            executionPlatform: .linuxARM64OCI,
            artifactTarget: ArtifactTarget(
                operatingSystem: .linux,
                architecture: publication.architecture,
                abi: "glibc"),
            toolchainIdentity: toolchainIdentity,
            nativeSDKIdentities: [
                ProductArtifactNamedIdentity(
                    name: "browser-payload",
                    digest: cohort.browserPayloadDigest),
                ProductArtifactNamedIdentity(
                    name: "runtime-payload",
                    digest: cohort.runtimeArtifactDigest),
            ],
            builderImageIdentity: builderImageIdentity,
            buildConfiguration: .release,
            semanticBuildArguments: [
                "family=\(cohort.family.rawValue)", "cohort=\(cohort.canonicalVersion)",
            ],
            executables: [],
            producerTrustDomain: producerTrustDomain,
            requiredQualificationRoles: [
                .bundleIntegrity, .nativeLinuxKernel, .physicalDRM, .physicalGPU,
                .release,
            ],
            provenance: source.provenance,
            identityPathMap: .empty)
        _ = try LocalProductArtifactStore(
            root: publication.productStoreRoot
        ).publish(
            envelope,
            payloadRoot: payload,
            archive: archive)
        try context.files.write(
            try encodedJSON(envelope),
            to: candidate.appending(
                "manifests/\(cohort.family.rawValue)-cohort.product.json"))
        try context.files.remove(payload)
        return LinuxNativePackageCohortPublication.Product(
            family: cohort.family,
            package: nil,
            archive: "packages/\(archive.lastComponent!.string)",
            archiveDigest: envelope.manifest.archiveDigest,
            productArtifact: envelope.identity)
    }
}

package func validateLinuxNativePackagePublication(
    architecture: PlatformArchitecture,
    outputRoot: FilePath,
    productStoreRoot: FilePath,
    files: ActionFileSystem
) throws {
    let current = outputRoot.appending("current")
    guard
        try files.metadataWithoutFollowingSymlinks(for: current)?.type
            == .symbolicLink
    else {
        throw LinuxNativePackageAssemblyFailure(
            "package cohort publication is missing")
    }
    let target = try files.readSymbolicLink(current)
    guard
        target.range(
            of: #"^generations/sha256-[0-9a-f]{64}$"#,
            options: .regularExpression) != nil
    else {
        throw LinuxNativePackageAssemblyFailure(
            "package cohort is not content addressed")
    }
    let generation = outputRoot.appending(target)
    let digest = try files.digest(tree: generation)
    guard target == "generations/sha256-\(digest.hexadecimal)" else {
        throw LinuxNativePackageAssemblyFailure(
            "package cohort digest does not match its contents")
    }
    let manifest: LinuxNativePackageCohortPublication = try decodeJSON(
        files.read(generation.appending("linux-native-package-cohort.json")))
    guard manifest.architecture == architecture,
        manifest.products.count
            == LinuxDistributionFamily.allCases.count
            * (LinuxNativePackageName.allCases.filter {
                $0 != .androidAddon
            }.count + 1)
    else {
        throw LinuxNativePackageAssemblyFailure(
            "package cohort publication is incomplete")
    }
    let store = LocalProductArtifactStore(root: productStoreRoot)
    for product in manifest.products {
        let archive = generation.appending(product.archive)
        guard try files.digest(file: archive) == product.archiveDigest else {
            throw LinuxNativePackageAssemblyFailure(
                "published native package was substituted: \(product.archive)")
        }
        let envelopeName =
            if let package = product.package {
                "\(package.rawValue)-\(product.family.rawValue).product.json"
            } else {
                "\(product.family.rawValue)-cohort.product.json"
            }
        let envelope: ProductArtifactEnvelope = try decodeJSON(
            files.read(generation.appending("manifests/\(envelopeName)")))
        guard envelope.identity == product.productArtifact,
            envelope.manifest.archiveDigest == product.archiveDigest
        else {
            throw LinuxNativePackageAssemblyFailure(
                "native package product envelope was substituted: \(product.archive)")
        }
        let stored = try store.validatedArtifact(
            product.productArtifact,
            provenance: envelope.provenanceIdentity)
        guard stored.envelope == envelope else {
            throw LinuxNativePackageAssemblyFailure(
                "native package product store envelope was substituted: "
                    + product.archive)
        }
    }
}

package struct LinuxNativePackageArchiveEntry: Equatable, Sendable {
    package let path: String
    package let kind: LinuxNativePackagePathKind
    package let permissions: UInt16
    package let rootOwned: Bool
    package let symbolicLinkTarget: String?
    package let configurationFile: Bool
    package let raw: String
}

package func parseLinuxNativePackageArchiveEntries(
    family: LinuxDistributionFamily,
    contents: String
) throws -> [String: LinuxNativePackageArchiveEntry] {
    var entries: [String: LinuxNativePackageArchiveEntry] = [:]
    for rawLine in contents.split(separator: "\n") {
        let raw = String(rawLine)
        let entry: LinuxNativePackageArchiveEntry?
        switch family {
        case .debian, .arch:
            entry = try parseTarArchiveEntry(
                raw,
                numericRootOwnership: family == .arch)
        case .rpm:
            entry = try parseRPMArchiveEntry(raw)
        }
        guard let entry else { continue }
        guard entries.updateValue(entry, forKey: entry.path) == nil else {
            throw LinuxNativePackageAssemblyFailure(
                "native package archive contains duplicate entry: \(entry.path)")
        }
    }
    return entries
}

private func parseTarArchiveEntry(
    _ raw: String,
    numericRootOwnership: Bool
) throws -> LinuxNativePackageArchiveEntry? {
    guard raw.count >= 10 else { return nil }
    let modeToken = String(raw.prefix(10))
    let kind: LinuxNativePackagePathKind
    switch modeToken.first {
    case "-": kind = .file
    case "d": kind = .tree
    case "l": kind = .symbolicLink
    default: return nil
    }
    let owner = raw.dropFirst(10).split(whereSeparator: { $0.isWhitespace }).first
    let pathAndTarget: String
    if let pathMarker = raw.range(of: " ./") {
        pathAndTarget = String(raw[raw.index(after: pathMarker.lowerBound)...])
    } else if let path = raw.split(whereSeparator: { $0.isWhitespace }).last {
        pathAndTarget = String(path)
    } else {
        return nil
    }
    var archivedPath = pathAndTarget
    let target: String?
    if let arrow = raw.range(of: " -> ") {
        target = String(raw[arrow.upperBound...])
        if let pathMarker = raw.range(of: " ./") {
            archivedPath = String(
                raw[raw.index(after: pathMarker.lowerBound)..<arrow.lowerBound])
        } else {
            guard
                let path = raw[..<arrow.lowerBound].split(whereSeparator: {
                    $0.isWhitespace
                }).last
            else { return nil }
            archivedPath = String(path)
        }
    } else {
        target = nil
    }
    if archivedPath.hasSuffix("/") { archivedPath.removeLast() }
    if archivedPath.hasPrefix("./") { archivedPath.removeFirst(2) }
    guard !archivedPath.isEmpty, archivedPath != "." else { return nil }
    let path = "/" + archivedPath
    return LinuxNativePackageArchiveEntry(
        path: path,
        kind: kind,
        permissions: try symbolicMode(modeToken),
        rootOwned:
            owner.map(String.init)
            == (numericRootOwnership ? "0/0" : "root/root"),
        symbolicLinkTarget: target,
        configurationFile: false,
        raw: raw)
}

private func parseRPMArchiveEntry(
    _ raw: String
) throws -> LinuxNativePackageArchiveEntry? {
    let fields = raw.split(
        maxSplits: 10,
        omittingEmptySubsequences: true,
        whereSeparator: { $0.isWhitespace })
    guard fields.count == 11, fields[0].hasPrefix("/"),
        let rawMode = UInt16(fields[4], radix: 8)
    else { return nil }
    let kind: LinuxNativePackagePathKind
    switch rawMode & 0o170000 {
    case 0o100000: kind = .file
    case 0o040000: kind = .tree
    case 0o120000: kind = .symbolicLink
    default: return nil
    }
    return LinuxNativePackageArchiveEntry(
        path: String(fields[0]),
        kind: kind,
        permissions: rawMode & 0o7777,
        rootOwned: fields[5] == "root" && fields[6] == "root",
        symbolicLinkTarget: kind == .symbolicLink ? String(fields[10]) : nil,
        configurationFile: fields[7] == "1",
        raw: raw)
}

private func symbolicMode(_ value: String) throws -> UInt16 {
    let characters = Array(value)
    guard characters.count == 10 else {
        throw LinuxNativePackageAssemblyFailure(
            "archive entry has an invalid symbolic mode: \(value)")
    }
    var mode: UInt16 = 0
    let permissions: [(Int, Character, UInt16)] = [
        (1, "r", 0o400), (2, "w", 0o200), (4, "r", 0o040),
        (5, "w", 0o020), (7, "r", 0o004), (8, "w", 0o002),
    ]
    for (index, expected, bit) in permissions where characters[index] == expected {
        mode |= bit
    }
    if "xs".contains(characters[3]) { mode |= 0o100 }
    if "xs".contains(characters[6]) { mode |= 0o010 }
    if "xt".contains(characters[9]) { mode |= 0o001 }
    if "sS".contains(characters[3]) { mode |= 0o4000 }
    if "sS".contains(characters[6]) { mode |= 0o2000 }
    if "tT".contains(characters[9]) { mode |= 0o1000 }
    let permitted: [Set<Character>] = [
        ["r", "-"], ["w", "-"], ["x", "s", "S", "-"],
        ["r", "-"], ["w", "-"], ["x", "s", "S", "-"],
        ["r", "-"], ["w", "-"], ["x", "t", "T", "-"],
    ]
    for index in 1..<10 where !permitted[index - 1].contains(characters[index]) {
        throw LinuxNativePackageAssemblyFailure(
            "archive entry has an invalid symbolic mode: \(value)")
    }
    return mode
}

package func nativeArchiveName(_ package: LinuxNativePackageManifest) -> String {
    switch package.family {
    case .debian:
        "\(package.name.rawValue)_\(package.version)_\(package.architecture).deb"
    case .rpm:
        "\(package.name.rawValue)-\(package.version).\(package.architecture).rpm"
    case .arch:
        "\(package.name.rawValue)-\(package.version)-\(package.architecture).pkg.tar.zst"
    }
}

package func debianControl(_ package: LinuxNativePackageManifest) -> String {
    var fields = [
        "Package: \(package.name.rawValue)",
        "Version: \(package.version)",
        "Architecture: \(package.architecture)",
        "Maintainer: Nucleus Project",
        "Section: misc",
        "Priority: optional",
    ]
    let dependencies = relationshipStrings(package)
    if !dependencies.isEmpty {
        fields.append("Depends: \(dependencies.joined(separator: ", "))")
    }
    if !package.conflicts.isEmpty {
        fields.append("Conflicts: \(package.conflicts.joined(separator: ", "))")
    }
    fields.append("Description: \(package.summary)")
    return fields.joined(separator: "\n") + "\n"
}

package func archPackageInfo(
    _ package: LinuxNativePackageManifest,
    installedSize: UInt64
) -> String {
    var fields = [
        "pkgname = \(package.name.rawValue)",
        "pkgbase = \(package.name.rawValue)",
        "xdata = pkgtype=pkg",
        "pkgver = \(package.version)",
        "pkgdesc = \(package.summary)",
        "url = https://github.com/nucleus-os/nucleus",
        "builddate = 0",
        "packager = Nucleus Project",
        "size = \(installedSize)",
        "arch = \(package.architecture)",
        "license = Apache-2.0",
    ]
    fields += relationshipStrings(package).map { "depend = \($0)" }
    fields += package.conflicts.map { "conflict = \($0)" }
    fields += package.configurationFiles.map {
        "backup = \($0.dropFirst())"
    }
    return fields.joined(separator: "\n") + "\n"
}

package func archBuildInfo(
    _ package: LinuxNativePackageManifest,
    assemblerIdentity: ArtifactDigest
) -> String {
    [
        "format = 2",
        "pkgname = \(package.name.rawValue)",
        "pkgbase = \(package.name.rawValue)",
        "pkgver = \(package.version)",
        "pkgarch = \(package.architecture)",
        "packager = Nucleus Project",
        "builddate = 0",
        "buildtool = collider",
        "buildtoolver = \(assemblerIdentity.description)",
    ].joined(separator: "\n") + "\n"
}

private func archInstalledSize(
    root: FilePath,
    files: ActionFileSystem
) throws -> UInt64 {
    try files.listRecursively(root).reduce(into: 0) { size, entry in
        switch entry.metadata.type {
        case .regular, .symbolicLink:
            let addition = size.addingReportingOverflow(entry.metadata.size)
            guard !addition.overflow else {
                throw LinuxNativePackageAssemblyFailure(
                    "Arch package installed size overflowed UInt64")
            }
            size = addition.partialValue
        case .directory:
            break
        case .other:
            throw LinuxNativePackageAssemblyFailure(
                "Arch package payload contains an unsupported file type: "
                    + entry.relativePath)
        }
    }
}

private func archMTree(
    root: FilePath,
    files: ActionFileSystem
) throws -> String {
    let entries = try files.listRecursively(root).sorted {
        $0.relativePath.utf8.lexicographicallyPrecedes($1.relativePath.utf8)
    }
    var lines = ["#mtree"]
    for entry in entries {
        var fields = [
            "./\(mtreeEscaped(entry.relativePath))",
            "uid=0",
            "gid=0",
            "mode=\(octalMode(entry.metadata.permissions))",
        ]
        switch entry.metadata.type {
        case .regular:
            fields.append("type=file")
            fields.append("size=\(entry.metadata.size)")
            fields.append(
                "sha256digest=\(try files.digest(file: entry.path).hexadecimal)")
        case .directory:
            fields.append("type=dir")
        case .symbolicLink:
            fields.append("type=link")
            fields.append(
                "link=\(mtreeEscaped(try files.readSymbolicLink(entry.path)))")
        case .other:
            throw LinuxNativePackageAssemblyFailure(
                "Arch package payload contains an unsupported file type: "
                    + entry.relativePath)
        }
        lines.append(fields.joined(separator: " "))
    }
    return lines.joined(separator: "\n") + "\n"
}

private func octalMode(_ value: UInt16) -> String {
    let digits = String(value & 0o7777, radix: 8)
    return String(repeating: "0", count: max(0, 4 - digits.count)) + digits
}

private func mtreeEscaped(_ value: String) -> String {
    value.utf8.map { byte -> String in
        switch byte {
        case 0x21...0x22, 0x24...0x3c, 0x3e...0x5b, 0x5d...0x7e:
            return String(UnicodeScalar(byte))
        default:
            let digits = String(byte, radix: 8)
            return "\\" + String(repeating: "0", count: 3 - digits.count) + digits
        }
    }.joined()
}

package func rpmSpec(_ package: LinuxNativePackageManifest) -> String {
    let versionParts = package.version.split(separator: "-", maxSplits: 1)
    let version = String(versionParts[0])
    let release = versionParts.count == 2 ? String(versionParts[1]) : "1"
    var headers = [
        "Name: \(package.name.rawValue)",
        "Version: \(version)",
        "Release: \(release)",
        "Summary: \(package.summary)",
        "License: Apache-2.0",
        "BuildArch: \(package.architecture)",
    ]
    headers += relationshipStrings(package).map { "Requires: \($0)" }
    headers += package.conflicts.map { "Conflicts: \($0)" }
    let files = package.ownedPaths.map { path in
        var directives: [String] = []
        if path.configurationFile {
            directives.append("%config(noreplace)")
        }
        if let permissions = path.permissions {
            let digits = String(permissions, radix: 8)
            let mode = String(repeating: "0", count: max(0, 4 - digits.count)) + digits
            directives.append("%attr(\(mode),root,root)")
        }
        directives.append(path.path)
        return directives.joined(separator: " ")
    }
    return
        "%global __os_install_post %{nil}\n"
        + headers.joined(separator: "\n")
        + "\n\n%description\n\(package.summary)\n"
        + "\n%prep\n%build\n%install\n"
        + "cp -a %{_sourcedir}/root/. %{buildroot}/\n"
        + rpmLifecycle(package)
        + "\n%files\n%defattr(-,root,root,-)\n"
        + files.joined(separator: "\n") + "\n"
}

private func relationshipStrings(_ package: LinuxNativePackageManifest) -> [String] {
    package.relationships.map { relationship in
        guard relationship.requirement == .exactCohort,
            let version = relationship.version
        else { return relationship.package }
        switch package.family {
        case .debian: return "\(relationship.package) (= \(version))"
        case .rpm: return "\(relationship.package) = \(version)"
        case .arch: return "\(relationship.package)=\(version)"
        }
    }
}

private func rpmLifecycle(_ package: LinuxNativePackageManifest) -> String {
    var sections = ""
    if !package.lifecycle.afterInstall.isEmpty {
        sections += "\n%post\n" + safeLifecycle(package.lifecycle.afterInstall)
    }
    if !package.lifecycle.afterRemove.isEmpty {
        sections += "\n%postun\n" + safeLifecycle(package.lifecycle.afterRemove)
    }
    return sections
}

private func archInstallScript(_ package: LinuxNativePackageManifest) -> String {
    var script = ""
    if !package.lifecycle.afterInstall.isEmpty {
        script +=
            "post_install() {\n"
            + safeLifecycle(
                package.lifecycle.afterInstall) + "}\n"
        script += "post_upgrade() { post_install; }\n"
    }
    if !package.lifecycle.afterRemove.isEmpty {
        script +=
            "post_remove() {\n"
            + safeLifecycle(
                package.lifecycle.afterRemove) + "}\n"
    }
    return script
}

private func safeLifecycle(_ commands: [String]) -> String {
    commands.map { command in
        let executable = command.split(separator: " ").first.map(String.init) ?? ""
        return "command -v \(executable) >/dev/null 2>&1 && \(command) || true\n"
    }.joined()
}

private func writeMaintainerScripts(
    _ package: LinuxNativePackageManifest,
    to control: FilePath,
    files: ActionFileSystem
) throws {
    let scripts: [(String, [String])] = [
        ("postinst", package.lifecycle.afterInstall),
        ("postrm", package.lifecycle.afterRemove),
    ]
    for (name, commands) in scripts where !commands.isEmpty {
        let path = control.appending(name)
        try files.write(
            Array(("#!/bin/sh\nset -e\n" + safeLifecycle(commands)).utf8),
            to: path)
        try files.setPermissions(0o755, for: path)
    }
}

private func validateMaterializedRoot(
    _ package: LinuxNativePackageManifest,
    root: FilePath,
    files: ActionFileSystem
) throws {
    for path in package.ownedPaths {
        let installed = try installedLinuxPackagePath(path.path, in: root)
        guard let metadata = try files.metadataWithoutFollowingSymlinks(for: installed)
        else {
            throw LinuxNativePackageAssemblyFailure(
                "package root is missing declared path: \(path.path)")
        }
        let expected: ActionFileSystem.FileType =
            switch path.kind {
            case .file: .regular
            case .symbolicLink: .symbolicLink
            case .tree: .directory
            }
        guard metadata.type == expected else {
            throw LinuxNativePackageAssemblyFailure(
                "package path has wrong type: \(path.path)")
        }
        if let permissions = path.permissions,
            metadata.permissions & 0o7777 != permissions
        {
            throw LinuxNativePackageAssemblyFailure(
                "package path has wrong permissions: \(path.path) expected "
                    + "\(String(permissions, radix: 8)), found "
                    + "\(String(metadata.permissions & 0o7777, radix: 8))")
        }
        if let target = path.symbolicLinkTarget,
            try files.readSymbolicLink(installed) != target
        {
            throw LinuxNativePackageAssemblyFailure(
                "package symlink has wrong target: \(path.path)")
        }
    }
}

private func copyTree(
    _ source: FilePath,
    to destination: FilePath,
    files: ActionFileSystem
) throws {
    try files.createDirectory(destination.removingLastComponent())
    try files.copyTree(from: source, to: destination)
}

private let reproducibleEnvironment = [
    "LANG": "C.UTF-8",
    "LC_ALL": "C.UTF-8",
    "SOURCE_DATE_EPOCH": "0",
]

package func nativePackageSubprocessEnvironment(
    _ overrides: [String: String],
    inheriting parent: [String: String] = ProcessInfo.processInfo.environment
) -> [String: String] {
    let fakerootNames = [
        "FAKED_MODE",
        "FAKEROOTKEY",
        "LD_LIBRARY_PATH",
        "LD_PRELOAD",
    ]
    var environment = parent.filter { fakerootNames.contains($0.key) }
    environment.merge(overrides) { _, override in override }
    return environment
}

@discardableResult
private func requireSuccess(
    _ executable: CommandSpec.Executable,
    _ arguments: [String],
    workingDirectory: FilePath? = nil,
    environment: [String: String] = [:],
    context: ActionContext
) async throws -> CommandResult {
    let result = try await context.commands.execute(
        CommandSpec(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory ?? FilePath("/"),
            environment: nativePackageSubprocessEnvironment(environment),
            output: .captured(limit: 4 * 1_024 * 1_024)))
    guard result.succeeded else {
        throw result.executionFailure(
            reason: "Linux native package command failed")
    }
    return result
}

private func encodedJSON<T: Encodable>(_ value: T) throws -> [UInt8] {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [
        .prettyPrinted, .sortedKeys, .withoutEscapingSlashes,
    ]
    var bytes = Array(try encoder.encode(value))
    bytes.append(0x0a)
    return bytes
}

private func decodeJSON<T: Decodable>(_ bytes: [UInt8]) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(bytes))
}

private struct LinuxNativePackageAssemblyFailure: Error,
    CustomStringConvertible, Sendable
{
    let description: String

    init(_ description: String) {
        self.description = "Linux native package assembly failed: \(description)"
    }
}
