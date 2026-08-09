internal import Foundation

package struct ApplicationProviderID: Hashable, Sendable, RawRepresentable {
    package var rawValue: String

    package init(rawValue: String) {
        precondition(!rawValue.isEmpty && !rawValue.contains(":"))
        self.rawValue = rawValue
    }

    package static let desktop = ApplicationProviderID(rawValue: "desktop")
}

package struct ApplicationID: Hashable, Sendable, RawRepresentable {
    package var rawValue: String

    package init?(rawValue: String) {
        guard let separator = rawValue.firstIndex(of: ":"),
            separator != rawValue.startIndex,
            rawValue.index(after: separator) != rawValue.endIndex
        else { return nil }
        self.rawValue = rawValue
    }

    package init(provider: ApplicationProviderID, localID: String) {
        precondition(!localID.isEmpty)
        self.rawValue = "\(provider.rawValue):\(localID)"
    }

    package var providerID: ApplicationProviderID {
        let separator = rawValue.firstIndex(of: ":")!
        return ApplicationProviderID(rawValue: String(rawValue[..<separator]))
    }
}

package enum ApplicationIconReference: Sendable, Equatable {
    case theme(name: String)
    case rasterAsset(digest: String, path: String)
}

package struct ApplicationRecord: Sendable, Equatable {
    package var id: ApplicationID
    package var name: String
    package var icon: ApplicationIconReference?
    package var categories: [String]
    package var providerID: ApplicationProviderID
    package var providerLaunchID: String

    package init(
        id: ApplicationID,
        name: String,
        icon: ApplicationIconReference? = nil,
        categories: [String] = [],
        providerID: ApplicationProviderID,
        providerLaunchID: String
    ) {
        precondition(!name.isEmpty)
        precondition(!providerLaunchID.isEmpty)
        self.id = id
        self.name = name
        self.icon = icon
        self.categories = categories
        self.providerID = providerID
        self.providerLaunchID = providerLaunchID
    }
}

package enum ApplicationCatalogChange: Sendable, Equatable {
    case replace([ApplicationRecord])
    case upsert(ApplicationRecord)
    case remove(ApplicationID)
}

package struct ApplicationLaunchRequest: Sendable, Equatable {
    package var applicationID: ApplicationID
    package var activationToken: String?

    package init(applicationID: ApplicationID, activationToken: String? = nil) {
        self.applicationID = applicationID
        self.activationToken = activationToken
    }
}

package enum ApplicationLaunchFailure: Error, Sendable, Equatable {
    case applicationUnavailable(ApplicationID)
    case providerUnavailable(ApplicationProviderID)
    case launchFailed(String)
}

package enum ApplicationLaunchResult: Sendable, Equatable {
    case created
    case activatedExistingPresentation
    case failed(ApplicationLaunchFailure)

    package var succeeded: Bool {
        switch self {
        case .created, .activatedExistingPresentation:
            true
        case .failed:
            false
        }
    }
}

@MainActor
package protocol ApplicationProvider: AnyObject {
    var id: ApplicationProviderID { get }
    var applications: [ApplicationRecord] { get }

    func setCatalogChangeHandler(
        _ handler: (@MainActor @Sendable (ApplicationCatalogChange) -> Void)?)
    func launch(_ request: ApplicationLaunchRequest) -> ApplicationLaunchResult
}

@MainActor
package final class ApplicationCatalog {
    package var onApplicationsChanged: (([ApplicationRecord]) -> Void)?

    package private(set) var applications: [ApplicationRecord] = []

    private var providers: [ApplicationProviderID: any ApplicationProvider] = [:]
    private var records: [ApplicationID: ApplicationRecord] = [:]

    package init() {}

    package func attach(_ provider: any ApplicationProvider) {
        detach(providerID: provider.id)
        providers[provider.id] = provider
        let providerID = provider.id
        provider.setCatalogChangeHandler { [weak self] change in
            self?.apply(change, from: providerID)
        }
        apply(.replace(provider.applications), from: providerID)
    }

    package func detach(providerID: ApplicationProviderID) {
        guard let provider = providers.removeValue(forKey: providerID) else { return }
        provider.setCatalogChangeHandler(nil)
        records = records.filter { $0.value.providerID != providerID }
        publish()
    }

    package func application(id: ApplicationID) -> ApplicationRecord? {
        records[id]
    }

    package func launch(_ request: ApplicationLaunchRequest) -> ApplicationLaunchResult {
        guard let record = records[request.applicationID] else {
            return .failed(.applicationUnavailable(request.applicationID))
        }
        guard let provider = providers[record.providerID] else {
            return .failed(.providerUnavailable(record.providerID))
        }
        return provider.launch(request)
    }

    private func apply(
        _ change: ApplicationCatalogChange,
        from providerID: ApplicationProviderID
    ) {
        switch change {
        case .replace(let replacement):
            validate(replacement, from: providerID)
            records = records.filter { $0.value.providerID != providerID }
            for record in replacement {
                records[record.id] = record
            }
        case .upsert(let record):
            validate([record], from: providerID)
            records[record.id] = record
        case .remove(let id):
            guard records[id]?.providerID == providerID else { return }
            records.removeValue(forKey: id)
        }
        publish()
    }

    private func validate(
        _ records: [ApplicationRecord],
        from providerID: ApplicationProviderID
    ) {
        precondition(
            records.allSatisfy {
                $0.providerID == providerID && $0.id.providerID == providerID
            })
        precondition(Set(records.map(\.id)).count == records.count)
    }

    private func publish() {
        applications = records.values.sorted(by: applicationRecordLessThan)
        onApplicationsChanged?(applications)
    }
}

private func applicationRecordLessThan(
    _ left: ApplicationRecord,
    _ right: ApplicationRecord
) -> Bool {
    let nameOrder = left.name.localizedStandardCompare(right.name)
    if nameOrder != .orderedSame {
        return nameOrder == .orderedAscending
    }
    return left.id.rawValue < right.id.rawValue
}
