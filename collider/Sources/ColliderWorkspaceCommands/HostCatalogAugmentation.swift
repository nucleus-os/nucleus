import ShellColliderRecipe

package struct HostCatalogAugmentation: Sendable {
    package let shellConfiguration: ShellRuntimePublicationConfiguration?

    package var exposesLinuxOperations: Bool {
        shellConfiguration != nil
    }

    package static let none = HostCatalogAugmentation(shellConfiguration: nil)

    package static func linux(
        shellConfiguration: ShellRuntimePublicationConfiguration
    ) -> HostCatalogAugmentation {
        HostCatalogAugmentation(shellConfiguration: shellConfiguration)
    }
}
