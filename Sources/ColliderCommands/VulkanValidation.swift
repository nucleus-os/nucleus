import Foundation

struct VulkanValidationLayer: Codable, Equatable {
    let manifest: String
    let directory: String

    static func resolve(
        environment: [String: String],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        includeSystemDirectories: Bool = true
    ) throws -> VulkanValidationLayer {
        for directory in searchDirectories(
            environment: environment,
            homeDirectory: homeDirectory,
            includeSystemDirectories: includeSystemDirectories)
        where FileManager.default.fileExists(atPath: directory.path) {
            let entries = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])) ?? []
            for manifest in entries
                .filter({ $0.pathExtension.lowercased() == "json" })
                .sorted(by: { $0.path < $1.path })
            {
                guard let data = try? Data(contentsOf: manifest),
                      let object = try? JSONSerialization.jsonObject(with: data),
                      containsValidationLayer(object)
                else { continue }
                return VulkanValidationLayer(
                    manifest: manifest.path,
                    directory: directory.path)
            }
        }
        throw WorkspaceFailure.message(
            "VK_LAYER_KHRONOS_validation was not found; "
                + "install the Vulkan validation layers package")
    }

    static func searchDirectories(
        environment: [String: String],
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        includeSystemDirectories: Bool = true
    ) -> [URL] {
        var directories: [URL] = []
        func appendLayerPathList(_ value: String?) {
            for path in (value ?? "").split(separator: ":", omittingEmptySubsequences: true) {
                directories.append(URL(fileURLWithPath: String(path), isDirectory: true))
            }
        }
        func appendDataPathList(_ value: String?) {
            for path in (value ?? "").split(separator: ":", omittingEmptySubsequences: true) {
                directories.append(
                    URL(fileURLWithPath: String(path), isDirectory: true)
                        .appendingPathComponent(
                            "vulkan/explicit_layer.d", isDirectory: true))
            }
        }
        appendLayerPathList(environment["VK_LAYER_PATH"])
        let dataHome = environment["XDG_DATA_HOME"].flatMap {
            $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true)
        } ?? homeDirectory.appendingPathComponent(".local/share", isDirectory: true)
        directories.append(dataHome.appendingPathComponent(
            "vulkan/explicit_layer.d", isDirectory: true))
        if includeSystemDirectories {
            directories.append(URL(
                fileURLWithPath: "/usr/local/share/vulkan/explicit_layer.d",
                isDirectory: true))
            directories.append(URL(
                fileURLWithPath: "/usr/share/vulkan/explicit_layer.d",
                isDirectory: true))
            let dataDirectories = environment["XDG_DATA_DIRS"].flatMap {
                $0.isEmpty ? nil : $0
            } ?? "/usr/local/share:/usr/share"
            appendDataPathList(dataDirectories)
        } else {
            appendDataPathList(environment["XDG_DATA_DIRS"])
        }

        var seen: Set<String> = []
        return directories.map(\.standardizedFileURL)
            .filter { seen.insert($0.path).inserted }
    }

    func applying(to environment: inout [String: String]) {
        let existing = environment["VK_LAYER_PATH"].flatMap {
            $0.isEmpty ? nil : $0
        }
        environment["VK_LAYER_PATH"] = [directory, existing]
            .compactMap { $0 }
            .joined(separator: ":")
    }
}

struct VulkanValidationReport: Codable {
    let status: String
    let manifest: String?
    let directory: String?
    let searchDirectories: [String]
}

struct VulkanValidation {
    let context: WorkspaceContext

    func run(dryRun: Bool, json: Bool) throws {
        let directories = VulkanValidationLayer.searchDirectories(
            environment: context.environment).map(\.path)
        let layer = dryRun ? nil : try VulkanValidationLayer.resolve(
            environment: context.environment)
        let report = VulkanValidationReport(
            status: dryRun ? "planned" : "passed",
            manifest: layer?.manifest,
            directory: layer?.directory,
            searchDirectories: directories)
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
            return
        }
        if let layer {
            print("vulkan validation layer: \(layer.manifest)")
        } else {
            print("vulkan validation search plan:")
            for directory in directories { print("  \(directory)") }
        }
    }
}

private func containsValidationLayer(_ value: Any) -> Bool {
    if let dictionary = value as? [String: Any] {
        if dictionary["name"] as? String == "VK_LAYER_KHRONOS_validation" {
            return true
        }
        return dictionary.values.contains(where: containsValidationLayer)
    }
    if let array = value as? [Any] {
        return array.contains(where: containsValidationLayer)
    }
    return false
}
