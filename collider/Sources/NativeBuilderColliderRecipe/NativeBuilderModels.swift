import ColliderCore
import SystemPackage

/// One Linux artifact lane produced inside the canonical ARM64 builder guest.
/// The produced architecture never determines which host executables run.
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

    /// Whether producing this target inside the canonical ARM64 builder guest
    /// is a cross compilation. The guest is always ARM64, so an ARM64 target
    /// builds natively and an x86_64 target does not.
    package var isCrossCompiledInBuilder: Bool {
        architecture == .x86_64
    }

    /// The CPU family meson names this architecture by, which is not always
    /// what Nucleus names it.
    package var mesonCPUFamily: String {
        switch architecture {
        case .arm64: "aarch64"
        case .x86_64: "x86_64"
        }
    }

    package var artifactTarget: ArtifactTarget {
        switch architecture {
        case .arm64: .linuxARM64
        case .x86_64: .linuxX86_64
        }
    }

    package var containerSwiftSDKRoot: String {
        "/swift-sdk/nucleus-swift-6.4-linux.artifactbundle/swift-linux/"
            + targetTriple + "/" + NucleusLinuxABI.sdkDirectoryName
    }

    package var containerLibCXXIncludeRoot: String {
        containerSwiftSDKRoot + "/usr/include/c++/v1"
    }

    package var containerLibCXXLibraryRoot: String {
        containerSwiftSDKRoot + "/usr/lib/" + gnuArchitecture
    }

}

/// The rootless native builder image and its host-owned mutable caches. This
/// bootstrap configuration deliberately does not name a target Swift SDK: the
/// image is required to produce that SDK.
package struct NativeOCIBaseConfiguration: Sendable {
    package let image: ArtifactReference
    package let swiftPMOverlay: ArtifactReference
    package let ccache: FilePath
    package let environment: [String: String]
    package let swiftPMOverlayRevision: String

    package init(
        image: ArtifactReference,
        swiftPMOverlay: ArtifactReference,
        ccache: FilePath,
        environment: [String: String],
        swiftPMOverlayRevision: String
    ) {
        self.image = image
        self.swiftPMOverlay = swiftPMOverlay
        self.ccache = ccache
        self.environment = environment
        self.swiftPMOverlayRevision = swiftPMOverlayRevision
    }

    package var imageID: FilePath { image.path }
}

/// A native builder equipped with the generated target Swift SDK. Every native
/// consumer receives the typed activation artifact rather than rediscovering
/// its publication through a raw cache path.
package enum NativeOCIConfigurationFailure: Error, CustomStringConvertible {
    case missingPackageRootView(String)

    package var description: String {
        switch self {
        case .missingPackageRootView(let identifier):
            "no package root view was declared for \(identifier)"
        }
    }
}

package struct NativeOCIConfiguration: Sendable {
    package let base: NativeOCIBaseConfiguration
    package let swiftSDK: ArtifactReference

    package let packageRootViews: [String: ArtifactReference]

    package init(
        base: NativeOCIBaseConfiguration,
        swiftSDK: ArtifactReference,
        packageRootViews: [String: ArtifactReference] = [:]
    ) {
        self.base = base
        self.swiftSDK = swiftSDK
        self.packageRootViews = packageRootViews
    }

    /// The package-root view a lane mounts, which must exist: a lane whose
    /// view was never declared would otherwise silently mount the checkout.
    package func packageRootView(_ identifier: String) throws -> ArtifactReference {
        guard let view = packageRootViews[identifier] else {
            throw NativeOCIConfigurationFailure.missingPackageRootView(identifier)
        }
        return view
    }

    package var image: ArtifactReference { base.image }
    package var imageID: FilePath { base.imageID }
    package var swiftPMOverlay: ArtifactReference { base.swiftPMOverlay }
    package var ccache: FilePath { base.ccache }
    package func ccache(for target: NativeLinuxTarget) -> FilePath {
        base.ccache.appending(target.identifier)
    }
    package var swiftSDKRoot: FilePath { swiftSDK.path }
    package var environment: [String: String] { base.environment }
    package var swiftPMOverlayRevision: String { base.swiftPMOverlayRevision }
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
