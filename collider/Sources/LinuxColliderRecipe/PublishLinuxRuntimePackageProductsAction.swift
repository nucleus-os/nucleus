import ColliderCore
import ColliderPersistence
import Foundation
import LinuxPackageAssembly
import LinuxPackageContracts
import SystemPackage

package struct LinuxNativePackageProductStoreReceipt: Codable, Equatable, Sendable {
    package let architecture: PlatformArchitecture
    package let packageGeneration: String
    package let products: [ProductArtifactID]
}

package struct PublishLinuxRuntimePackageProductsAction: ColliderAction {
    package struct Identity: ColliderActionIdentity {
        let architecture: PlatformArchitecture
        let packagePublicationRoot: FilePath
        let productStoreRoot: FilePath
        let receiptRoot: FilePath

        package func encode(into encoder: inout IdentityEncoder) {
            encoder.append(architecture.rawValue)
            encoder.append(path: packagePublicationRoot)
            encoder.append(path: productStoreRoot)
            encoder.append(path: receiptRoot)
        }
    }

    package static let kind: ActionKind =
        "linux.publish-runtime-package-products"

    private let architecture: PlatformArchitecture
    private let packagePublicationRoot: FilePath
    private let productStoreRoot: FilePath
    private let receiptRoot: FilePath

    package init(
        architecture: PlatformArchitecture,
        packagePublicationRoot: FilePath,
        productStoreRoot: FilePath,
        receiptRoot: FilePath
    ) {
        self.architecture = architecture
        self.packagePublicationRoot = packagePublicationRoot
        self.productStoreRoot = productStoreRoot
        self.receiptRoot = receiptRoot
    }

    package var identity: Identity {
        Identity(
            architecture: architecture,
            packagePublicationRoot: packagePublicationRoot,
            productStoreRoot: productStoreRoot,
            receiptRoot: receiptRoot)
    }

    package var requirements: ActionRequirements {
        ActionRequirements(
            effects: [
                ActionEffect(
                    .read,
                    scope: .input(packagePublicationRoot)),
                ActionEffect(
                    .readWrite,
                    scope: .publication(productStoreRoot)),
                ActionEffect(
                    .readWrite,
                    scope: .output(receiptRoot)),
            ],
            executionPlatform: .macOSARM64Native)
    }

    package func execute(in context: ActionContext) throws {
        let publication = try validateLinuxNativePackagePublication(
            architecture: architecture,
            outputRoot: packagePublicationRoot,
            files: context.files)
        let store = LocalProductArtifactStore(root: productStoreRoot)
        var inputByteCount: UInt64 = 0
        var outputByteCount: UInt64 = 0
        let publicationStart = ContinuousClock().now
        for product in publication.publication.products {
            let envelopePath = publication.root.appending("manifests").appending(
                linuxNativePackageEnvelopeName(product))
            let envelopeBytes = try context.files.read(envelopePath)
            let envelope = try JSONDecoder().decode(
                ProductArtifactEnvelope.self,
                from: Data(envelopeBytes))
            let payload = publication.root.appending("product-payloads").appending(
                product.productArtifact.rawValue.hexadecimal)
            let archive = publication.root.appending(product.archive)
            try ProductArtifactBuilder.validateEnvelope(
                envelope,
                payloadRoot: payload,
                archive: archive)
            inputByteCount &+= try linuxNativePackageLogicalByteCount(
                at: payload,
                files: context.files)
            inputByteCount &+= try linuxNativePackageLogicalByteCount(
                at: archive,
                files: context.files)
            inputByteCount &+= UInt64(envelopeBytes.count)
            let stored = try store.publishIfNeeded(
                envelope,
                payloadRoot: payload,
                archive: archive)
            if stored.disposition == .publishedArtifact {
                outputByteCount &+= try linuxNativePackageLogicalByteCount(
                    at: stored.artifact.payloadRoot.removingLastComponent(),
                    files: context.files)
            }
        }
        let receipt = LinuxNativePackageProductStoreReceipt(
            architecture: architecture,
            packageGeneration: publication.target,
            products: publication.publication.products.map(\.productArtifact).sorted {
                $0.rawValue.hexadecimal < $1.rawValue.hexadecimal
            })
        try context.files.createDirectory(receiptRoot)
        try context.files.write(
            try encodedReceipt(receipt),
            to: receiptPath)
        context.observations.record(
            ActionStageObservation(
                name: LinuxNativePackageStage.productStorePublication
                    .observationName,
                durationNanoseconds: elapsedNanoseconds(since: publicationStart),
                inputByteCount: inputByteCount,
                outputByteCount: outputByteCount))
    }

    package func validateOutputs(using files: ActionFileSystem) throws {
        try validateLinuxNativePackageProductStoreReceipt(
            architecture: architecture,
            packagePublicationRoot: packagePublicationRoot,
            productStoreRoot: productStoreRoot,
            receipt: receiptPath,
            files: files)
    }

    private var receiptPath: FilePath {
        receiptRoot.appending("receipt.json")
    }
}

package func validateLinuxNativePackageProductStoreReceipt(
    architecture: PlatformArchitecture,
    packagePublicationRoot: FilePath,
    productStoreRoot: FilePath,
    receipt: FilePath,
    files: ActionFileSystem
) throws {
    let generation = try validateLinuxNativePackagePublication(
        architecture: architecture,
        outputRoot: packagePublicationRoot,
        files: files)
    let recorded = try JSONDecoder().decode(
        LinuxNativePackageProductStoreReceipt.self,
        from: Data(files.read(receipt)))
    let expectedProducts = generation.publication.products.map(\.productArtifact)
        .sorted { $0.rawValue.hexadecimal < $1.rawValue.hexadecimal }
    guard recorded.architecture == architecture,
        recorded.packageGeneration == generation.target,
        recorded.products == expectedProducts
    else {
        throw LinuxNativePackageProductPublicationFailure(
            "product-store receipt does not match the active package generation")
    }
    try validateLinuxNativePackagePublication(
        architecture: architecture,
        outputRoot: packagePublicationRoot,
        productStoreRoot: productStoreRoot,
        files: files)
}

private func encodedReceipt<T: Encodable>(_ value: T) throws -> [UInt8] {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return Array(try encoder.encode(value))
}

private struct LinuxNativePackageProductPublicationFailure: Error,
    CustomStringConvertible, Sendable
{
    let description: String

    init(_ description: String) {
        self.description =
            "Linux native package product publication failed: \(description)"
    }
}
