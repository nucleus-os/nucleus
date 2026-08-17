import AndroidRuntimeColliderRecipe
import ShellColliderRecipe

package struct HostCatalogAugmentation: Sendable {
    package let shellConfiguration: ShellRuntimePublicationConfiguration?
    package let androidPackageConfiguration: AndroidPackageInputConfiguration?

    package var exposesLinuxOperations: Bool {
        shellConfiguration != nil
    }

    package static let none = HostCatalogAugmentation(
        shellConfiguration: nil,
        androidPackageConfiguration: nil)

    package static func linux(
        shellConfiguration: ShellRuntimePublicationConfiguration,
        androidPackageConfiguration: AndroidPackageInputConfiguration? = nil
    ) -> HostCatalogAugmentation {
        HostCatalogAugmentation(
            shellConfiguration: shellConfiguration,
            androidPackageConfiguration: androidPackageConfiguration)
    }
}
