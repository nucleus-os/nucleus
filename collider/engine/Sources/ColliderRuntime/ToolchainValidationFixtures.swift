import ColliderCore
import Foundation
import SystemPackage

enum ToolchainValidationFixtures {
    enum Fixture: String, CaseIterable {
        case cxxInterop = "CxxInteropTestRunner"
        case sourceKitLSP = "NucleusLSPPackage"
        case androidSDKConsumer = "AndroidSDKConsumer"
    }

    static func materialize(
        _ fixture: Fixture,
        at destination: FilePath,
        substitutions: [String: String] = [:]
    ) throws {
        let source = try resourceURL(for: fixture)
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.string) {
            try manager.removeItem(atPath: destination.string)
        }
        try manager.createDirectory(
            atPath: destination.removingLastComponent().string,
            withIntermediateDirectories: true)
        try manager.copyItem(
            at: source,
            to: URL(fileURLWithPath: destination.string))
        guard !substitutions.isEmpty else { return }
        try substitute(
            substitutions,
            under: URL(fileURLWithPath: destination.string))
    }

    static func resourceURL(for fixture: Fixture) throws -> URL {
        guard
            let root = Bundle.module.resourceURL?
                .appendingPathComponent(
                    "ToolchainValidationFixtures",
                    isDirectory: true),
            FileManager.default.fileExists(atPath: root.path)
        else {
            throw RuntimeFailure.invalidOutput(
                "Collider validation fixture bundle is missing")
        }
        let fixtureURL = root.appendingPathComponent(
            fixture.rawValue,
            isDirectory: true)
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw RuntimeFailure.invalidOutput(
                "Collider validation fixture is missing: \(fixture.rawValue)")
        }
        return fixtureURL
    }

    static func jsonRPCPayload(
        _ messages: [[String: Any]]
    ) throws -> [UInt8] {
        var payload = Data()
        for message in messages {
            let body = try JSONSerialization.data(
                withJSONObject: message,
                options: [.sortedKeys])
            payload.append(
                Data("Content-Length: \(body.count)\r\n\r\n".utf8))
            payload.append(body)
        }
        return Array(payload)
    }

    static func jsonRPCMessages(
        _ output: String
    ) throws -> [[String: Any]] {
        let data = Data(output.utf8)
        let separator = Data("\r\n\r\n".utf8)
        var offset = data.startIndex
        var messages: [[String: Any]] = []
        while offset < data.endIndex {
            guard
                let headerRange = data.range(
                    of: separator,
                    in: offset..<data.endIndex),
                let header = String(
                    data: data[offset..<headerRange.lowerBound],
                    encoding: .utf8),
                let lengthLine = header.split(separator: "\r\n").first(
                    where: {
                        $0.lowercased().hasPrefix("content-length:")
                    }),
                let length = Int(
                    lengthLine.split(separator: ":", maxSplits: 1)[1]
                        .trimmingCharacters(in: .whitespaces))
            else {
                throw RuntimeFailure.invalidOutput(
                    "SourceKit-LSP emitted invalid JSON-RPC framing")
            }
            let bodyStart = headerRange.upperBound
            let bodyEnd = bodyStart + length
            guard bodyEnd <= data.endIndex,
                let message = try JSONSerialization.jsonObject(
                    with: data[bodyStart..<bodyEnd]) as? [String: Any]
            else {
                throw RuntimeFailure.invalidOutput(
                    "SourceKit-LSP emitted an invalid JSON-RPC body")
            }
            messages.append(message)
            offset = bodyEnd
        }
        return messages
    }

    private static func substitute(
        _ substitutions: [String: String],
        under directory: URL
    ) throws {
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles])
        else {
            throw RuntimeFailure.invalidOutput(
                "cannot enumerate validation fixture \(directory.path)")
        }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true,
                var source = try? String(contentsOf: url, encoding: .utf8)
            else { continue }
            let original = source
            for (placeholder, value) in substitutions.sorted(
                by: { $0.key < $1.key })
            {
                source = source.replacingOccurrences(
                    of: placeholder,
                    with: value)
            }
            if source != original {
                try DurableFile.write(
                    Data(source.utf8),
                    to: FilePath(url.path))
            }
        }
    }
}
