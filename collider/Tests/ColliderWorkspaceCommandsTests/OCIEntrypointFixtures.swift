import ColliderCore
import SystemPackage

func fixtureMountedEntrypoint(
    imageID: FilePath,
    role: String
) throws -> OCIMountedEntrypoint {
    var builder = TaskBuilder(
        id: TaskID(rawValue: "fixture.\(role)-image"),
        component: ComponentID(rawValue: "fixture"))
    let image = try builder.output(
        "image-id",
        path: imageID,
        validation: .regularFile)
    return fixtureMountedEntrypoint(image: image, role: role)
}

func fixtureMountedEntrypoint(
    image: ArtifactReference,
    role: String
) -> OCIMountedEntrypoint {
    OCIMountedEntrypoint(
        image: image,
        executable: FilePath("/bin/sh"),
        containerDirectory: "/collider-entrypoints/\(role)")
}
