import Foundation
import SystemPackage

/// Adds one operational entrypoint to an immutable local dependency image.
/// The dependency image remains reusable when only the entrypoint changes.
public protocol OCIEntrypointImageActionKind: Sendable {
    static var actionKind: ActionKind { get }
}

public struct PrepareOCIEntrypointImageAction<Kind: OCIEntrypointImageActionKind>:
    ColliderAction
{
    public struct Identity: ColliderActionIdentity {
        let baseImageID: FilePath
        let entrypoint: FilePath
        let entrypointDestination: String
        let generatedContext: FilePath
        let preparation: OCIImagePreparation

        public func encode(into encoder: inout ActionIdentityEncoder) {
            encoder.append(tag: 1, string: baseImageID.string)
            encoder.append(tag: 2, string: entrypoint.string)
            encoder.append(tag: 3, string: entrypointDestination)
            encoder.append(tag: 4, string: generatedContext.string)
            encoder.append(
                tag: 5,
                nested: OCIImagePreparationActionIdentity(preparation))
        }
    }

    public static var kind: ActionKind { Kind.actionKind }

    private let baseImageID: FilePath
    private let entrypoint: FilePath
    private let entrypointDestination: String
    private let generatedContext: FilePath
    private let preparation: OCIImagePreparation

    public init(
        baseImageID: FilePath,
        entrypoint: FilePath,
        entrypointDestination: String,
        generatedContext: FilePath,
        preparation: OCIImagePreparation
    ) {
        self.baseImageID = baseImageID
        self.entrypoint = entrypoint
        self.entrypointDestination = entrypointDestination
        self.generatedContext = generatedContext
        self.preparation = preparation
    }

    public var identity: Identity {
        Identity(
            baseImageID: baseImageID,
            entrypoint: entrypoint,
            entrypointDestination: entrypointDestination,
            generatedContext: generatedContext,
            preparation: preparation)
    }

    public var requirements: ActionRequirements {
        ActionRequirements(
            effects: [
                ActionEffect(.read, scope: .input(baseImageID)),
                ActionEffect(.read, scope: .input(entrypoint)),
                ActionEffect(.readWrite, scope: .scratch(generatedContext)),
                ActionEffect(.readWrite, scope: .scratch(candidateContext)),
                ActionEffect(.readWrite, scope: .output(preparation.imageID)),
            ],
            lane: .hostExclusive,
            executionPlatform: preparation.executionPlatform)
    }

    public var environment: [String: String] { preparation.environment }

    public func execute(in context: ActionContext) async throws {
        guard preparation.baseImageSource == .local,
            preparation.localBaseImageID == baseImageID
        else {
            throw OCIEntrypointImageFailure.invalidPreparation
        }
        let destination = FilePath(entrypointDestination).lexicallyNormalized()
        guard entrypointDestination.hasPrefix("/"),
            destination.string == entrypointDestination,
            entrypointDestination != "/",
            !entrypointDestination.split(separator: "/").contains("..")
        else {
            throw OCIEntrypointImageFailure.invalidDestination(
                entrypointDestination)
        }
        let identifier = String(
            decoding: try context.files.read(baseImageID),
            as: UTF8.self)
        let components = identifier.split(whereSeparator: \.isNewline)
            .map(String.init)
        guard components.count == 2 else {
            throw OCIEntrypointImageFailure.invalidBaseImage
        }
        let name = components[0]
        let digest = components[1]
        guard name.hasPrefix("localhost/"),
            !name.contains(where: { $0.isWhitespace || $0 == "@" }),
            !name.contains(":"),
            digest.hasPrefix("sha256:"),
            digest.count == 71,
            digest.dropFirst("sha256:".count).allSatisfy({ $0.isHexDigit })
        else {
            throw OCIEntrypointImageFailure.invalidBaseImage
        }

        try context.files.remove(candidateContext)
        defer { try? context.files.remove(candidateContext) }
        try context.files.createDirectory(candidateContext)
        let digestTag = "digest-" + digest.dropFirst("sha256:".count)
        let containerFile =
            "FROM \(name):\(digestTag)\n\n"
            + "COPY --chmod=0755 entrypoint \(entrypointDestination)\n\n"
            + "ENTRYPOINT [\"\(entrypointDestination)\"]\n"
        try context.files.write(
            Array(containerFile.utf8),
            to: candidateContext.appending("Containerfile"))
        try context.files.copy(
            from: entrypoint,
            to: candidateContext.appending("entrypoint"))
        try context.files.remove(generatedContext)
        try context.files.move(from: candidateContext, to: generatedContext)
        try await context.containers.prepareImage(preparation)
    }

    public func validateOutputs(using files: ActionFileSystem) throws {
        guard try files.metadata(for: preparation.imageID)?.type == .regular else {
            throw OCIEntrypointImageFailure.missingImageID
        }
    }

    private var candidateContext: FilePath {
        generatedContext.removingLastComponent().appending(
            "\(generatedContext.lastComponent?.string ?? "entrypoint-context").candidate")
    }
}

private enum OCIEntrypointImageFailure: Error, CustomStringConvertible {
    case invalidPreparation
    case invalidDestination(String)
    case invalidBaseImage
    case missingImageID

    var description: String {
        switch self {
        case .invalidPreparation:
            "entrypoint image must use a local content-addressed base"
        case .invalidDestination(let destination):
            "invalid OCI entrypoint destination: \(destination)"
        case .invalidBaseImage:
            "base image ID is not a content-addressed localhost image"
        case .missingImageID:
            "entrypoint image ID is missing"
        }
    }
}
