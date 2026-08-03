import ColliderCore
import Foundation
import SystemPackage

func requiredDRMRenderNode(environment: [String: String]) throws -> String {
    let fileManager = FileManager.default
    let candidates: [String]
    if let explicit = environment["NUCLEUS_TEST_DRM_RENDER_NODE"],
        !explicit.isEmpty
    {
        candidates = [explicit]
    } else {
        candidates =
            (try? fileManager.contentsOfDirectory(atPath: "/dev/dri"))?.filter {
                $0.hasPrefix("renderD")
            }
            .sorted()
            .map { "/dev/dri/\($0)" } ?? []
    }
    guard
        let path = candidates.first(where: {
            guard fileManager.isReadableFile(atPath: $0),
                fileManager.isWritableFile(atPath: $0),
                let attributes = try? fileManager.attributesOfItem(atPath: $0),
                attributes[.type] as? FileAttributeType == .typeCharacterSpecial
            else { return false }
            return true
        })
    else {
        throw WorkspaceFailure.message(
            "gpu-drm requires a readable and writable /dev/dri/renderD* node; "
                + "set NUCLEUS_TEST_DRM_RENDER_NODE to the required node")
    }
    return path
}
