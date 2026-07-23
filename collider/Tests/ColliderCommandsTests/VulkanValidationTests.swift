import Foundation
import Testing
@testable import ColliderCommands

@Test func vulkanValidationFindsAndPrependsADeclaredManifest() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-vulkan-validation-\(UUID().uuidString)", isDirectory: true)
    let layers = root.appendingPathComponent("layers", isDirectory: true)
    try FileManager.default.createDirectory(
        at: layers, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let manifest = layers.appendingPathComponent("validation.json")
    try Data("""
    {"file_format_version":"1.2.0","layer":{"name":"VK_LAYER_KHRONOS_validation"}}
    """.utf8).write(to: manifest)

    let layer = try VulkanValidationLayer.resolve(
        environment: ["VK_LAYER_PATH": layers.path],
        homeDirectory: root)
    #expect(layer.manifest == manifest.path)
    var environment = ["VK_LAYER_PATH": "/restricted"]
    layer.applying(to: &environment)
    #expect(environment["VK_LAYER_PATH"] == "\(layers.path):/restricted")
}

@Test func vulkanValidationRejectsUnrelatedLayerManifests() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "collider-vulkan-validation-\(UUID().uuidString)", isDirectory: true)
    let layers = root.appendingPathComponent(
        ".local/share/vulkan/explicit_layer.d", isDirectory: true)
    try FileManager.default.createDirectory(
        at: layers, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data(#"{"layer":{"name":"VK_LAYER_OTHER"}}"#.utf8).write(
        to: layers.appendingPathComponent("other.json"))

    #expect(throws: WorkspaceFailure.self) {
        try VulkanValidationLayer.resolve(
            environment: ["XDG_DATA_DIRS": root.path],
            homeDirectory: root,
            includeSystemDirectories: false)
    }
}
