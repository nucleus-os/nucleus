import ColliderCore
import ColliderProcess
import ColliderRuntime
import Foundation
import SystemPackage

// MARK: - Declared provisioning states

/// Whether the hidden builder account exists on this host.
enum BuilderAccountPresence: String, Sendable, CaseIterable {
    case absent
    case present
}

/// Whether the root-owned runner LaunchDaemon is loaded.
enum BuilderServicePresence: String, Sendable, CaseIterable {
    case absent
    case present
}

/// How far an interrupted provisioning run progressed before it stopped.
enum BuilderRecoveryState: String, Sendable, CaseIterable {
    case absent
    case preArtifact = "pre-artifact"
    case unregistered
    case registered
}

/// The complete local provisioning state this host presents.
enum BuilderLocalState: String, Sendable, CaseIterable {
    case fresh
    case preArtifact = "pre-artifact"
    case unregistered
    case registered
    case complete
    case inconsistent
}

/// The runner registration the protected runner group presents.
enum BuilderRunnerState: String, Sendable, CaseIterable {
    case fresh
    case complete
    case inconsistent
}

/// The single provisioning step that both states admit.
enum BuilderProvisioningAction: String, Sendable, CaseIterable {
    case provision
    case finalize
    case inconsistent
}

/// Provisioning never replaces or guesses at partial state, so only the exact
/// combinations a supported interruption can produce resolve to a local state.
func builderLocalState(
    account: BuilderAccountPresence,
    service: BuilderServicePresence,
    recovery: BuilderRecoveryState
) -> BuilderLocalState {
    switch (account, service, recovery) {
    case (.absent, .absent, .absent): .fresh
    case (.present, .present, .absent): .complete
    case (.present, .absent, .preArtifact): .preArtifact
    case (.present, .absent, .unregistered): .unregistered
    case (.present, .absent, .registered): .registered
    default: .inconsistent
    }
}

/// An empty group admits provisioning; exactly the declared runner admits
/// finalization. Any other membership stops for recovery.
func builderRunnerState(
    registeredNames: [String],
    expected: String
) -> BuilderRunnerState {
    if registeredNames.isEmpty { return .fresh }
    if registeredNames == [expected] { return .complete }
    return .inconsistent
}

func builderProvisioningAction(
    local: BuilderLocalState,
    runner: BuilderRunnerState
) -> BuilderProvisioningAction {
    switch (local, runner) {
    case (.fresh, .fresh), (.preArtifact, .fresh), (.unregistered, .fresh): .provision
    // A completed host finalizes again rather than only verifying. Finalization
    // is convergent and ends in verification, so a contract that gains declared
    // machine state installs it by re-running the commission.
    case (.registered, .complete), (.complete, .complete): .finalize
    default: .inconsistent
    }
}

// MARK: - GitHub control-plane payloads

private struct GitHubRunnerGroupList: Decodable {
    let runnerGroups: [GitHubRunnerGroup]
}

private struct GitHubRunnerGroup: Decodable {
    let id: Int
    let name: String
    let visibility: String
    let restrictedToWorkflows: Bool
    let selectedWorkflows: [String]?
}

private struct GitHubRunnerList: Decodable {
    let runners: [GitHubRunner]
}

private struct GitHubRunner: Decodable {
    struct Label: Decodable { let name: String }

    let id: Int
    let name: String
    let status: String
    let busy: Bool
    let labels: [Label]
}

private struct GitHubRepositoryList: Decodable {
    let repositories: [GitHubRepository]
}

private struct GitHubRepository: Decodable {
    let id: Int
}

private struct GitHubRegistrationToken: Decodable {
    let token: String
}

private struct InstalledRunnerRegistration: Decodable {
    let agentName: String
    let poolName: String
    let workFolder: String
}

// MARK: - Provisioning

/// Unprivileged orchestration of the macOS builder identity.
///
/// Collider owns the pinned host acquisition, the local and GitHub state
/// contract, and the control-plane reconciliation. Every privileged mutation
/// stays in the root-owned scripts this type invokes through `sudo`, which
/// keeps the privilege boundary and the language boundary on the same seam.
struct MacOSBuilderProvisioning {
    enum Operation: String, CaseIterable, Sendable {
        case prepare
        case commission
        case retire
    }

    private let context: WorkspaceContext
    private let contract: MacOSBuilderContract
    private let layout: MacOSHostStorageLayout
    private let organization = "nucleus-os"
    private let repositoryName = "nucleus"
    private let workflow = "nucleus-os/nucleus/.github/workflows/ci.yml@refs/heads/main"

    init(context: WorkspaceContext) throws {
        self.context = context
        contract = try MacOSBuilderContract.load(root: context.root)
        layout = try MacOSHostStorageLayout.current()
    }

    func run(_ operation: Operation) async throws {
        try validateInteractiveDeveloper()
        switch operation {
        case .prepare: try await prepare()
        case .commission: try await commission()
        case .retire: try await retire()
        }
    }

    // MARK: Prepare

    private func prepare() async throws {
        try validateCanonicalCheckout()
        try FileManager.default.createDirectory(
            atPath: layout.provisioning.string,
            withIntermediateDirectories: true)
        if try validatedArchive() == nil {
            try stage("downloading the pinned Actions runner archive")
            guard
                let digest = ArtifactDigest(sha256Hex: contract.builder.runnerArchiveSHA256),
                let url = URL(string: contract.builder.runnerArchiveURL)
            else {
                throw WorkspaceFailure.message(
                    "pinned runner archive download specification is invalid")
            }
            try await context.runtime.download(
                DownloadSpec(
                    url: url,
                    permittedRedirectOrigins: [
                        "https://objects.githubusercontent.com",
                        "https://release-assets.githubusercontent.com",
                    ],
                    expectedDigest: digest,
                    maximumResponseSize: Int64(contract.builder.runnerArchiveSize),
                    acceptedMediaTypes: ["application/octet-stream"]),
                to: archivePath)
        }
        guard try validatedArchive() != nil else {
            throw WorkspaceFailure.message(
                "pinned GitHub Actions runner archive failed verification")
        }
        try stage("prepared and verified GitHub Actions runner \(contract.builder.runnerVersion)")
        try context.console.human("archive: \(archivePath.string)")
    }

    // MARK: Commission

    private func commission() async throws {
        try stage("validating local inputs")
        try validateCanonicalCheckout()
        guard try validatedArchive() != nil else {
            throw WorkspaceFailure.message(
                "prepared runner archive is absent or drifted: \(archivePath.string); "
                    + "run 'collider provision macos-builder prepare'")
        }
        try validateProvisioningScripts()

        let local = try await localState()
        guard local != .inconsistent else {
            throw WorkspaceFailure.message(
                "local builder provisioning is partial; inspect it before retrying")
        }

        try stage("validating GitHub authorization")
        try await validateOrganizationAuthorization()

        try stage("reconciling the protected runner group")
        let groupID = try await reconciledRunnerGroup()

        let registeredNames = try await runnerNames(inGroup: groupID)
        let runner = builderRunnerState(
            registeredNames: registeredNames,
            expected: contract.builder.runnerName)
        let action = builderProvisioningAction(local: local, runner: runner)
        guard action != .inconsistent else {
            throw WorkspaceFailure.message(
                "local state is \(local.rawValue) but runner-group state is "
                    + "\(runner.rawValue); provisioning never replaces or guesses "
                    + "at partial state")
        }

        switch action {
        case .provision:
            try stage("provisioning the isolated builder identity")
            let token = try await registrationToken()
            try await sudoScript(
                "provision-nucleus-builder.sh",
                arguments: [archivePath.string],
                standardInput: Array("\(token)\n".utf8))
        case .finalize:
            try stage("reconciling and verifying the trusted host identity")
            try await sudoScript("finalize-nucleus-builder.sh")
        case .inconsistent:
            throw WorkspaceFailure.message("unreachable provisioning action")
        }

        try stage("waiting for the registered runner")
        let registered = try await awaitOnlineRunner()
        guard registered.labels.contains(where: { $0.name == contract.builder.runnerLabel })
        else {
            throw WorkspaceFailure.message("provisioned runner label is absent")
        }
        guard try await runnerNames(inGroup: groupID) == [contract.builder.runnerName] else {
            throw WorkspaceFailure.message("runner group membership drifted")
        }
        try stage("all local and GitHub gates passed")
        try context.console.human(
            "commission complete: runner group and trusted host identity are live")
    }

    // MARK: Retire

    private func retire() async throws {
        try stage("validating GitHub authorization")
        try await validateOrganizationAuthorization()

        let registered = try await organizationRunner()
        if let registered {
            guard !registered.busy else {
                throw WorkspaceFailure.message(
                    "the runner is executing a job; drain it before retiring")
            }
        }

        try stage("retiring the installed runner service and machine-wide state")
        try await sudoScript("retire-nucleus-builder.sh")

        if let registered {
            try stage("removing the organization runner registration")
            try await gh([
                "api", "--method", "DELETE",
                "orgs/\(organization)/actions/runners/\(registered.id)",
            ])
        }

        guard try await organizationRunner() == nil else {
            throw WorkspaceFailure.message("organization runner registration survived retirement")
        }
        let local = try await localState()
        guard local == .preArtifact || local == .fresh else {
            throw WorkspaceFailure.message(
                "local state after retirement is \(local.rawValue); commission resumes "
                    + "only from pre-artifact or fresh")
        }
        try stage("retirement complete; local state is \(local.rawValue)")
        try context.console.human(
            "commission re-provisions at the declared roots; the builder account, its "
                + "source ACLs, per-user Collider storage, and container service remain")
    }

    // MARK: Local state

    private func localState() async throws -> BuilderLocalState {
        let account: BuilderAccountPresence =
            await directoryServicesRecordExists() ? .present : .absent
        let service: BuilderServicePresence =
            await launchDaemonIsLoaded() ? .present : .absent
        guard account == .present, service == .absent else {
            return builderLocalState(account: account, service: service, recovery: .absent)
        }
        return builderLocalState(
            account: account,
            service: service,
            recovery: try recoveryState())
    }

    private func recoveryState() throws -> BuilderRecoveryState {
        let finalizationFootprint = [
            contract.builder.hostContractRoot,
            runnerPlistPath.string,
            "/usr/local/bin/collider",
            "/usr/local/bin/nucleus-builder-run",
        ].contains(where: pathExists)

        let home = contract.builder.home
        if isSymbolicLink(home) { return .absent }
        if FileManager.default.fileExists(atPath: home),
            !builderHomeIsProvisioned(
                try ownership(of: home), user: contract.builder.user)
        {
            return .absent
        }

        let runnerRoot = contract.builder.runnerRoot
        guard pathExists(runnerRoot) else {
            return finalizationFootprint ? .absent : .preArtifact
        }
        guard !isSymbolicLink(runnerRoot),
            isDirectory(runnerRoot),
            FileManager.default.isExecutableFile(atPath: runnerRoot + "/config.sh")
        else { return .absent }

        let rootOwnership = try ownership(of: runnerRoot)
        let hasRegistration = pathExists(runnerRoot + "/.runner")
        let hasCredentials = pathExists(runnerRoot + "/.credentials")
        if rootOwnership
            == BuilderOwnership(
                user: contract.builder.user, group: contract.builder.group,
                permissions: 0o755),
            !finalizationFootprint,
            !hasRegistration,
            !hasCredentials
        {
            return .unregistered
        }
        if rootOwnership == BuilderOwnership(user: "root", group: "wheel", permissions: 0o755),
            hasRegistration,
            hasCredentials,
            pathExists(runnerRoot + "/.credentials_rsaparams"),
            let registration = try? installedRegistration(),
            registration.agentName == contract.builder.runnerName,
            registration.poolName == contract.builder.runnerGroup
        {
            return .registered
        }
        return .absent
    }

    private func installedRegistration() throws -> InstalledRunnerRegistration {
        try JSONDecoder().decode(
            InstalledRunnerRegistration.self,
            from: Data(contentsOf: URL(fileURLWithPath: contract.builder.runnerRoot + "/.runner")))
    }

    private func directoryServicesRecordExists() async -> Bool {
        await commandSucceeds("/usr/bin/dscl", [".", "-read", "/Users/\(contract.builder.user)"])
    }

    private func launchDaemonIsLoaded() async -> Bool {
        await commandSucceeds(
            "/bin/launchctl", ["print", "system/\(contract.builder.runnerServiceLabel)"])
    }

    // MARK: GitHub control plane

    private func validateOrganizationAuthorization() async throws {
        guard await commandSucceeds("/usr/bin/which", ["gh"]) else {
            throw WorkspaceFailure.message("gh is required to reconcile the runner group")
        }
        let status = String(
            decoding: try await githubResponse(
                ["auth", "status", "-h", "github.com"], mergingStandardError: true),
            as: UTF8.self)
        guard
            status.split(separator: "\n")
                .contains(where: { $0.contains("Token scopes:") && $0.contains("'admin:org'") })
        else {
            throw WorkspaceFailure.message(
                "GitHub authorization must include admin:org; "
                    + "run: gh auth refresh -h github.com -s admin:org")
        }
    }

    private func reconciledRunnerGroup() async throws -> Int {
        let repositoryID = try await ghDecode(
            GitHubRepository.self, ["api", "repos/\(organization)/\(repositoryName)"]
        ).id
        let existing = try await ghDecode(
            GitHubRunnerGroupList.self, ["api", "orgs/\(organization)/actions/runner-groups"]
        ).runnerGroups.first { $0.name == contract.builder.runnerGroup }

        let groupID: Int
        if let existing {
            try await gh(
                [
                    "api", "--method", "PATCH",
                    "orgs/\(organization)/actions/runner-groups/\(existing.id)",
                ]
                    + runnerGroupFields)
            groupID = existing.id
        } else {
            groupID = try await ghDecode(
                GitHubRunnerGroup.self,
                ["api", "--method", "POST", "orgs/\(organization)/actions/runner-groups"]
                    + runnerGroupFields
            ).id
        }
        try await gh([
            "api", "--method", "PUT",
            "orgs/\(organization)/actions/runner-groups/\(groupID)/repositories",
            "-F", "selected_repository_ids[]=\(repositoryID)",
        ])

        let reconciled = try await ghDecode(
            GitHubRunnerGroup.self,
            ["api", "orgs/\(organization)/actions/runner-groups/\(groupID)"])
        guard reconciled.visibility == "selected" else {
            throw WorkspaceFailure.message("runner group visibility drifted")
        }
        guard reconciled.restrictedToWorkflows else {
            throw WorkspaceFailure.message("runner group workflow restriction is disabled")
        }
        guard reconciled.selectedWorkflows?.contains(workflow) == true else {
            throw WorkspaceFailure.message("runner group workflow allowlist drifted")
        }
        let repositories = try await ghDecode(
            GitHubRepositoryList.self,
            ["api", "orgs/\(organization)/actions/runner-groups/\(groupID)/repositories"]
        ).repositories.map(\.id)
        guard repositories == [repositoryID] else {
            throw WorkspaceFailure.message("runner group repository allowlist drifted")
        }
        return groupID
    }

    private var runnerGroupFields: [String] {
        [
            "-f", "name=\(contract.builder.runnerGroup)",
            "-f", "visibility=selected",
            "-F", "allows_public_repositories=true",
            "-F", "restricted_to_workflows=true",
            "-f", "selected_workflows[]=\(workflow)",
        ]
    }

    private func runnerNames(inGroup group: Int) async throws -> [String] {
        try await ghDecode(
            GitHubRunnerList.self,
            ["api", "orgs/\(organization)/actions/runner-groups/\(group)/runners"]
        ).runners.map(\.name)
    }

    private func organizationRunner() async throws -> GitHubRunner? {
        try await ghDecode(
            GitHubRunnerList.self, ["api", "orgs/\(organization)/actions/runners"]
        ).runners.first { $0.name == contract.builder.runnerName }
    }

    /// The registration token travels from this call to the privileged
    /// boundary on standard input only, never through argv or the environment.
    private func registrationToken() async throws -> String {
        let token = try await JSONDecoder().decode(
            GitHubRegistrationToken.self,
            from: try githubResponse([
                "api", "--method", "POST",
                "orgs/\(organization)/actions/runners/registration-token",
            ])
        ).token
        guard !token.isEmpty else {
            throw WorkspaceFailure.message("issued runner registration token is empty")
        }
        return token
    }

    private func awaitOnlineRunner() async throws -> GitHubRunner {
        for _ in 0..<60 {
            if let runner = try await organizationRunner(), runner.status == "online" {
                return runner
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw WorkspaceFailure.message("provisioned runner did not register and come online")
    }

    /// Runs `gh` and returns its response without routing it through the
    /// logging runtime.
    ///
    /// Control-plane responses are decoded into typed values, so none of them
    /// needs to be echoed, and one carries a registration token that must never
    /// reach the terminal or the durable run log. That is why this captures
    /// rather than routing through the logging runtime.
    ///
    /// Was in the deadlock class: standard output was read to end of file
    /// before standard error. The argument that excused it — that `gh` writes
    /// less to standard error than a pipe buffer holds — was an assumption
    /// about a third-party tool's output, and concurrent draining removes the
    /// need to make it.
    private func githubResponse(
        _ arguments: [String],
        mergingStandardError: Bool = false
    ) async throws -> Data {
        let capture = try await CapturedChildProcess.capture(
            executable: FilePath("/usr/bin/env"),
            arguments: ["gh"] + arguments,
            workingDirectory: context.root,
            environment: sanitizedEnvironment(context.environment),
            combiningStandardError: mergingStandardError)
        guard !mergingStandardError else {
            return Data(capture.standardOutput)
        }
        guard capture.status == 0 else {
            throw WorkspaceFailure.message(
                "gh \(arguments.prefix(2).joined(separator: " ")) failed: "
                    + capture.standardErrorText)
        }
        return Data(capture.standardOutput)
    }

    @discardableResult
    private func gh(_ arguments: [String]) async throws -> String {
        String(decoding: try await githubResponse(arguments), as: UTF8.self)
    }

    private func ghDecode<Value: Decodable>(
        _ type: Value.Type,
        _ arguments: [String]
    ) async throws -> Value {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try await decoder.decode(Value.self, from: try githubResponse(arguments))
    }

    // MARK: Privileged boundary

    /// Every privileged mutation stays in a root-owned script. Collider passes
    /// short-lived secrets on standard input so they never reach argv or the
    /// child environment, and leaves the terminal available to `sudo`.
    private func sudoScript(
        _ name: String,
        arguments: [String] = [],
        standardInput: [UInt8]? = nil
    ) async throws {
        let script = scriptPath(name).string
        if let standardInput {
            try await context.run(
                "/usr/bin/sudo", [script] + arguments,
                input: .bytes(standardInput),
                output: .inherited)
            return
        }
        try await context.run("/usr/bin/sudo", [script] + arguments, terminal: true)
    }

    private func validateProvisioningScripts() throws {
        for script in [
            "builder-machine-root.sh",
            "finalize-nucleus-builder.sh",
            "provision-nucleus-builder.sh",
            "retire-nucleus-builder.sh",
            "verify-nucleus-builder.sh",
        ] {
            guard FileManager.default.isExecutableFile(atPath: scriptPath(script).string) else {
                throw WorkspaceFailure.message(
                    "required provisioning input is not executable: \(script)")
            }
        }
    }

    // MARK: Host inputs

    private func validateInteractiveDeveloper() throws {
        guard getuid() != 0 else {
            throw WorkspaceFailure.message(
                "run builder provisioning as the interactive developer, not as root")
        }
        guard NSUserName() == contract.builder.developerUser else {
            throw WorkspaceFailure.message(
                "builder provisioning must run as \(contract.builder.developerUser)")
        }
    }

    private func validateCanonicalCheckout() throws {
        let declared = contract.builder.authoritativeCheckout
        let resolved = URL(fileURLWithPath: declared).resolvingSymlinksInPath().path
        guard resolved == declared,
            FileManager.default.fileExists(atPath: declared + "/Package.swift")
        else {
            throw WorkspaceFailure.message(
                "authoritative checkout is not canonical: \(declared)")
        }
    }

    private var archivePath: FilePath {
        layout.provisioning.appending(
            "actions-runner-osx-arm64-\(contract.builder.runnerVersion).tar.gz")
    }

    /// The prepared archive, or `nil` when it is absent or has drifted from the
    /// pinned size and digest.
    private func validatedArchive() throws -> FilePath? {
        guard let contents = FileManager.default.contents(atPath: archivePath.string) else {
            return nil
        }
        guard contents.count == Int(contract.builder.runnerArchiveSize),
            ArtifactDigest.sha256(contents).hexadecimal
                == contract.builder.runnerArchiveSHA256
        else { return nil }
        return archivePath
    }

    private var runnerPlistPath: FilePath {
        FilePath("/Library/LaunchDaemons")
            .appending("\(contract.builder.runnerServiceLabel).plist")
    }

    private func scriptPath(_ name: String) -> FilePath {
        context.root.appending("tools/macos-builder/\(name)")
    }

    private func stage(_ message: String) throws {
        try context.console.diagnostic("provision: \(message)")
    }

    /// Not in the deadlock class: both streams are discarded, so there was
    /// never a pipe to drain. Converted for singularity of mechanism, so no
    /// layer keeps a reason to build a process by hand.
    private func commandSucceeds(
        _ executable: String,
        _ arguments: [String]
    ) async -> Bool {
        guard
            let status = try? await CapturedChildProcess.status(
                executable: FilePath(executable),
                arguments: arguments)
        else { return false }
        return status == 0
    }
}

// MARK: - Filesystem contracts

/// Whether a home directory is one provisioning established: owned by the
/// builder and private to it.
///
/// The group is deliberately excluded. Provisioning assigns the dedicated
/// group, so requiring it here would make a host that predates that assignment
/// resolve as inconsistent and refuse the very run that would fix it.
/// Verification asserts the primary group after provisioning, which is the
/// point at which it is established.
func builderHomeIsProvisioned(_ ownership: BuilderOwnership, user: String) -> Bool {
    ownership.user == user && ownership.permissions == 0o700
}

struct BuilderOwnership: Equatable {
    let user: String
    let group: String
    let permissions: Int
}

private func ownership(of path: String) throws -> BuilderOwnership {
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    return BuilderOwnership(
        user: attributes[.ownerAccountName] as? String ?? "",
        group: attributes[.groupOwnerAccountName] as? String ?? "",
        permissions: (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0)
}

private func isSymbolicLink(_ path: String) -> Bool {
    (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) != nil
}

private func isDirectory(_ path: String) -> Bool {
    (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey]).isDirectory)
        == true
}

/// Existence that a dangling symbolic link also satisfies, matching the
/// provisioning scripts' `-e || -L` staging probes.
private func pathExists(_ path: String) -> Bool {
    FileManager.default.fileExists(atPath: path) || isSymbolicLink(path)
}
