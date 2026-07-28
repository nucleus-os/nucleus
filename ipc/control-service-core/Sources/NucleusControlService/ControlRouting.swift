import NucleusControlProtocol
import NucleusSessionProtocol

public enum ControlRoute: Equatable, Sendable {
    case local(ControlResponse)
    case configuration(ConfigurationSubscriptionRequest)
    case renderServer(RenderServerControlRequest)
    case unauthorized
}

/// Pure request classification. The broker owns no session state; it only
/// maps the public vocabulary onto capability-scoped owner channels.
public enum ControlRouting {
    public static func route(
        _ request: ControlRequest,
        configurationAvailability: ControlOwnerAvailability,
        renderServerAvailability: ControlOwnerAvailability,
        hasElevatedCapability: Bool
    ) -> ControlRoute {
        switch request {
        case .version:
            return .local(.version(ControlVersionInfo(
                configurationService: configurationAvailability,
                renderServer: renderServerAvailability)))
        case .configuration, .exportConfiguration:
            return configurationAvailability.available
                ? .configuration(.export)
                : unavailable
        case .reloadConfiguration:
            return configurationAvailability.available
                ? .configuration(.reload)
                : unavailable
        case .validateConfiguration(let source):
            return configurationAvailability.available
                ? .configuration(.validate(source: source))
                : unavailable
        case .replaceConfiguration(let source):
            guard hasElevatedCapability else { return .unauthorized }
            return configurationAvailability.available
                ? .configuration(.replace(source: source))
                : unavailable
        case .outputs:
            return renderServerAvailability.available
                ? .renderServer(.outputs)
                : unavailable
        case .binds:
            return renderServerAvailability.available
                ? .renderServer(.activeBindings)
                : unavailable
        case .action(let action):
            return renderServerAvailability.available
                ? .renderServer(.action(action))
                : unavailable
        }
    }

    private static var unavailable: ControlRoute {
        .local(.error(ControlFailure(
            code: .ownerUnavailable,
            message: "request owner is unavailable")))
    }

    public static func failure(
        code: OwnerControlFailureCode?,
        message: String?
    ) -> ControlFailure {
        let publicCode: ControlErrorCode
        switch code {
        case .unavailable:
            publicCode = .ownerUnavailable
        case .staleGeneration:
            publicCode = .staleGeneration
        case .unauthorized:
            publicCode = .unauthorized
        case .invalidRequest:
            publicCode = .invalidRequest
        case .rejected, .none:
            publicCode = .rejected
        case .internalTransport:
            publicCode = .internalTransport
        }
        return ControlFailure(
            code: publicCode,
            message: message ?? "owner rejected the request")
    }
}
