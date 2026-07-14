import Foundation

struct BuildContract: Codable, Sendable {
    struct Toolchain: Codable, Sendable {
        let swiftVersionPrefix: String
        let clangMajor: Int
    }

    struct Tools: Codable, Sendable {
        let cmakeMinimum: String
        let ninjaMinimum: String
        let nodeAllowedMajors: [Int]
        let nodeMinimumFutureMajor: Int
        let yarnVersion: String
        let bunVersion: String
        let pythonMinimum: String
        let jinja2Minimum: String
        let markupsafeMinimum: String
    }

    struct Libraries: Codable, Sendable {
        let icuMinimum: String
        let libeventMinimum: String
        let opensslMinimum: String
        let vulkanMinimum: String
        let fontconfigMinimum: String
        let freetypeMinimum: String
    }

    let schemaVersion: Int
    let toolchain: Toolchain
    let tools: Tools
    let libraries: Libraries

    static func load(from workspaceRoot: URL) throws -> BuildContract {
        let url = workspaceRoot.appendingPathComponent("config/build-contract.json")
        let data = try Data(contentsOf: url)
        let value = try JSONDecoder().decode(BuildContract.self, from: data)
        guard value.schemaVersion == 1 else {
            throw WorkspaceFailure.message("unsupported build-contract schema \(value.schemaVersion)")
        }
        return value
    }
}

struct SemanticVersion: Comparable, CustomStringConvertible, Sendable {
    let components: [Int]
    let suffix: String

    init(_ text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let numeric = trimmed.prefix { $0.isNumber || $0 == "." }
        let values = numeric.split(separator: ".").compactMap { Int($0) }
        guard !values.isEmpty else { throw WorkspaceFailure.message("could not parse version '\(text)'") }
        components = values
        suffix = String(trimmed.dropFirst(numeric.count))
    }

    var description: String { components.map(String.init).joined(separator: ".") + suffix }

    static func == (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}
