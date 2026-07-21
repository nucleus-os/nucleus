import Foundation

struct PublicAPIAudit {
    let context: WorkspaceContext

    private let modules = [
        "NucleusTypes",
        "NucleusLayers",
        "NucleusUI",
        "NucleusUIEmbedder",
        "NucleusRenderModel",
        "NucleusRenderHost",
    ]

    func run() throws {
        let core = context.repository("core")
        let output = core.appendingPathComponent(
            ".build/nucleus-api-symbol-graphs",
            isDirectory: true)
        let scratch = core.appendingPathComponent(
            ".build/nucleus-api-build",
            isDirectory: true)
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: output)
        // Symbol-graph files are side effects the normal incremental build does
        // not track. A dedicated scratch graph makes API extraction repeatable
        // without disturbing the package's normal build cache.
        try? fileManager.removeItem(at: scratch)
        try fileManager.createDirectory(
            at: output,
            withIntermediateDirectories: true)

        for module in modules {
            print(
                "==> api component=core package=core configuration=debug "
                    + "module=\(module)")
            do {
                try context.run(
                    "swift",
                    [
                        "build", "--scratch-path", scratch.path,
                        "--target", module,
                        "-Xswiftc", "-emit-symbol-graph",
                        "-Xswiftc", "-emit-symbol-graph-dir",
                        "-Xswiftc", output.path,
                        "-Xswiftc", "-symbol-graph-minimum-access-level",
                        "-Xswiftc", "public",
                        "-Xswiftc", "-symbol-graph-skip-synthesized-members",
                    ],
                    directory: core)
            } catch {
                throw WorkspaceFailure.message(
                    "public API extraction failed [component=core package=core "
                        + "module=\(module)]: \(error)")
            }
        }

        var reports: [ModuleReport] = []
        for module in modules {
            let graph = output.appendingPathComponent("\(module).symbols.json")
            guard fileManager.fileExists(atPath: graph.path),
                  try fileSize(graph) > 0
            else {
                throw WorkspaceFailure.message(
                    "public API extraction produced no graph for \(module)")
            }
            reports.append(try audit(module: module, graph: graph))
        }

        let reportURL = output.appendingPathComponent("documentation-audit.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(reports).write(to: reportURL, options: .atomic)
        for report in reports {
            let counts = DocumentationConcern.allCases.map {
                "\($0.rawValue)=\(report.missing[$0.rawValue]?.count ?? 0)"
            }.joined(separator: " ")
            print(
                "api: \(report.module) public-symbols=\(report.publicSymbolCount) "
                    + counts)
        }
        print("api: symbol graphs and documentation audit written to \(output.path)")
    }

    private enum DocumentationConcern: String, CaseIterable {
        case ownership
        case actorIsolation = "actor-isolation"
        case units
        case coordinateSpace = "coordinate-space"
        case lifetime
        case errors
    }

    private struct SymbolGraph: Decodable {
        let symbols: [Symbol]
    }

    private struct Symbol: Decodable {
        struct Names: Decodable { let title: String }
        struct Fragment: Decodable { let spelling: String }
        struct Documentation: Decodable {
            struct Line: Decodable { let text: String }
            let lines: [Line]
        }

        let names: Names
        let declarationFragments: [Fragment]?
        let docComment: Documentation?
    }

    private struct ModuleReport: Encodable {
        let module: String
        let publicSymbolCount: Int
        let missing: [String: [String]]
    }

    private func audit(module: String, graph: URL) throws -> ModuleReport {
        let decoded = try JSONDecoder().decode(
            SymbolGraph.self,
            from: Data(contentsOf: graph))
        var missing = Dictionary(
            uniqueKeysWithValues: DocumentationConcern.allCases.map {
                ($0.rawValue, [String]())
            })
        for symbol in decoded.symbols {
            let declaration = symbol.declarationFragments?
                .map(\.spelling).joined() ?? symbol.names.title
            let searchText = (symbol.names.title + " " + declaration).lowercased()
            let documentation = symbol.docComment?.lines
                .map(\.text).joined(separator: " ").lowercased() ?? ""
            for concern in applicableConcerns(to: searchText)
            where !documents(concern, in: documentation) {
                missing[concern.rawValue, default: []].append(symbol.names.title)
            }
        }
        for concern in DocumentationConcern.allCases {
            missing[concern.rawValue] = Array(
                Set(missing[concern.rawValue, default: []])).sorted()
        }
        return ModuleReport(
            module: module,
            publicSymbolCount: decoded.symbols.count,
            missing: missing)
    }

    private func applicableConcerns(
        to text: String
    ) -> Set<DocumentationConcern> {
        var concerns: Set<DocumentationConcern> = []
        if containsAny(text, [
            "owner", "owned", "borrow", "retain", "release", "resource",
            "host", "handle", "snapshot",
        ]) {
            concerns.insert(.ownership)
        }
        if containsAny(text, [
            "callback", "completion", "observer", "sink", "schedule",
            "async", "task", "actor",
        ]) {
            concerns.insert(.actorIsolation)
        }
        if containsAny(text, [
            "width", "height", "size", "radius", "scale", "duration",
            "timeout", "deadline", "timestamp", "offset",
        ]) {
            concerns.insert(.units)
        }
        if containsAny(text, [
            "frame", "bounds", "origin", "position", "point", "rect",
            "location", "offset", "coordinate",
        ]) {
            concerns.insert(.coordinateSpace)
        }
        if containsAny(text, [
            "lifetime", "invalidate", "disconnect", "shutdown", "destroy",
            "cancel", "registration", "token",
        ]) {
            concerns.insert(.lifetime)
        }
        if containsAny(text, [
            "error", "failure", "result", "status", "throw", "reject",
        ]) {
            concerns.insert(.errors)
        }
        return concerns
    }

    private func documents(
        _ concern: DocumentationConcern,
        in documentation: String
    ) -> Bool {
        let terms: [String]
        switch concern {
        case .ownership:
            terms = ["own", "borrow", "retain", "release", "identity", "resource"]
        case .actorIsolation:
            terms = ["actor", "main thread", "executor", "sendable", "concurrent"]
        case .units:
            terms = ["point", "pixel", "second", "nanosecond", "scale", "unit"]
        case .coordinateSpace:
            terms = ["coordinate", "local", "global", "window", "screen", "parent"]
        case .lifetime:
            terms = ["lifetime", "until", "invalidate", "disconnect", "destroy", "cancel"]
        case .errors:
            terms = ["error", "fail", "throw", "reject", "nil", "invalid"]
        }
        return containsAny(documentation, terms)
    }

    private func containsAny(_ text: String, _ terms: [String]) -> Bool {
        terms.contains { text.contains($0) }
    }

    private func fileSize(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw WorkspaceFailure.message("could not read file size: \(url.path)")
        }
        return size.uint64Value
    }
}
