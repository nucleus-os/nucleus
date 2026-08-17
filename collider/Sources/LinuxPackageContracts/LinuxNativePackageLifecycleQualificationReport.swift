import ColliderCore
import ColliderPersistence
import Foundation

package struct LinuxNativePackageLifecycleQualificationReport: Codable,
    Equatable, Sendable
{
    package let family: LinuxDistributionFamily
    package let architecture: PlatformArchitecture
    package let oldVersion: String
    package let newVersion: String
    package let productionArtifacts: [ProductArtifactID]
    package let fixtureArtifacts: [ProductArtifactID]
    package let operations: [String]
    package let lifecycleInvocations: Int

    package init(
        family: LinuxDistributionFamily,
        architecture: PlatformArchitecture,
        oldVersion: String,
        newVersion: String,
        productionArtifacts: [ProductArtifactID],
        fixtureArtifacts: [ProductArtifactID],
        operations: [String],
        lifecycleInvocations: Int
    ) {
        self.family = family
        self.architecture = architecture
        self.oldVersion = oldVersion
        self.newVersion = newVersion
        self.productionArtifacts = productionArtifacts
        self.fixtureArtifacts = fixtureArtifacts
        self.operations = operations
        self.lifecycleInvocations = lifecycleInvocations
    }
}
