import ColliderCore

public struct PreparedComponentCatalog: Sendable {
    let index: ComponentCatalogIndex
    let graph: TaskGraph

    public init(_ catalog: ComponentCatalog) throws {
        let index = try ComponentCatalogIndex(catalog)
        self.index = index
        graph = index.graph
        try ColliderPlanner().validateCompleteGraph(graph.declarations)
    }

    public func selectedTasks(
        for requests: [ComponentEntrypointRequest]
    ) throws -> [TaskID] {
        try index.roots(for: requests)
    }
}

struct ComponentCatalogIndex: Sendable {
    let tasks: [TaskDeclaration]
    let graph: TaskGraph

    private let components: [ComponentID: ComponentDefinition]
    private let groups: [String: ComponentSelectionGroup]
    private let componentSpellings: [String: ComponentID]
    private let routesByKey: [RouteKey: [ComponentEntrypointReference]]
    private let publicEntrypointSet: Set<ComponentEntrypointRequest>

    init(_ catalog: ComponentCatalog) throws {
        var componentsByID: [ComponentID: ComponentDefinition] = [:]
        var spellings: [String: ComponentID] = [:]
        var directoryNames: [String: ComponentID] = [:]
        var allTasks: [TaskDeclaration] = []

        for component in catalog.components {
            let descriptor = component.descriptor
            guard componentsByID.updateValue(component, forKey: descriptor.id) == nil else {
                throw ComponentCatalogFailure.duplicateComponent(descriptor.id)
            }
            guard
                directoryNames.updateValue(descriptor.id, forKey: descriptor.directoryName) == nil
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
        graph = try TaskGraph(allTasks)
        try StorageCatalog.validateProducers(catalog.storage, tasks: allTasks)

        var groupsByName: [String: ComponentSelectionGroup] = [:]
        for group in catalog.groups {
            guard spellings[group.name] == nil,
                groupsByName.updateValue(group, forKey: group.name) == nil
            else {
                throw ComponentCatalogFailure.duplicateSpelling(group.name)
            }
            for component in group.components where componentsByID[component] == nil {
                throw ComponentCatalogFailure.unknownGroupComponent(
                    group: group.name,
                    component: component)
            }
        }

        var indexedRoutes: [RouteKey: [ComponentEntrypointReference]] = [:]
        for route in catalog.routes {
            guard !route.destinations.isEmpty else {
                throw ComponentCatalogFailure.emptyRoute(
                    spelling: route.spelling,
                    entrypoint: route.requestedEntrypoint)
            }
            let key = RouteKey(
                spelling: route.spelling,
                entrypoint: route.requestedEntrypoint)
            guard indexedRoutes.updateValue(route.destinations, forKey: key) == nil else {
                throw ComponentCatalogFailure.duplicateRoute(
                    spelling: route.spelling,
                    entrypoint: route.requestedEntrypoint)
            }
            for destination in route.destinations {
                try Self.validate(destination, in: componentsByID)
            }
        }

        components = componentsByID
        groups = groupsByName
        componentSpellings = spellings
        routesByKey = indexedRoutes
        publicEntrypointSet = Set(catalog.publicEntrypoints)
        tasks = allTasks
        try validatePublicEntrypoints(catalog)
    }

    func roots(for requests: [ComponentEntrypointRequest]) throws -> [TaskID] {
        try requests.flatMap { request in
            guard publicEntrypointSet.contains(request) else {
                throw ComponentCatalogFailure.nonPublicEntrypoint(request)
            }
            return try resolve(request).flatMap { reference in
                components[reference.component]!.entrypoints[reference.entrypoint]!.roots
            }
        }.sorted { $0.rawValue < $1.rawValue }
    }

    private func resolve(
        _ request: ComponentEntrypointRequest
    ) throws -> [ComponentEntrypointReference] {
        if let destinations = routesByKey[
            RouteKey(spelling: request.spelling, entrypoint: request.entrypoint)
        ] {
            return destinations
        }
        if let componentID = componentSpellings[request.spelling] {
            let reference = ComponentEntrypointReference(
                component: componentID,
                entrypoint: request.entrypoint)
            try Self.validate(reference, in: components)
            return [reference]
        }
        if let group = groups[request.spelling] {
            let references = group.components.sorted {
                $0.rawValue < $1.rawValue
            }.compactMap { componentID -> ComponentEntrypointReference? in
                guard components[componentID]?.entrypoints[request.entrypoint] != nil else {
                    return nil
                }
                return ComponentEntrypointReference(
                    component: componentID,
                    entrypoint: request.entrypoint)
            }
            guard !references.isEmpty else {
                throw ComponentCatalogFailure.unsupportedEntrypoint(
                    spelling: request.spelling,
                    entrypoint: request.entrypoint)
            }
            return references
        }
        throw ComponentCatalogFailure.unknownSelection(request.spelling)
    }

    private func validatePublicEntrypoints(_ catalog: ComponentCatalog) throws {
        var requests: Set<ComponentEntrypointRequest> = []
        var reachable: Set<ComponentEntrypointReference> = []
        for request in catalog.publicEntrypoints {
            guard requests.insert(request).inserted else {
                throw ComponentCatalogFailure.duplicatePublicEntrypoint(request)
            }
            reachable.formUnion(try resolve(request))
        }
        for route in catalog.routes {
            let request = ComponentEntrypointRequest(
                spelling: route.spelling,
                entrypoint: route.requestedEntrypoint)
            guard requests.contains(request) else {
                throw ComponentCatalogFailure.unreachableRoute(request)
            }
        }
        for component in components.values {
            for entrypoint in component.entrypoints.keys {
                let reference = ComponentEntrypointReference(
                    component: component.descriptor.id,
                    entrypoint: entrypoint)
                guard reachable.contains(reference) else {
                    throw ComponentCatalogFailure.unreachableEntrypoint(reference)
                }
            }
        }
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

    private struct RouteKey: Hashable {
        let spelling: String
        let entrypoint: ComponentEntrypointID
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
    case duplicatePublicEntrypoint(ComponentEntrypointRequest)
    case nonPublicEntrypoint(ComponentEntrypointRequest)
    case unreachableRoute(ComponentEntrypointRequest)
    case unreachableEntrypoint(ComponentEntrypointReference)

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
        case .duplicatePublicEntrypoint(let request):
            "duplicate public entrypoint '\(request.spelling)' for '\(request.entrypoint)'"
        case .nonPublicEntrypoint(let request):
            "selection '\(request.spelling)' does not publish entrypoint '\(request.entrypoint)'"
        case .unreachableRoute(let request):
            "selection route '\(request.spelling)' for '\(request.entrypoint)' is not public"
        case .unreachableEntrypoint(let reference):
            "component '\(reference.component)' entrypoint '\(reference.entrypoint)' is unreachable"
        }
    }
}
