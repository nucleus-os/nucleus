import ColliderCore
import ColliderRuntime
import Foundation

#if os(macOS)
import ContainerAPIClient
import ContainerCommands

struct AppleContainerImageBuilder: Sendable {
    func build(_ preparation: OCIImagePreparation) async throws -> String {
        try validateOCIPlatform(preparation.executionPlatform)
        let command = try Application.BuildCommand.parse(
            appleContainerBuildArguments(preparation))
        try await command.run()

        let configuration = try await Application.loadContainerSystemConfig()
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
    [
        "--platform", ociPlatformName(preparation.executionPlatform),
        "--network", "none",
        "--pull",
        "--progress", "plain",
        "--tag", preparation.imageName,
        "--file", preparation.containerFile.string,
        preparation.context.string,
    ]
}
#endif
