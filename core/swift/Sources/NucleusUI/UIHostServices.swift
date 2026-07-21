public enum UIHostService: String, Sendable, Equatable {
    case text
    case pasteboard
    case environment
    case image
}

public enum UIHostServiceFailure: Sendable, Equatable {
    case text(TextSystemIssue)
    case pasteboard(PasteboardFailure)
    case image(ImageRequestFailure)
    case unavailable
    case operationFailed(String)
}

public struct UIHostDiagnostic: Sendable, Equatable {
    public var service: UIHostService
    public var operation: String
    public var resourceIdentity: UInt64?
    public var generation: UInt64?
    public var failure: UIHostServiceFailure

    public init(
        service: UIHostService,
        operation: String,
        resourceIdentity: UInt64? = nil,
        generation: UInt64? = nil,
        failure: UIHostServiceFailure
    ) {
        self.service = service
        self.operation = operation
        self.resourceIdentity = resourceIdentity
        self.generation = generation
        self.failure = failure
    }
}

/// The portable services installed before one retained UI graph is built.
///
/// The references are immutable after construction. Their backend/adapter
/// lifecycle remains explicit on the service that owns it, so a host cannot
/// silently replace the complete semantic environment under existing views.
@MainActor
public struct UIHostServices: ~Sendable {
    public typealias DiagnosticSink =
        @MainActor @Sendable (UIHostDiagnostic) -> Void

    public let textSystem: TextSystem
    public let pasteboard: Pasteboard
    public let imageSourceResolver: ImageSourceResolver
    public let requiresTextBackend: Bool
    private let diagnosticSink: DiagnosticSink

    public init(
        textSystem: TextSystem,
        pasteboard: Pasteboard,
        imageSourceResolver: ImageSourceResolver,
        requiresTextBackend: Bool = true,
        diagnosticSink: @escaping DiagnosticSink
    ) {
        self.textSystem = textSystem
        self.pasteboard = pasteboard
        self.imageSourceResolver = imageSourceResolver
        self.requiresTextBackend = requiresTextBackend
        self.diagnosticSink = diagnosticSink

        textSystem.diagnosticHandler = { [weak textSystem] issue in
            diagnosticSink(UIHostDiagnostic(
                service: .text,
                operation: issue.operation,
                generation: textSystem?.installationGeneration,
                failure: .text(issue)))
        }
        pasteboard.diagnosticHandler = { [weak pasteboard] operation, failure in
            diagnosticSink(UIHostDiagnostic(
                service: .pasteboard,
                operation: operation,
                generation: pasteboard?.adapterGeneration,
                failure: .pasteboard(failure)))
        }
    }

    /// Explicit deterministic services for tests, previews, and in-memory
    /// application hosts. The text system deliberately has no native backend;
    /// its deterministic portable fallback remains scoped to this context.
    public static func inMemory(
        diagnosticSink: @escaping DiagnosticSink = { _ in }
    ) -> UIHostServices {
        UIHostServices(
            textSystem: TextSystem(),
            pasteboard: Pasteboard(adapter: InMemoryPasteboardAdapter()),
            imageSourceResolver: .directResourcesOnly,
            requiresTextBackend: false,
            diagnosticSink: diagnosticSink)
    }

    @discardableResult
    package func validateForRetainedMaterialization() -> Bool {
        guard requiresTextBackend, !textSystem.hasInstalledBackend else {
            return true
        }
        diagnosticSink(UIHostDiagnostic(
            service: .text,
            operation: "materialize-retained-ui",
            generation: textSystem.installationGeneration,
            failure: .text(.missingBackend)))
        return false
    }

    package func report(_ diagnostic: UIHostDiagnostic) {
        diagnosticSink(diagnostic)
    }
}

private extension TextSystemIssue {
    var operation: String {
        switch self {
        case .missingBackend:
            "resolve-backend"
        case .fontResolutionFailed:
            "resolve-font"
        case .fontMetricsFailed:
            "font-metrics"
        case .layoutFailed:
            "create-layout"
        case .resourceCreationFailed:
            "create-layout-resource"
        }
    }
}
