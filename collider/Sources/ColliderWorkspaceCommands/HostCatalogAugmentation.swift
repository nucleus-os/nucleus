import AndroidRuntimeColliderRecipe
import ShellColliderRecipe

package struct HostCatalogAugmentation: Sendable {
    package let shellConfiguration: ShellRuntimeInstallConfiguration?
    package let androidAddonConfiguration: AndroidAddonPackageConfiguration?

    package var exposesLinuxOperations: Bool {
        shellConfiguration != nil
    }

    package static let none = HostCatalogAugmentation(
        shellConfiguration: nil,
        androidAddonConfiguration: nil)

    package static func linux(
        shellConfiguration: ShellRuntimeInstallConfiguration,
        androidAddonConfiguration: AndroidAddonPackageConfiguration? = nil
    ) -> HostCatalogAugmentation {
        HostCatalogAugmentation(
            shellConfiguration: shellConfiguration,
            androidAddonConfiguration: androidAddonConfiguration)
    }
}
