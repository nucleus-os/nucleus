import SystemPackage

public struct ComponentEntrypointID: RawRepresentable, Hashable, Codable, Sendable,
    CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static let build = Self(rawValue: "build")
    public static let bootstrap = Self(rawValue: "bootstrap")
    public static let generate = Self(rawValue: "generate")
    public static let install = Self(rawValue: "install")
    public static let testDefault = Self(rawValue: "test.default")
}

public struct ComponentDescriptor: Hashable, Sendable {
    public let id: ComponentID
    public let canonicalName: String
    public let directoryName: String
    public let aliases: Set<String>

    public init(
        id: ComponentID,
        canonicalName: String,
        directoryName: String,
        aliases: Set<String> = []
    ) {
        self.id = id
        self.canonicalName = canonicalName
        self.directoryName = directoryName
        self.aliases = aliases
    }
}

public struct ComponentEntrypoint: Hashable, Sendable {
    public let id: ComponentEntrypointID
    public let roots: Set<TaskID>

    public init(id: ComponentEntrypointID, roots: Set<TaskID>) {
        self.id = id
        self.roots = roots
    }
}

public struct ComponentDefinition: Sendable {
    public let descriptor: ComponentDescriptor
    public let tasks: [TaskDeclaration]
    public let entrypoints: [ComponentEntrypointID: ComponentEntrypoint]
    public let storage: [StorageDeclaration]

    public init(
        descriptor: ComponentDescriptor,
        tasks: [TaskDeclaration],
        entrypoints: [ComponentEntrypoint],
        storage: [StorageDeclaration] = []
    ) throws {
        var tasksByID: [TaskID: TaskDeclaration] = [:]
        for task in tasks {
            guard task.component == descriptor.id else {
                throw ComponentDefinitionFailure.foreignTask(
                    component: descriptor.id,
                    task: task.id,
                    owner: task.component)
            }
            guard tasksByID.updateValue(task, forKey: task.id) == nil else {
                throw ComponentDefinitionFailure.duplicateTask(task.id)
            }
        }

        var entrypointsByID: [ComponentEntrypointID: ComponentEntrypoint] = [:]
        for entrypoint in entrypoints {
            guard !entrypoint.roots.isEmpty else {
                throw ComponentDefinitionFailure.emptyEntrypoint(entrypoint.id)
            }
            guard
                entrypointsByID.updateValue(entrypoint, forKey: entrypoint.id) == nil
            else {
                throw ComponentDefinitionFailure.duplicateEntrypoint(entrypoint.id)
            }
            for root in entrypoint.roots where tasksByID[root] == nil {
                throw ComponentDefinitionFailure.unknownEntrypointRoot(
                    entrypoint: entrypoint.id,
                    task: root)
            }
        }
        for declaration in storage where declaration.owner != descriptor.id {
            throw ComponentDefinitionFailure.foreignStorage(
                component: descriptor.id,
                storage: declaration.id,
                owner: declaration.owner)
        }

        self.descriptor = descriptor
        self.tasks = tasks
        self.entrypoints = entrypointsByID
        self.storage = storage
    }

    public func addingStorage(
        _ declarations: [StorageDeclaration]
    ) throws -> ComponentDefinition {
        try ComponentDefinition(
            descriptor: descriptor,
            tasks: tasks,
            entrypoints: Array(entrypoints.values),
            storage: storage + declarations)
    }
}

public protocol ColliderComponent: Sendable {
    static var descriptor: ComponentDescriptor { get }

    static func makeComponent(
        in context: RecipeContext
    ) throws -> ComponentDefinition
}

public protocol RecipeConfiguration: Sendable {}

public struct RecipeBuildContextID: RawRepresentable, Hashable, Codable, Sendable,
    CustomStringConvertible
{
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static let hostDebug = Self(rawValue: "host.debug")
    public static let hostRelease = Self(rawValue: "host.release")

    public static func linux(
        _ architecture: PlatformArchitecture,
        configuration: SwiftBuildConfiguration = .debug,
        sanitizer: String? = nil
    ) -> Self {
        let suffix = sanitizer.map { ".sanitize.\($0)" } ?? ""
        return Self(
            rawValue:
                "linux.\(architecture.rawValue).\(configuration.rawValue)\(suffix)")
    }

    public static func androidARM64(apiLevel: UInt32) -> Self {
        Self(rawValue: "android.arm64.api-\(apiLevel)")
    }
}

public struct RecipeContext: Sendable {
    public let repositoryRoot: FilePath
    public let cacheRoot: FilePath
    public let environment: [String: String]
    public let buildContexts: [RecipeBuildContextID: SwiftPMInvocation]
    private let configurations: [ComponentID: any RecipeConfiguration]

    public init(
        repositoryRoot: FilePath,
        cacheRoot: FilePath,
        environment: [String: String],
        buildContexts: [RecipeBuildContextID: SwiftPMInvocation] = [:],
        configurations: [ComponentID: any RecipeConfiguration] = [:]
    ) {
        self.repositoryRoot = repositoryRoot
        self.cacheRoot = cacheRoot
        self.environment = environment
        self.buildContexts = buildContexts
        self.configurations = configurations
    }

    public func componentRoot(_ descriptor: ComponentDescriptor) -> FilePath {
        repositoryRoot.appending(descriptor.directoryName)
    }

    public func swiftPM(
        _ id: RecipeBuildContextID
    ) throws -> SwiftPMInvocation {
        guard let invocation = buildContexts[id] else {
            throw RecipeContextFailure.missingBuildContext(id)
        }
        return invocation
    }

    public func configuration<Value: RecipeConfiguration>(
        _ type: Value.Type = Value.self,
        for component: ComponentID
    ) throws -> Value {
        guard let value = configurations[component] else {
            throw RecipeContextFailure.missingConfiguration(component)
        }
        guard let typed = value as? Value else {
            throw RecipeContextFailure.invalidConfigurationType(component)
        }
        return typed
    }

    public func configurationIfPresent<Value: RecipeConfiguration>(
        _ type: Value.Type = Value.self,
        for component: ComponentID
    ) throws -> Value? {
        guard let value = configurations[component] else { return nil }
        guard let typed = value as? Value else {
            throw RecipeContextFailure.invalidConfigurationType(component)
        }
        return typed
    }

}

public enum RecipeContextFailure: Error, CustomStringConvertible, Sendable {
    case missingBuildContext(RecipeBuildContextID)
    case missingConfiguration(ComponentID)
    case invalidConfigurationType(ComponentID)

    public var description: String {
        switch self {
        case .missingBuildContext(let id):
            "recipe build context '\(id)' is not declared"
        case .missingConfiguration(let component):
            "recipe configuration for component '\(component)' is not declared"
        case .invalidConfigurationType(let component):
            "recipe configuration for component '\(component)' has the wrong type"
        }
    }
}

public struct ComponentEntrypointReference: Hashable, Sendable {
    public let component: ComponentID
    public let entrypoint: ComponentEntrypointID

    public init(component: ComponentID, entrypoint: ComponentEntrypointID) {
        self.component = component
        self.entrypoint = entrypoint
    }
}

public struct ComponentSelectionGroup: Hashable, Sendable {
    public let name: String
    public let components: Set<ComponentID>

    public init(name: String, components: Set<ComponentID>) {
        self.name = name
        self.components = components
    }
}

public struct ComponentEntrypointRoute: Hashable, Sendable {
    public let spelling: String
    public let requestedEntrypoint: ComponentEntrypointID
    public let destinations: [ComponentEntrypointReference]

    public init(
        spelling: String,
        requestedEntrypoint: ComponentEntrypointID,
        destinations: [ComponentEntrypointReference]
    ) {
        self.spelling = spelling
        self.requestedEntrypoint = requestedEntrypoint
        self.destinations = destinations
    }
}

public struct ComponentEntrypointRequest: Hashable, Sendable {
    public let spelling: String
    public let entrypoint: ComponentEntrypointID

    public init(
        spelling: String,
        entrypoint: ComponentEntrypointID
    ) {
        self.spelling = spelling
        self.entrypoint = entrypoint
    }

    public init(
        entrypoint: ComponentEntrypointID,
        selection: String?
    ) {
        spelling = selection ?? "all"
        self.entrypoint = entrypoint
    }
}

public struct ComponentCatalog: Sendable {
    public let components: [ComponentDefinition]
    public let groups: [ComponentSelectionGroup]
    public let routes: [ComponentEntrypointRoute]
    public let publicEntrypoints: [ComponentEntrypointRequest]

    public init(
        components: [ComponentDefinition],
        groups: [ComponentSelectionGroup] = [],
        routes: [ComponentEntrypointRoute] = [],
        publicEntrypoints: [ComponentEntrypointRequest]
    ) {
        self.components = components
        self.groups = groups
        self.routes = routes
        self.publicEntrypoints = publicEntrypoints
    }

    public var tasks: [TaskDeclaration] {
        components.flatMap(\.tasks)
    }

    public var storage: [StorageDeclaration] {
        components.flatMap(\.storage)
    }

    public func workflowLocks(
        for declaration: StorageDeclaration
    ) throws -> Set<TaskLock> {
        try StorageCatalog.workflowLocks(for: declaration, tasks: tasks)
    }
}

public enum ComponentDefinitionFailure: Error, CustomStringConvertible, Sendable {
    case foreignTask(component: ComponentID, task: TaskID, owner: ComponentID)
    case duplicateTask(TaskID)
    case duplicateEntrypoint(ComponentEntrypointID)
    case emptyEntrypoint(ComponentEntrypointID)
    case unknownEntrypointRoot(entrypoint: ComponentEntrypointID, task: TaskID)
    case foreignStorage(component: ComponentID, storage: String, owner: ComponentID)

    public var description: String {
        switch self {
        case .foreignTask(let component, let task, let owner):
            "component '\(component)' contains task '\(task)' owned by '\(owner)'"
        case .duplicateTask(let task):
            "duplicate task '\(task)' in component definition"
        case .duplicateEntrypoint(let entrypoint):
            "duplicate component entrypoint '\(entrypoint)'"
        case .emptyEntrypoint(let entrypoint):
            "component entrypoint '\(entrypoint)' has no roots"
        case .unknownEntrypointRoot(let entrypoint, let task):
            "component entrypoint '\(entrypoint)' names unknown root task '\(task)'"
        case .foreignStorage(let component, let storage, let owner):
            "component '\(component)' contains storage '\(storage)' owned by '\(owner)'"
        }
    }
}
