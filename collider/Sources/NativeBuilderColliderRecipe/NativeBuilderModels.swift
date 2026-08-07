import ColliderCore
import SystemPackage

/// One Linux artifact lane produced inside the canonical ARM64 builder guest.
/// The guest remains ARM64 for both lanes; x86_64 target execution opts into
/// Intel binary translation explicitly.
package struct NativeLinuxTarget: Hashable, Sendable {
    package let architecture: PlatformArchitecture

    package init(architecture: PlatformArchitecture) {
        precondition(architecture == .arm64 || architecture == .x86_64)
        self.architecture = architecture
    }

    package var identifier: String {
        "linux-\(architecture.rawValue)"
    }

    package var targetTriple: String {
        switch architecture {
        case .arm64: "aarch64-unknown-linux-gnu"
        case .x86_64: "x86_64-unknown-linux-gnu"
        }
    }

    package var gnuArchitecture: String {
        switch architecture {
        case .arm64: "aarch64-linux-gnu"
        case .x86_64: "x86_64-linux-gnu"
        }
    }

    package var artifactTarget: ArtifactTarget {
        switch architecture {
        case .arm64: .linuxARM64
        case .x86_64: .linuxX86_64
        }
    }

    package var intelBinaryTranslationPolicy: OCIIntelBinaryTranslationPolicy {
        architecture == .x86_64 ? .required : .disabled
    }

    package var containerSwiftSDKRoot: String {
        "/swift-sdk/nucleus-swift-6.4-linux.artifactbundle/swift-linux/"
            + targetTriple + "/" + NucleusLinuxABI.sdkDirectoryName
    }

    package var containerRuntimeLibraryPath: String {
        "\(containerSwiftSDKRoot)/usr/lib/\(gnuArchitecture):"
            + "\(containerSwiftSDKRoot)/lib/\(gnuArchitecture)"
    }
}

/// The rootless native builder image and its host-owned mutable caches. This
/// bootstrap configuration deliberately does not name a target Swift SDK: the
/// image is required to produce that SDK.
package struct NativeOCIBaseConfiguration: Sendable {
    package let context: FilePath
    package let image: ArtifactReference<FileArtifact>
    package let ccache: FilePath
    package let environment: [String: String]

    package init(
        context: FilePath,
        image: ArtifactReference<FileArtifact>,
        ccache: FilePath,
        environment: [String: String]
    ) {
        self.context = context
        self.image = image
        self.ccache = ccache
        self.environment = environment
    }

    package var imageID: FilePath { image.path }
}

/// A native builder equipped with the generated target Swift SDK. Every native
/// consumer receives the typed activation artifact rather than rediscovering
/// its publication through a raw cache path.
package struct NativeOCIConfiguration: Sendable {
    package let base: NativeOCIBaseConfiguration
    package let swiftSDK: ArtifactReference<PathArtifact>

    package init(
        base: NativeOCIBaseConfiguration,
        swiftSDK: ArtifactReference<PathArtifact>
    ) {
        self.base = base
        self.swiftSDK = swiftSDK
    }

    package var context: FilePath { base.context }
    package var image: ArtifactReference<FileArtifact> { base.image }
    package var imageID: FilePath { base.imageID }
    package var ccache: FilePath { base.ccache }
    package var swiftSDKRoot: FilePath { swiftSDK.path }
    package var environment: [String: String] { base.environment }
}

package struct NativeBuilderGraphConfiguration: RecipeConfiguration {
    package let builder: NativeOCIConfiguration
    package let nativeSDKRoot: FilePath
    package let targetArtifacts: [NativeLinuxTarget: ArtifactReferenceSet]

    package init(
        builder: NativeOCIConfiguration,
        nativeSDKRoot: FilePath,
        targetArtifacts: [NativeLinuxTarget: ArtifactReferenceSet] = [:]
    ) {
        self.builder = builder
        self.nativeSDKRoot = nativeSDKRoot
        self.targetArtifacts = targetArtifacts
    }

    package func nativeSDK(for target: NativeLinuxTarget) -> FilePath {
        nativeSDKRoot.appending(target.identifier)
    }

    package func artifacts(for target: NativeLinuxTarget) throws
        -> ArtifactReferenceSet
    {
        guard let artifacts = targetArtifacts[target] else {
            throw NativeBuilderGraphConfigurationFailure.missingTargetArtifacts(target)
        }
        return artifacts
    }
}

package enum NativeBuilderGraphConfigurationFailure: Error,
    CustomStringConvertible, Sendable
{
    case missingTargetArtifacts(NativeLinuxTarget)

    package var description: String {
        switch self {
        case .missingTargetArtifacts(let target):
            "target artifacts for '\(target.identifier)' are not declared"
        }
    }
}
