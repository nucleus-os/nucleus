import ColliderCore
import ColliderRuntime
import Foundation

struct OCIImageOutputValidator {
    private struct Image: Hashable {
        let repository: String
        let digest: String
    }

    private let latestImages: Set<Image>

    init(images: [OCIImageState]) {
        latestImages = Set(
            images.lazy.filter { $0.tag == "latest" }.map {
                Image(repository: $0.repository, digest: $0.digest)
            })
    }

    func validate(_ task: TaskDeclaration) throws {
        guard let action = task.action else { return }
        let outputPaths = Set(task.outputs.map(\.path))
        for preparation in action.imagePreparations
        where
            outputPaths.contains(preparation.imageID)
        {
            let identifier = try String(
                contentsOfFile: preparation.imageID.string,
                encoding: .utf8)
            let components = identifier.split(whereSeparator: \.isNewline)
                .map(String.init)
            guard components.count == 2,
                components[0] == preparation.imageName,
                latestImages.contains(
                    Image(
                        repository: components[0],
                        digest: components[1]))
            else {
                throw OCIImageOutputValidationFailure.missingCurrentImage(
                    preparation.imageName)
            }
        }
    }
}

private enum OCIImageOutputValidationFailure: Error, CustomStringConvertible {
    case missingCurrentImage(String)

    var description: String {
        switch self {
        case .missingCurrentImage(let image):
            "current OCI image is missing or does not match its recorded digest: \(image)"
        }
    }
}

extension ExecutionPlan {
    var containsCleanOCIImageOutput: Bool {
        zip(declaredTasks, declaredEntries).contains {
            hasCleanOCIImageOutput(task: $0.0, entry: $0.1)
        }
            || zip(loweredTasks.map(\.task), loweredEntries).contains {
                hasCleanOCIImageOutput(task: $0.0, entry: $0.1)
            }
    }
}

private func hasCleanOCIImageOutput(
    task: TaskDeclaration,
    entry: TaskPlanEntry
) -> Bool {
    guard entry.isClean, let action = task.action else { return false }
    let outputPaths = Set(task.outputs.map(\.path))
    return action.imagePreparations.contains {
        outputPaths.contains($0.imageID)
    }
}
