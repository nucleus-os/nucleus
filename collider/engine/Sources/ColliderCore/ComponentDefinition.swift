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
    public static let benchmark = Self(rawValue: "benchmark")
    public static let qualify = Self(rawValue: "qualify")
    public static let testDefault = Self(rawValue: "test.default")
    public static let testGPUHeadless = Self(rawValue: "test.gpu-headless")
    public static let testGPUDRM = Self(rawValue: "test.gpu-drm")
    public static let testReleaseGate = Self(rawValue: "test.release-gate")
    public static let androidBuild = Self(rawValue: "android.build")
    public static let androidNative = Self(rawValue: "android.native")
    public static let androidVerify = Self(rawValue: "android.verify")
    public static let sanitizeAddress = Self(rawValue: "sanitize.address")
    public static let sanitizeUndefined = Self(rawValue: "sanitize.undefined")
    public static let sanitizeThread = Self(rawValue: "sanitize.thread")
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

    public init(
        descriptor: ComponentDescriptor,
        tasks: [TaskDeclaration],
        entrypoints: [ComponentEntrypoint]
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

        self.descriptor = descriptor
        self.tasks = tasks
        self.entrypoints = entrypointsByID
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
    public let nativeSDKRoot: FilePath
    public let environment: [String: String]
    public let buildContexts: [RecipeBuildContextID: SwiftPMInvocation]
    private let configurations: [ComponentID: any RecipeConfiguration]

    public init(
        repositoryRoot: FilePath,
        cacheRoot: FilePath,
        nativeSDKRoot: FilePath,
        environment: [String: String],
        buildContexts: [RecipeBuildContextID: SwiftPMInvocation] = [:],
        configurations: [ComponentID: any RecipeConfiguration] = [:]
    ) {
        self.repositoryRoot = repositoryRoot
        self.cacheRoot = cacheRoot
        self.nativeSDKRoot = nativeSDKRoot
        self.environment = environment
        self.buildContexts = buildContexts
        self.configurations = configurations
    }

    public func componentRoot(_ descriptor: ComponentDescriptor) -> FilePath {
        repositoryRoot.appending(descriptor.directoryName)
    }

    public var nativeBuilder: NativeOCIConfiguration {
        let cache = cacheRoot.appending("nucleus")
        return NativeOCIConfiguration(
            context: repositoryRoot.appending("core/build-container"),
            imageID: cache.appending("build-containers/native/image-id"),
            ccache: cache.appending("ccache/native"),
            swiftSDKRoot: cache.appending(
                "swift-target-sdks/current/swift-sdks"),
            environment: environment)
    }

    public func nativeSDK(for target: NativeLinuxTarget) -> FilePath {
        nativeSDKRoot.appending(target.identifier)
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

public struct ComponentCatalog: Sendable {
    public let components: [ComponentID: ComponentDefinition]
    public let groups: [String: ComponentSelectionGroup]
    public let routes: [ComponentEntrypointRoute]
    public let tasks: [TaskDeclaration]

    private let componentSpellings: [String: ComponentID]
    private let routesByKey: [RouteKey: [ComponentEntrypointReference]]

    public init(
        components: [ComponentDefinition],
        groups: [ComponentSelectionGroup] = [],
        routes: [ComponentEntrypointRoute] = []
    ) throws {
        var componentsByID: [ComponentID: ComponentDefinition] = [:]
        var spellings: [String: ComponentID] = [:]
        var directoryNames: [String: ComponentID] = [:]
        var allTasks: [TaskDeclaration] = []

        for component in components {
            let descriptor = component.descriptor
            guard componentsByID.updateValue(component, forKey: descriptor.id) == nil else {
                throw ComponentCatalogFailure.duplicateComponent(descriptor.id)
            }
            guard
                directoryNames.updateValue(descriptor.id, forKey: descriptor.directoryName)
                    == nil
            else {
                throw ComponentCatalogFailure.duplicateDirectory(descriptor.directoryName)
            }
            for spelling in [descriptor.canonicalName] + descriptor.aliases.sorted() {
                guard spellings.updateValue(descriptor.id, forKey: spelling) == nil else {
                    throw ComponentCatalogFailure.duplicateSpelling(spelling)
                }
            }
            allTasks += component.tasks
        }

        _ = try TaskGraph(allTasks)

        var groupsByName: [String: ComponentSelectionGroup] = [:]
        for group in groups {
            guard spellings[group.name] == nil else {
                throw ComponentCatalogFailure.duplicateSpelling(group.name)
            }
            guard groupsByName.updateValue(group, forKey: group.name) == nil else {
                throw ComponentCatalogFailure.duplicateSpelling(group.name)
            }
            for component in group.components where componentsByID[component] == nil {
                throw ComponentCatalogFailure.unknownGroupComponent(
                    group: group.name,
                    component: component)
            }
        }

        var routesByKey: [RouteKey: [ComponentEntrypointReference]] = [:]
        for route in routes {
            guard !route.destinations.isEmpty else {
                throw ComponentCatalogFailure.emptyRoute(
                    spelling: route.spelling,
                    entrypoint: route.requestedEntrypoint)
            }
            let key = RouteKey(
                spelling: route.spelling,
                entrypoint: route.requestedEntrypoint)
            guard routesByKey.updateValue(route.destinations, forKey: key) == nil else {
                throw ComponentCatalogFailure.duplicateRoute(
                    spelling: route.spelling,
                    entrypoint: route.requestedEntrypoint)
            }
            for destination in route.destinations {
                try Self.validate(destination, in: componentsByID)
            }
        }

        try Self.validateOutputOwnership(allTasks)

        self.components = componentsByID
        self.groups = groupsByName
        self.routes = routes
        tasks = allTasks
        componentSpellings = spellings
        self.routesByKey = routesByKey
    }

    public func entrypoints(
        named entrypoint: ComponentEntrypointID,
        selection: String?
    ) throws -> [ComponentEntrypointReference] {
        let spelling = selection ?? "all"
        if let destinations = routesByKey[
            RouteKey(spelling: spelling, entrypoint: entrypoint)
        ] {
            return destinations
        }
        if let componentID = componentSpellings[spelling] {
            let reference = ComponentEntrypointReference(
                component: componentID,
                entrypoint: entrypoint)
            try Self.validate(reference, in: components)
            return [reference]
        }
        if let group = groups[spelling] {
            let references = group.components.sorted(by: {
                $0.rawValue < $1.rawValue
            }).compactMap { componentID -> ComponentEntrypointReference? in
                guard components[componentID]?.entrypoints[entrypoint] != nil else {
                    return nil
                }
                return ComponentEntrypointReference(
                    component: componentID,
                    entrypoint: entrypoint)
            }
            guard !references.isEmpty else {
                throw ComponentCatalogFailure.unsupportedEntrypoint(
                    spelling: spelling,
                    entrypoint: entrypoint)
            }
            return references
        }
        throw ComponentCatalogFailure.unknownSelection(spelling)
    }

    public func roots(
        named entrypoint: ComponentEntrypointID,
        selection: String?
    ) throws -> [TaskID] {
        try entrypoints(named: entrypoint, selection: selection).flatMap { reference in
            components[reference.component]!.entrypoints[reference.entrypoint]!.roots
        }.sorted { $0.rawValue < $1.rawValue }
    }

    private static func validate(
        _ reference: ComponentEntrypointReference,
        in components: [ComponentID: ComponentDefinition]
    ) throws {
        guard let component = components[reference.component] else {
            throw ComponentCatalogFailure.unknownComponent(reference.component)
        }
        guard component.entrypoints[reference.entrypoint] != nil else {
            throw ComponentCatalogFailure.unknownEntrypoint(reference)
        }
    }

    private static func validateOutputOwnership(_ tasks: [TaskDeclaration]) throws {
        var owners: [(path: FilePath, normalized: String, task: TaskID)] = []
        for task in tasks {
            for output in task.outputs {
                let normalized = output.path.lexicallyNormalized().string
                for owner in owners
                where task.id != owner.task
                    && (normalized == owner.normalized
                        || Self.contains(normalized, in: owner.normalized)
                        || Self.contains(owner.normalized, in: normalized))
                {
                    throw ComponentCatalogFailure.overlappingOutput(
                        first: owner.task,
                        second: task.id,
                        path: output.path)
                }
                owners.append((output.path, normalized, task.id))
            }
        }
    }

    private static func contains(_ child: String, in parent: String) -> Bool {
        let prefix = parent.hasSuffix("/") ? parent : parent + "/"
        return child.hasPrefix(prefix)
    }

    private struct RouteKey: Hashable, Sendable {
        let spelling: String
        let entrypoint: ComponentEntrypointID
    }
}

public enum ComponentDefinitionFailure: Error, CustomStringConvertible, Sendable {
    case foreignTask(component: ComponentID, task: TaskID, owner: ComponentID)
    case duplicateTask(TaskID)
    case duplicateEntrypoint(ComponentEntrypointID)
    case emptyEntrypoint(ComponentEntrypointID)
    case unknownEntrypointRoot(entrypoint: ComponentEntrypointID, task: TaskID)

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
        }
    }
}

public enum ComponentCatalogFailure: Error, CustomStringConvertible, Sendable {
    case duplicateComponent(ComponentID)
    case duplicateDirectory(String)
    case duplicateSpelling(String)
    case unknownComponent(ComponentID)
    case unknownGroupComponent(group: String, component: ComponentID)
    case unknownEntrypoint(ComponentEntrypointReference)
    case unknownSelection(String)
    case unsupportedEntrypoint(spelling: String, entrypoint: ComponentEntrypointID)
    case emptyRoute(spelling: String, entrypoint: ComponentEntrypointID)
    case duplicateRoute(spelling: String, entrypoint: ComponentEntrypointID)
    case overlappingOutput(first: TaskID, second: TaskID, path: FilePath)

    public var description: String {
        switch self {
        case .duplicateComponent(let component):
            "duplicate component '\(component)'"
        case .duplicateDirectory(let directory):
            "duplicate component directory '\(directory)'"
        case .duplicateSpelling(let spelling):
            "duplicate component selection spelling '\(spelling)'"
        case .unknownComponent(let component):
            "unknown component '\(component)'"
        case .unknownGroupComponent(let group, let component):
            "selection group '\(group)' names unknown component '\(component)'"
        case .unknownEntrypoint(let reference):
            "component '\(reference.component)' has no entrypoint '\(reference.entrypoint)'"
        case .unknownSelection(let spelling):
            "unknown component selection '\(spelling)'"
        case .unsupportedEntrypoint(let spelling, let entrypoint):
            "selection '\(spelling)' does not support entrypoint '\(entrypoint)'"
        case .emptyRoute(let spelling, let entrypoint):
            "selection route '\(spelling)' for '\(entrypoint)' has no destinations"
        case .duplicateRoute(let spelling, let entrypoint):
            "duplicate selection route '\(spelling)' for '\(entrypoint)'"
        case .overlappingOutput(let first, let second, let path):
            "tasks '\(first)' and '\(second)' overlap output ownership at '\(path)'"
        }
    }
}
