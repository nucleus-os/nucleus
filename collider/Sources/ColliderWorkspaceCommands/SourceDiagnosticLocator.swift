import Foundation

/// A compiler or linker diagnostic located in the checkout that produced it.
package struct ResolvedSourceDiagnostic: Equatable, Sendable {
    /// Path relative to the repository root, which is what a workflow
    /// annotation must carry to land on the file it names.
    package let path: String
    package let line: Int
    package let column: Int
    package let message: String
}

/// Attributes a failing stage log to one source location.
///
/// Diagnostics reach this from builds that ran somewhere else: a container sees
/// the checkout at its own mount point, and a materialized workspace sees it at
/// another. Rather than teach this every mount layout, it takes the longest
/// trailing component sequence that names a file in the checkout. A path that
/// does not resolve produces no file annotation instead of a wrong one, which
/// keeps a mount layout this does not know about from pointing a reader at a
/// file that had nothing to do with the failure.
///
/// This reads console output for presentation only. Whether a task failed comes
/// from its exit status and recorded events, never from this.
package enum SourceDiagnosticLocator {
    /// A single trailing component names too many plausible files to attribute
    /// a failure to one of them, so resolution requires at least two.
    private static let minimumComponents = 2

    private static let markers = [": error: ", ": fatal error: "]

    package static func firstDiagnostic(
        in text: String,
        repositoryRoot: String,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> ResolvedSourceDiagnostic? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let parsed = parse(String(line)) else { continue }
            guard
                let path = repositoryRelativePath(
                    for: parsed.path,
                    repositoryRoot: repositoryRoot,
                    exists: exists)
            else { continue }
            return ResolvedSourceDiagnostic(
                path: path,
                line: parsed.line,
                column: parsed.column,
                message: parsed.message)
        }
        return nil
    }

    /// Split `<path>:<line>:<column>: error: <message>`.
    ///
    /// A diagnostic that carries no location, such as a driver's terminal
    /// `error:` line, is not a source location and is skipped.
    package static func parse(
        _ line: String
    ) -> (path: String, line: Int, column: Int, message: String)? {
        for marker in markers {
            guard let marker = line.range(of: marker) else { continue }
            let location = String(line[line.startIndex..<marker.lowerBound])
            let message = String(line[marker.upperBound...])
            let fields = location.split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count >= 3,
                let column = Int(fields[fields.count - 1]),
                let number = Int(fields[fields.count - 2]),
                number > 0,
                column > 0
            else { continue }
            let path = fields[0..<(fields.count - 2)].joined(separator: ":")
            guard !path.isEmpty, !message.isEmpty else { continue }
            return (path, number, column, message)
        }
        return nil
    }

    package static func repositoryRelativePath(
        for path: String,
        repositoryRoot: String,
        exists: (String) -> Bool
    ) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard components.count >= minimumComponents else { return nil }
        let root =
            repositoryRoot.hasSuffix("/")
            ? String(repositoryRoot.dropLast())
            : repositoryRoot
        for start in 0...(components.count - minimumComponents) {
            let candidate = components[start...].joined(separator: "/")
            if exists("\(root)/\(candidate)") { return candidate }
        }
        return nil
    }
}
