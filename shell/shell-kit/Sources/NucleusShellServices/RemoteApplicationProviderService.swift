package import Foundation
import Glibc
package import NucleusSessionProtocol

package struct ApplicationProviderPollDescriptor: Sendable, Equatable {
    package var token: UInt64
    package var fileDescriptor: Int32
}

@MainActor
package final class RemoteApplicationProviderService {
    private struct Connection {
        var channel: ApplicationProviderClientChannel
        var provider: RemoteApplicationProvider
        var receivedHello = false
        var attached = false
    }

    private let launcher: LauncherService
    private let sessionRuntimeDirectory: URL
    private let endpointDirectory: URL
    private let expectedUserID: UInt32
    private var connections: [UInt64: Connection] = [:]
    private var providerTokens: [ApplicationProviderID: UInt64] = [:]
    private var nextToken: UInt64 = 1
    private var nextScanNanoseconds: UInt64 = 0

    package init(
        launcher: LauncherService,
        sessionRuntimeDirectory: URL,
        expectedUserID: UInt32 = getuid()
    ) {
        self.launcher = launcher
        self.sessionRuntimeDirectory = sessionRuntimeDirectory
        endpointDirectory = ApplicationProviderEndpoint.directory(
            in: sessionRuntimeDirectory)
        self.expectedUserID = expectedUserID
    }

    package var pollDescriptors: [ApplicationProviderPollDescriptor] {
        connections.map {
            ApplicationProviderPollDescriptor(
                token: $0.key,
                fileDescriptor: $0.value.channel.fileDescriptor)
        }
    }

    package func scan(nowNanoseconds: UInt64) {
        guard nowNanoseconds >= nextScanNanoseconds else { return }
        nextScanNanoseconds = nowNanoseconds &+ 250_000_000
        guard
            let names = try? FileManager.default.contentsOfDirectory(
                atPath: endpointDirectory.path)
        else { return }

        for name in names.sorted() where name.hasSuffix(".sock") {
            let rawProviderID = String(name.dropLast(".sock".count))
            guard ApplicationProviderEndpoint.validProviderID(rawProviderID) else { continue }
            let providerID = ApplicationProviderID(rawValue: rawProviderID)
            guard providerTokens[providerID] == nil else { continue }
            let socket = endpointDirectory.appendingPathComponent(name)
            guard
                let channel = try? ApplicationProviderClientChannel(
                    connecting: socket,
                    expectedProviderID: rawProviderID,
                    expectedUserID: expectedUserID)
            else { continue }
            let token = nextToken
            nextToken &+= 1
            connections[token] = Connection(
                channel: channel,
                provider: RemoteApplicationProvider(
                    id: providerID,
                    sessionRuntimeDirectory: sessionRuntimeDirectory,
                    expectedUserID: expectedUserID))
            providerTokens[providerID] = token
        }
    }

    package func nanosecondsUntilScan(nowNanoseconds: UInt64) -> UInt64 {
        nextScanNanoseconds > nowNanoseconds
            ? nextScanNanoseconds - nowNanoseconds
            : 0
    }

    @discardableResult
    package func process(token: UInt64) -> Bool {
        guard var connection = connections[token] else { return false }
        do {
            guard let change = try connection.channel.receive() else {
                guard !connection.receivedHello else {
                    throw RemoteApplicationProviderFailure.duplicateHello
                }
                connection.receivedHello = true
                connections[token] = connection
                return false
            }
            guard connection.receivedHello else {
                throw RemoteApplicationProviderFailure.changeBeforeHello
            }
            let mapped = try map(
                change,
                providerID: connection.provider.id)
            if !connection.attached {
                guard case .replace = mapped else {
                    throw RemoteApplicationProviderFailure.changeBeforeSnapshot
                }
                connection.provider.apply(mapped)
                launcher.attach(connection.provider)
                connection.attached = true
            } else {
                connection.provider.apply(mapped)
            }
            connections[token] = connection
            return true
        } catch {
            disconnect(token: token)
            return true
        }
    }

    package func disconnect(token: UInt64) {
        guard let connection = connections.removeValue(forKey: token) else { return }
        providerTokens.removeValue(forKey: connection.provider.id)
        if connection.attached {
            launcher.detach(providerID: connection.provider.id)
        }
        nextScanNanoseconds = 0
    }

    package func shutdown() {
        for token in Array(connections.keys) {
            disconnect(token: token)
        }
    }

    private func map(
        _ change: ApplicationProviderCatalogChange,
        providerID: ApplicationProviderID
    ) throws -> ApplicationCatalogChange {
        switch change {
        case .replace(let records):
            return .replace(try records.map { try map($0, providerID: providerID) })
        case .upsert(let record):
            return .upsert(try map(record, providerID: providerID))
        case .remove(let rawID):
            guard let id = ApplicationID(rawValue: rawID), id.providerID == providerID else {
                throw RemoteApplicationProviderFailure.invalidApplicationID
            }
            return .remove(id)
        }
    }

    private func map(
        _ record: ApplicationProviderRecord,
        providerID: ApplicationProviderID
    ) throws -> ApplicationRecord {
        guard let id = ApplicationID(rawValue: record.id), id.providerID == providerID else {
            throw RemoteApplicationProviderFailure.invalidApplicationID
        }
        let icon: ApplicationIconReference?
        switch record.icon {
        case .none:
            icon = nil
        case .theme(let name):
            icon = .theme(name: name)
        case .rasterAsset(let digest, let path):
            icon = .rasterAsset(digest: digest, path: path)
        }
        return ApplicationRecord(
            id: id,
            name: record.name,
            icon: icon,
            categories: record.categories,
            providerID: providerID,
            providerLaunchID: record.launchID)
    }
}

private enum RemoteApplicationProviderFailure: Error {
    case duplicateHello
    case changeBeforeHello
    case changeBeforeSnapshot
    case invalidApplicationID
}

@MainActor
private final class RemoteApplicationProvider: ApplicationProvider {
    let id: ApplicationProviderID
    private let sessionRuntimeDirectory: URL
    private let expectedUserID: UInt32
    private(set) var applications: [ApplicationRecord] = []
    private var records: [ApplicationID: ApplicationRecord] = [:]
    private var catalogChangeHandler: (@MainActor @Sendable (ApplicationCatalogChange) -> Void)?

    init(
        id: ApplicationProviderID,
        sessionRuntimeDirectory: URL,
        expectedUserID: UInt32
    ) {
        self.id = id
        self.sessionRuntimeDirectory = sessionRuntimeDirectory
        self.expectedUserID = expectedUserID
    }

    func setCatalogChangeHandler(
        _ handler: (@MainActor @Sendable (ApplicationCatalogChange) -> Void)?
    ) {
        catalogChangeHandler = handler
    }

    func launch(_ request: ApplicationLaunchRequest) -> ApplicationLaunchResult {
        guard let record = records[request.applicationID] else {
            return .failed(.applicationUnavailable(request.applicationID))
        }
        do {
            let providerRequest = try ApplicationProviderLaunchRequest(
                providerID: id.rawValue,
                launchID: record.providerLaunchID,
                activationToken: request.activationToken)
            switch try ApplicationProviderLaunchClient.launch(
                providerRequest,
                sessionRuntimeDirectory: sessionRuntimeDirectory,
                expectedUserID: expectedUserID)
            {
            case .created:
                return .created
            case .activatedExistingPresentation:
                return .activatedExistingPresentation
            case .failed(let message):
                return .failed(.launchFailed(message))
            }
        } catch {
            return .failed(.launchFailed(String(describing: error)))
        }
    }

    func apply(_ change: ApplicationCatalogChange) {
        switch change {
        case .replace(let replacement):
            records = Dictionary(uniqueKeysWithValues: replacement.map { ($0.id, $0) })
        case .upsert(let record):
            records[record.id] = record
        case .remove(let id):
            records.removeValue(forKey: id)
        }
        applications = records.values.sorted { $0.id.rawValue < $1.id.rawValue }
        catalogChangeHandler?(change)
    }
}
