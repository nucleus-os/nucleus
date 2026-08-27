import ArgumentParser
import ColliderCore
import ColliderPersistence
import ColliderPlanning
import ReleaseGateColliderRecipe

struct Runs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Inspect active and historical Collider runs.",
        subcommands: [List.self, Show.self])

    struct List: ColliderInspectionCommand {
        @OptionGroup var outputOptions: CommandOutputOptions
        @Option(name: .shortAndLong, help: "Maximum number of runs to return.")
        var limit = RunRegistry.defaultRetainedRunCount

        mutating func validate() throws {
            guard limit >= 0 else { throw ValidationError("--limit must be nonnegative") }
        }

        mutating func run(in context: WorkspaceContext) async throws {
            try await RepositoryState(context: context).listRuns(limit: limit)
        }
    }

    struct Show: ColliderInspectionCommand {
        @OptionGroup var outputOptions: CommandOutputOptions
        @Argument(help: "Run identifier, or latest.") var runID: String?

        @Option(
            name: .customLong("explain-identity"),
            help: ArgumentHelp(
                "Print the recorded identity components of tasks whose name "
                    + "contains this text. Only tasks a lowering produced carry "
                    + "them, because those are the identities no later planning "
                    + "reconstructs."))
        var explainIdentity: String?

        mutating func run(in context: WorkspaceContext) async throws {
            try await RepositoryState(context: context).showRun(
                runID,
                explainIdentity: explainIdentity)
        }
    }
}

struct TaskInventoryEntry: Codable, Equatable, Sendable {
    let task: String
    let component: String
    let dependencies: [String]
    let lane: String
    let outputCount: Int
}

struct TaskInventoryReport: Codable, Equatable, Sendable {
    let tasks: [TaskInventoryEntry]
}

struct Tasks: ColliderInspectionCommand {
    static let configuration = CommandConfiguration(
        abstract: "List declared tasks from the current component catalog.")

    @OptionGroup var outputOptions: CommandOutputOptions
    @Option(help: "Restrict tasks to one component name or alias.")
    var component: String?
    @Option(help: "Restrict tasks to identifiers containing this text.")
    var matching: String?

    mutating func run(in context: WorkspaceContext) async throws {
        let catalog = try await ComponentRegistry(context: context).componentCatalog()
        let componentID: ComponentID?
        if let component {
            guard
                let definition = catalog.components.first(where: {
                    $0.descriptor.canonicalName == component
                        || $0.descriptor.aliases.contains(component)
                })
            else { throw WorkspaceFailure.message("unknown component '\(component)'") }
            componentID = definition.descriptor.id
        } else {
            componentID = nil
        }
        let entries = catalog.tasks
            .filter { componentID == nil || $0.component == componentID }
            .filter { task in
                guard let matching else { return true }
                return task.id.rawValue.contains(matching)
            }
            .sorted { $0.id.rawValue < $1.id.rawValue }
            .map {
                TaskInventoryEntry(
                    task: $0.id.rawValue,
                    component: $0.component.rawValue,
                    dependencies: $0.executionDependencies.map(\.rawValue).sorted(),
                    lane: ($0.action?.requirements.lane ?? .lightweight).rawValue,
                    outputCount: $0.outputs.count)
            }
        let text = entries.map {
            "\($0.task)\t\($0.component)\t\($0.lane)\t\($0.dependencies.count) dependencies"
        }.joined(separator: "\n")
        try context.console.report(TaskInventoryReport(tasks: entries), text: text)
    }
}

enum GraphOperation: String, CaseIterable, ExpressibleByArgument, Sendable {
    case bootstrap
    case build
    case test
    case generate
    case install

    var entrypoint: ComponentEntrypointID {
        switch self {
        case .bootstrap: .bootstrap
        case .build: .build
        case .test: .testDefault
        case .generate: .generate
        case .install: .install
        }
    }
}

struct GraphNodeReport: Codable, Equatable, Sendable {
    let task: String
    let component: String
    let dependencies: [String]
    let selectedRoot: Bool
}

struct GraphInspectionReport: Codable, Equatable, Sendable {
    let operation: String
    let target: String
    let roots: [String]
    let nodes: [GraphNodeReport]
}

struct Graph: ColliderInspectionCommand {
    static let configuration = CommandConfiguration(
        abstract: "Print the resolved declared task graph for an operation.")

    @OptionGroup var outputOptions: CommandOutputOptions
    @Argument var operation: GraphOperation
    @Argument(help: "Selection spelling such as all, runtime, core, or browser.")
    var target: String?

    mutating func run(in context: WorkspaceContext) async throws {
        let catalog = try await ComponentRegistry(context: context).componentCatalog()
        let selection = target ?? "all"
        var requests = [
            ComponentEntrypointRequest(
                spelling: selection,
                entrypoint: operation.entrypoint)
        ]
        if operation == .test, selection == "all" {
            requests.append(
                ComponentEntrypointRequest(
                    spelling: "release-gate",
                    entrypoint: ReleaseGateEntrypoints.test))
        }
        let roots = try ColliderPlanner().selectedTasks(
            in: catalog,
            requests: requests)
        let rootSet = Set(roots)
        let declarations = try TaskGraph(catalog.tasks).orderedTasks(selecting: roots)
        let nodes = declarations.map {
            GraphNodeReport(
                task: $0.id.rawValue,
                component: $0.component.rawValue,
                dependencies: $0.executionDependencies.map(\.rawValue),
                selectedRoot: rootSet.contains($0.id))
        }
        let report = GraphInspectionReport(
            operation: operation.rawValue,
            target: selection,
            roots: roots.map(\.rawValue).sorted(),
            nodes: nodes)
        let text = nodes.map { node in
            let marker = node.selectedRoot ? "*" : " "
            let dependencies =
                node.dependencies.isEmpty
                ? "" : " <- " + node.dependencies.joined(separator: ", ")
            return "\(marker) \(node.task)\(dependencies)"
        }.joined(separator: "\n")
        try context.console.report(report, text: text)
    }
}
