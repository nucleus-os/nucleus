import ChromiumColliderRecipe
import ColliderCore
import ShellColliderRecipe
import SystemPackage
import Testing

@testable import LinuxColliderRecipe
@testable import LinuxPackageAssembly
@testable import LinuxPackageContracts

@Test func nativePackageSubprocessesPreserveOnlyTheFakerootSession() {
    let environment = nativePackageSubprocessEnvironment(
        [
            "LANG": "C.UTF-8",
            "LD_PRELOAD": "explicit-fakeroot.so",
        ],
        inheriting: [
            "FAKED_MODE": "unknown-is-root",
            "FAKEROOTKEY": "42",
            "LD_LIBRARY_PATH": "/fakeroot",
            "LD_PRELOAD": "libfakeroot-sysv.so",
            "NUCLEUS_SECRET": "must-not-leak",
            "PATH": "/host/path",
        ])

    #expect(
        environment == [
            "FAKED_MODE": "unknown-is-root",
            "FAKEROOTKEY": "42",
            "LANG": "C.UTF-8",
            "LD_LIBRARY_PATH": "/fakeroot",
            "LD_PRELOAD": "explicit-fakeroot.so",
        ])
}

@Test func nativeBuilderIdentityMountRetainsTheImageIDAsARegularFile() {
    #expect(
        nativeBuilderIdentityMountRoot(FilePath("/cache/native/image-id"))
            == FilePath("/cache/native"))
}

@Test func nativePackageCohortsSplitOwnershipAndBindExactRelationships() throws {
    for family in LinuxDistributionFamily.allCases {
        let runtime = runtimeManifest(family: family, architecture: .arm64)
        let browser = browserManifest(architecture: .arm64)
        let cohort = try LinuxNativePackageCohortContract(
            runtime: runtime,
            browser: browser,
            architecture: .arm64)

        #expect(
            cohort.manifest.packages.map(\.name) == [
                .runtime, .session, .browser, .developmentHost, .complete,
            ])
        #expect(cohort.manifest.runtimeArtifactDigest.description == runtime.artifactDigest)
        #expect(cohort.manifest.browserPayloadDigest == browser.payloadDigest)
        #expect(Set(cohort.manifest.packages.map(\.version)).count == 1)

        let session = try #require(
            cohort.manifest.packages.first { $0.name == .session })
        #expect(session.configurationFiles == ["/etc/pam.d/nucleus"])
        #expect(
            session.relationships == [
                LinuxNativePackageRelationship(
                    package: "nucleus-runtime",
                    requirement: .exactCohort,
                    version: session.version)
            ])

        let browserPackage = try #require(
            cohort.manifest.packages.first { $0.name == .browser })
        let browserDependencies = Set(browserPackage.relationships.map(\.package))
        #expect(
            browserDependencies.contains("pango") || browserDependencies.contains("libpango-1.0-0"))
        #expect(
            browserDependencies.contains("systemd-libs") || browserDependencies.contains("libudev1")
        )
        #expect(
            browserPackage.ownedPaths.contains {
                $0.path == "/usr/libexec/nucleus-browser/chrome-sandbox"
                    && $0.permissions == 0o4755
            })
        #expect(
            browserPackage.ownedPaths.contains {
                $0.path.hasSuffix(browser.payloadDigest.hexadecimal)
                    && $0.kind == .tree
            })

        let complete = try #require(
            cohort.manifest.packages.first { $0.name == .complete })
        #expect(
            Set(complete.relationships.map(\.package)) == [
                "nucleus-runtime", "nucleus-session", "nucleus-browser",
            ])
        #expect(
            complete.relationships.allSatisfy {
                $0.requirement == .exactCohort && $0.version == complete.version
            })
    }
}

@Test func nativePackageCohortIdentityChangesWithEitherImmutableInput() throws {
    let runtime = runtimeManifest(family: .debian, architecture: .x86_64)
    let browser = browserManifest(architecture: .x86_64)
    let baseline = try LinuxNativePackageCohortContract(
        runtime: runtime,
        browser: browser,
        architecture: .x86_64)
    let changedRuntime = try LinuxNativePackageCohortContract(
        runtime: runtimeManifest(
            family: .debian,
            architecture: .x86_64,
            digestByte: "b"),
        browser: browser,
        architecture: .x86_64)
    let changedBrowser = try LinuxNativePackageCohortContract(
        runtime: runtime,
        browser: browserManifest(
            architecture: .x86_64,
            payloadByte: "d"),
        architecture: .x86_64)

    #expect(
        Set([
            baseline.manifest.canonicalVersion,
            changedRuntime.manifest.canonicalVersion,
            changedBrowser.manifest.canonicalVersion,
        ]).count == 3)
}

@Test func nativePackageCohortRejectsCrossArchitectureSubstitution() throws {
    #expect(throws: (any Error).self) {
        _ = try LinuxNativePackageCohortContract(
            runtime: runtimeManifest(family: .rpm, architecture: .arm64),
            browser: browserManifest(architecture: .x86_64),
            architecture: .arm64)
    }
}

@Test func runtimePackageInputBindsTheExactActiveGenerationAndDigest() throws {
    let digest = ArtifactDigest(
        sha256Hex: String(repeating: "a", count: 64))!
    let manifest = runtimeManifest(family: .debian, architecture: .arm64)

    try validateRuntimePackageInput(
        manifest,
        activeGeneration: String(repeating: "a", count: 24),
        activeDigest: digest)
    #expect(throws: (any Error).self) {
        try validateRuntimePackageInput(
            manifest,
            activeGeneration: String(repeating: "b", count: 24),
            activeDigest: digest)
    }
    #expect(throws: (any Error).self) {
        try validateRuntimePackageInput(
            manifest,
            activeGeneration: String(repeating: "a", count: 24),
            activeDigest: ArtifactDigest(
                sha256Hex: String(repeating: "b", count: 64))!)
    }
}

@Test func nativePackageMetadataBindsFamilyVersionsAndArchitectures() throws {
    for family in LinuxDistributionFamily.allCases {
        let cohort = try LinuxNativePackageCohortContract(
            runtime: runtimeManifest(family: family, architecture: .x86_64),
            browser: browserManifest(architecture: .x86_64),
            architecture: .x86_64)
        let complete = try #require(
            cohort.manifest.packages.first { $0.name == .complete })
        let runtime = try #require(
            cohort.manifest.packages.first { $0.name == .runtime })
        let archive = nativeArchiveName(runtime)
        switch family {
        case .debian:
            #expect(complete.architecture == "all")
            #expect(archive.hasSuffix("_amd64.deb"))
            #expect(
                debianControl(complete).contains(
                    "nucleus-runtime (= \(complete.version))"))
        case .rpm:
            #expect(complete.architecture == "noarch")
            #expect(archive.hasSuffix(".x86_64.rpm"))
        case .arch:
            #expect(complete.architecture == "any")
            #expect(archive.hasSuffix("-x86_64.pkg.tar.zst"))
            #expect(
                archPackageInfo(complete, installedSize: 123).contains(
                    "depend = nucleus-runtime=\(complete.version)"))
            #expect(
                archPackageInfo(complete, installedSize: 123).contains(
                    "size = 123"))
            #expect(
                archPackageInfo(complete, installedSize: 123).contains(
                    "xdata = pkgtype=pkg"))
        }
    }
}

@Test func archBuildInfoNamesTheActualAssemblerIdentity() throws {
    let package = try LinuxNativePackageCohortContract(
        runtime: runtimeManifest(family: .arch, architecture: .arm64),
        browser: browserManifest(architecture: .arm64),
        architecture: .arm64
    ).manifest.packages[0]
    let identity = ArtifactDigest(
        sha256Hex: String(repeating: "e", count: 64))!
    let buildInfo = archBuildInfo(package, assemblerIdentity: identity)

    #expect(buildInfo.contains("format = 2"))
    #expect(buildInfo.contains("buildtool = collider"))
    #expect(buildInfo.contains("buildtoolver = \(identity.description)"))
}

@Test func rpmSpecDeclaresExactOwnedPathModes() throws {
    let package = try LinuxNativePackageCohortContract(
        runtime: runtimeManifest(family: .rpm, architecture: .x86_64),
        browser: browserManifest(architecture: .x86_64),
        architecture: .x86_64
    ).manifest.packages.first { $0.name == .browser }
    let browser = try #require(package)

    #expect(
        rpmSpec(browser).hasPrefix("%global __os_install_post %{nil}\n"))
    #expect(
        rpmSpec(browser).contains(
            "%attr(4755,root,root) /usr/libexec/nucleus-browser/chrome-sandbox"))
}

@Test func packageArchiveEntriesPreserveExactFamilyMetadata() throws {
    let fixtures: [(LinuxDistributionFamily, String, Bool)] = [
        (
            .debian,
            "-rwsr-xr-x root/root 25088 1970-01-01 00:00 ./usr/libexec/nucleus-browser/chrome-sandbox",
            false
        ),
        (
            .rpm,
            "/usr/libexec/nucleus-browser/chrome-sandbox 25088 1786877379 d75481de 0104755 root root 0 0 0 X",
            false
        ),
        (
            .arch,
            "-rwsr-xr-x 0/0 25088 1970-01-01 00:00 usr/libexec/nucleus-browser/chrome-sandbox",
            false
        ),
        (
            .rpm,
            "/etc/pam.d/nucleus 72 1786877366 b72f6015 0100644 root root 1 0 0 X",
            true
        ),
    ]
    for (family, contents, configurationFile) in fixtures {
        let entries = try parseLinuxNativePackageArchiveEntries(
            family: family,
            contents: contents)
        let path =
            configurationFile
            ? "/etc/pam.d/nucleus"
            : "/usr/libexec/nucleus-browser/chrome-sandbox"
        let entry = try #require(entries[path])
        #expect(entry.kind == .file)
        #expect(entry.permissions == (configurationFile ? 0o644 : 0o4755))
        #expect(entry.rootOwned)
        #expect(entry.configurationFile == configurationFile)
    }
}

@Test func packageArchiveEntriesPreserveSymlinkTargets() throws {
    let target = "/opt/nucleus/generations/f22d664f93c0ef44565b9a34"
    let fixtures: [(LinuxDistributionFamily, String)] = [
        (
            .debian,
            "lrwxr-xr-x root/root 0 1970-01-01 00:00 ./opt/nucleus/current -> \(target)"
        ),
        (
            .rpm,
            "/opt/nucleus/current 49 1786877366 00000000 0120755 root root 0 0 0 \(target)"
        ),
        (
            .arch,
            "lrwxr-xr-x 0/0 0 1970-01-01 00:00 opt/nucleus/current -> \(target)"
        ),
    ]
    for (family, contents) in fixtures {
        let entry = try #require(
            parseLinuxNativePackageArchiveEntries(
                family: family,
                contents: contents
            )["/opt/nucleus/current"])
        #expect(entry.kind == .symbolicLink)
        #expect(entry.permissions == 0o755)
        #expect(entry.rootOwned)
        #expect(entry.symbolicLinkTarget == target)
    }
}

@Test func packagePathsMustBeAbsoluteNormalizedAndContained() throws {
    #expect(
        try validatedLinuxPackageAbsolutePath("/usr/lib/nucleus/file")
            == FilePath("/usr/lib/nucleus/file"))
    for unsafe in [
        "", "/", "usr/lib/nucleus", "/usr//lib/nucleus", "/usr/./lib/nucleus",
        "/usr/lib/../etc", "/usr/lib/nucleus/", "/usr/lib/nucleus bad",
    ] {
        #expect(throws: (any Error).self) {
            _ = try validatedLinuxPackageAbsolutePath(unsafe)
        }
    }

    try validateLinuxPackageSymlinkTarget(
        "../lib/nucleus-browser/current/bin/nucleus-browser",
        at: "/usr/bin/nucleus-browser")
    #expect(throws: (any Error).self) {
        try validateLinuxPackageSymlinkTarget(
            "../../../../outside",
            at: "/usr/bin/nucleus-browser")
    }
    #expect(throws: (any Error).self) {
        try validateLinuxPackageSymlinkTarget(
            "../lib/nucleus-browser/current/..",
            at: "/usr/bin/nucleus-browser")
    }
    #expect(throws: (any Error).self) {
        try validateLinuxPackageSymlinkTarget(
            "../lib/other/../nucleus-browser",
            at: "/usr/bin/nucleus-browser")
    }
}

private func runtimeManifest(
    family: LinuxDistributionFamily,
    architecture: PlatformArchitecture,
    digestByte: Character = "a"
) -> LinuxDistributionPackageManifest {
    let adapter = LinuxDistributionPackageAdapter(family: family)
    let digest = "sha256:" + String(repeating: digestByte, count: 64)
    let generation = "/opt/nucleus/generations/" + String(repeating: digestByte, count: 24)
    return LinuxDistributionPackageManifest(
        family: family,
        architecture: adapter.packageArchitecture(architecture),
        artifactDigest: digest,
        runtimeRoot: LinuxDistributionPackageAdapter.runtimeRoot,
        runtimeGeneration: generation,
        seatPolicy: "systemd-logind",
        capabilityPackages: ["wayland": ["wayland"]],
        dependencies: ["bash", "wayland"],
        installations: [
            LinuxPackageInstallation(
                source: ".",
                destination: generation,
                kind: .tree,
                target: nil,
                contents: nil),
            LinuxPackageInstallation.symbolicLink(
                LinuxDistributionPackageAdapter.runtimeRoot,
                target: generation),
            LinuxPackageInstallation.file(
                "/etc/pam.d/nucleus",
                contents: "auth include common-auth\naccount include common-account\n"),
        ],
        removals: [
            "/etc/pam.d/nucleus", LinuxDistributionPackageAdapter.runtimeRoot,
            generation,
        ])
}

private func browserManifest(
    architecture: PlatformArchitecture,
    payloadByte: Character = "c"
) -> BrowserPackageInputManifest {
    let payload = ArtifactDigest(
        sha256Hex: String(repeating: payloadByte, count: 64))!
    return BrowserPackageInputManifest(
        artifactTarget: ArtifactTarget(
            operatingSystem: .linux,
            architecture: architecture,
            abi: "glibc"),
        payloadDigest: payload,
        payloadGeneration: "generations/sha256-\(payload.hexadecimal)",
        buildManifestDigest: ArtifactDigest(
            sha256Hex: String(repeating: "e", count: 64))!)
}
