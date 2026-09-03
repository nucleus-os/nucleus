import ColliderCore
import ColliderRuntime
import Foundation

#if os(macOS)
import ContainerAPIClient
import ContainerCommands

struct AppleContainerImageBuilder: Sendable {
    func build(_ preparation: OCIImagePreparation) async throws -> String {
        try validateOCIPlatform(preparation.executionPlatform)
        let configuration = try await Application.loadContainerSystemConfig()
        if preparation.baseImageSource == .local {
            let base = try ociLocalBaseImage(preparation)
            let image = try await ClientImage.get(
                reference: base.sourceReference,
                containerSystemConfig: configuration)
            guard image.digest == base.digest else {
                throw AppleContainerFailure.invalidImageDigest
            }
            let tagged = try await image.tag(new: base.buildReference)
            guard tagged.digest == base.digest else {
                throw AppleContainerFailure.invalidImageDigest
            }
        }
        let command = try Application.BuildCommand.parse(
            appleContainerBuildArguments(preparation))
        try await command.run()

        let image = try await ClientImage.get(
            reference: preparation.imageName,
            containerSystemConfig: configuration)
        guard image.digest.hasPrefix("sha256:"), image.digest.count == 71 else {
            throw AppleContainerFailure.invalidImageDigest
        }
        return preparation.imageName + "\n" + image.digest
    }
}

func appleContainerBuildArguments(
    _ preparation: OCIImagePreparation
) -> [String] {
    var arguments = [
        "--platform", ociPlatformName(preparation.executionPlatform),
        "--network", "none",
        // Successful BuildKit, package-install, export, and unpack progress is
        // mechanical task detail. In append-only CI it otherwise bypasses the
        // task reporter and permanently expands one catalog step by thousands
        // of lines. Build failures still propagate through the owning task.
        "--quiet",
    ]
    if preparation.baseImageSource == .registry {
        arguments.append("--pull")
    }
    arguments += [
        "--progress", "plain",
        "--tag", preparation.imageName,
        "--file", preparation.containerFile.string,
        preparation.context.string,
    ]
    return arguments
}
#endif
