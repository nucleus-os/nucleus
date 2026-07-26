struct AndroidForwardPatch: Codable, Equatable {
    let path: String
    let sha256: String
}

struct AndroidForwardPatchStack: Codable, Equatable {
    let repositoryPath: String
    let baseCommit: String
    let patchedCommit: String
    let patchedTree: String
    let patches: [AndroidForwardPatch]
}

struct AndroidImageProvenance: Decodable, Equatable {
    struct Image: Decodable, Equatable {
        let name: String
        let size: UInt64
        let storageFormat: String
        let sha256: String
    }

    let status: String
    let product: String
    let release: String
    let variant: String
    let buildNumber: String
    let buildTimestamp: UInt64
    let platformSDK: UInt32
    let vendorAPILevel: UInt32
    let sourceManifestCommit: String
    let sourceBaseManifestSHA256: String
    let sourceManifestSHA256: String
    let sourceForwardPatches: [AndroidForwardPatchStack]
    let productTreeSHA256: String
    let images: [Image]
}

struct AndroidSourceProvenance: Decodable, Equatable {
    let status: String
    let manifestCommit: String
    let baseResolvedManifestSHA256: String
    let resolvedManifestSHA256: String
    let forwardPatches: [AndroidForwardPatchStack]
}

struct AndroidPatchManifest: Decodable, Equatable {
    struct Repository: Decodable, Equatable {
        let path: String
        let patches: [String]
    }

    let repositories: [Repository]
}

struct AndroidSourceLock: Decodable, Equatable {
    struct Platform: Decodable, Equatable {
        let manifestCommit: String
    }

    let platform: Platform
}

struct AndroidProductLock: Decodable, Equatable {
    let product: String
    let release: String
    let variant: String
    let buildNumber: String
    let buildTimestamp: UInt64
    let platformSDK: UInt32
    let vendorAPILevel: UInt32
}

func androidImageStalenessReason(
    image: AndroidImageProvenance,
    source: AndroidSourceProvenance,
    patchManifest: AndroidPatchManifest,
    patchDigests: [String],
    sourceManifestCommit: String,
    productLock: AndroidProductLock,
    productTreeSHA256: String
) -> String? {
    guard source.status == "materialized" else {
        return "current AOSP source provenance is not materialized"
    }
    guard source.manifestCommit == sourceManifestCommit else {
        return "current AOSP source provenance does not match aosp.lock.json"
    }
    guard image.sourceManifestCommit == source.manifestCommit,
        image.sourceBaseManifestSHA256
            == source.baseResolvedManifestSHA256,
        image.sourceManifestSHA256 == source.resolvedManifestSHA256,
        image.sourceForwardPatches == source.forwardPatches
    else {
        return "published images do not match the current AOSP source"
    }
    guard patchManifest.repositories.count == source.forwardPatches.count
    else {
        return "current AOSP source provenance does not match patches.json"
    }
    var digestIndex = 0
    for (repository, stack) in zip(
        patchManifest.repositories,
        source.forwardPatches)
    {
        guard repository.path == stack.repositoryPath,
            repository.patches == stack.patches.map(\.path)
        else {
            return "current AOSP source provenance does not match patches.json"
        }
        for patch in stack.patches {
            guard digestIndex < patchDigests.count,
                patch.sha256 == patchDigests[digestIndex]
            else {
                return "current AOSP source provenance contains a stale patch digest"
            }
            digestIndex += 1
        }
    }
    guard digestIndex == patchDigests.count else {
        return "current AOSP patch digest inventory is inconsistent"
    }
    guard image.product == productLock.product,
        image.release == productLock.release,
        image.variant == productLock.variant,
        image.buildNumber == productLock.buildNumber,
        image.buildTimestamp == productLock.buildTimestamp,
        image.platformSDK == productLock.platformSDK,
        image.vendorAPILevel == productLock.vendorAPILevel
    else {
        return "published images do not match aosp-product.lock.json"
    }
    guard image.productTreeSHA256 == productTreeSHA256 else {
        return "published images do not match the current product definition"
    }
    return nil
}
