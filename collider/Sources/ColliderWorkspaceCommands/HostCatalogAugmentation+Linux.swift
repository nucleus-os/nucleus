extension ComponentRegistry {
    package func defaultHostCatalogAugmentation() throws -> HostCatalogAugmentation {
        #if os(Linux)
        return .linux(
            shellConfiguration: try shellRuntimeInstallConfiguration(
                prefix: context.layout.installPrefix,
                selection: RuntimeBuildSelection()))
        #else
        return .none
        #endif
    }
}
