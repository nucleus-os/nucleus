import ColliderCore
import Foundation
import SystemPackage

struct AOSPSigningIdentityPreparation: Hashable, Sendable {
    let destination: FilePath
    let subject: String
    let environment: [String: String]
}

struct PrepareAOSPSigningIdentityAction: ColliderAction {
    struct Identity: ColliderActionIdentity {
        let destination: FilePath
        let subject: String

        func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: destination.string)
            encoder.append(tag: 2, string: subject)
        }
    }

    static let kind: ActionKind = "android-runtime.prepare-aosp-signing-identity"

    let preparation: AOSPSigningIdentityPreparation

    var identity: Identity {
        Identity(
            destination: preparation.destination,
            subject: preparation.subject)
    }

    var requirements: ActionRequirements {
        ActionRequirements(
            tools: [
                ActionToolRequirement(
                    "openssl",
                    executable: .named("openssl"),
                    role: .semantic)
            ],
            effects: [
                ActionEffect(
                    .readWrite,
                    scope: .output(preparation.destination.removingLastComponent()))
            ])
    }

    var environment: [String: String] { preparation.environment }

    func execute(in context: ActionContext) async throws {
        let workflow = AOSPSigningIdentityWorkflow(context: context)
        if try context.files.metadata(for: preparation.destination) != nil {
            let identity = try await workflow.validate(preparation)
            try context.files.write(
                Array(try JSONEncoder().encode(identity)),
                to: preparation.destination.appending("signing-identity.json"))
            return
        }

        let parent = preparation.destination.removingLastComponent()
        try context.files.createDirectory(parent)
        let candidate = parent.appending(".signing-identity-candidate")
        try context.files.remove(candidate)
        defer { try? context.files.remove(candidate) }
        try context.files.createDirectory(candidate)

        var certificates: [AOSPSigningIdentity.Certificate] = []
        for alias in aospSigningAliases {
            let base = candidate.appending(alias)
            let privateKey = FilePath(base.string + ".pem")
            let certificate = FilePath(base.string + ".x509.pem")
            let pkcs8 = FilePath(base.string + ".pk8")
            try await workflow.run(
                [
                    "genpkey",
                    "-algorithm", "RSA",
                    "-pkeyopt", "rsa_keygen_bits:4096",
                    "-out", privateKey.string,
                ],
                in: candidate,
                environment: preparation.environment)
            try await workflow.run(
                [
                    "req",
                    "-new",
                    "-x509",
                    "-sha256",
                    "-key", privateKey.string,
                    "-out", certificate.string,
                    "-days", "3650",
                    "-subj", preparation.subject + "/CN=Nucleus Android \(alias)",
                ],
                in: candidate,
                environment: preparation.environment)
            try await workflow.run(
                [
                    "pkcs8",
                    "-in", privateKey.string,
                    "-topk8",
                    "-outform", "DER",
                    "-out", pkcs8.string,
                    "-nocrypt",
                ],
                in: candidate,
                environment: preparation.environment)
            try context.files.setPermissions(0o600, for: privateKey)
            try context.files.setPermissions(0o600, for: pkcs8)
            certificates.append(
                AOSPSigningIdentity.Certificate(
                    alias: alias,
                    x509SHA256: try context.files.digest(file: certificate).hexadecimal))
        }

        let identity = AOSPSigningIdentity(
            purpose: "local-development",
            subject: preparation.subject,
            certificates: certificates)
        try context.files.write(
            Array(try JSONEncoder().encode(identity)),
            to: candidate.appending("signing-identity.json"))
        try context.files.move(from: candidate, to: preparation.destination)
        _ = try await workflow.validate(preparation)
    }
}

struct AOSPSigningIdentityWorkflow {
    let context: ActionContext

    func validate(
        _ preparation: AOSPSigningIdentityPreparation
    ) async throws -> AOSPSigningIdentity {
        try await validate(
            at: preparation.destination,
            expectedSubject: preparation.subject,
            environment: preparation.environment)
    }

    func validate(
        at destination: FilePath,
        expectedSubject: String? = nil,
        environment: [String: String]
    ) async throws -> AOSPSigningIdentity {
        let identityPath = destination.appending(
            "signing-identity.json")
        let identity = try JSONDecoder().decode(
            AOSPSigningIdentity.self,
            from: Data(try context.files.read(identityPath)))
        guard identity.purpose == "local-development",
            expectedSubject.map({ identity.subject == $0 }) ?? true,
            identity.certificates.map(\.alias) == aospSigningAliases
        else {
            throw AOSPSigningIdentityFailure.invalidMetadata
        }

        let validation = destination.appending(".validation")
        try context.files.remove(validation)
        try context.files.createDirectory(validation)
        defer { try? context.files.remove(validation) }
        for item in identity.certificates {
            let base = destination.appending(item.alias)
            let privateKey = FilePath(base.string + ".pem")
            let certificate = FilePath(base.string + ".x509.pem")
            let pkcs8 = FilePath(base.string + ".pk8")
            for path in [privateKey, certificate, pkcs8] {
                guard try context.files.metadata(for: path)?.type == .regular else {
                    throw AOSPSigningIdentityFailure.missingKeyMaterial(path)
                }
            }
            guard
                try context.files.digest(file: certificate).hexadecimal
                    == item.x509SHA256
            else {
                throw AOSPSigningIdentityFailure.changedCertificate(certificate)
            }

            let certificatePEM = validation.appending(
                "\(item.alias)-certificate-public.pem")
            let certificateDER = validation.appending(
                "\(item.alias)-certificate-public.der")
            let privateDER = validation.appending(
                "\(item.alias)-private-public.der")
            try await run(
                [
                    "x509", "-in", certificate.string,
                    "-pubkey", "-noout", "-out", certificatePEM.string,
                ],
                in: destination,
                environment: environment)
            try await run(
                [
                    "pkey", "-pubin", "-in", certificatePEM.string,
                    "-outform", "DER", "-out", certificateDER.string,
                ],
                in: destination,
                environment: environment)
            try await run(
                [
                    "pkey", "-in", privateKey.string, "-pubout",
                    "-outform", "DER", "-out", privateDER.string,
                ],
                in: destination,
                environment: environment)
            guard try context.files.contentsEqual(at: certificateDER, and: privateDER)
            else {
                throw AOSPSigningIdentityFailure.keyMismatch(item.alias)
            }
        }
        return identity
    }

    func run(
        _ arguments: [String],
        in directory: FilePath,
        environment: [String: String]
    ) async throws {
        let result = try await context.commands.execute(
            CommandSpec(
                executable: .named("openssl"),
                arguments: arguments,
                workingDirectory: directory,
                environment: environment,
                output: .captured(limit: 32 * 1_024 * 1_024)))
        guard result.status == 0 else {
            let detail = result.standardOutput.trimmingCharacters(
                in: .whitespacesAndNewlines)
            throw AOSPSigningIdentityFailure.commandFailed(
                arguments.first ?? "openssl",
                detail)
        }
    }
}

let aospSigningAliases = [
    "releasekey",
    "platform",
    "shared",
    "media",
    "networkstack",
]

struct AOSPSigningIdentity: Codable {
    struct Certificate: Codable {
        let alias: String
        let x509SHA256: String
    }

    let purpose: String
    let subject: String
    let certificates: [Certificate]
}

private enum AOSPSigningIdentityFailure: Error, CustomStringConvertible {
    case invalidMetadata
    case missingKeyMaterial(FilePath)
    case changedCertificate(FilePath)
    case keyMismatch(String)
    case commandFailed(String, String)

    var description: String {
        switch self {
        case .invalidMetadata:
            "AOSP signing identity metadata is invalid"
        case .missingKeyMaterial(let path):
            "AOSP signing key material is missing: \(path)"
        case .changedCertificate(let path):
            "AOSP signing certificate digest changed: \(path)"
        case .keyMismatch(let alias):
            "AOSP signing certificate does not match its private key: \(alias)"
        case .commandFailed(let command, let detail):
            "\(command) failed" + (detail.isEmpty ? "" : ": \(detail)")
        }
    }
}
