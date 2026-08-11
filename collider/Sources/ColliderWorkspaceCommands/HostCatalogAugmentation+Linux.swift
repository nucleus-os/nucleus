extension ComponentRegistry {
    package func defaultHostCatalogAugmentation() throws -> HostCatalogAugmentation {
        #if os(Linux)
        return .linux(
            shellConfiguration: try shellRuntimePublicationConfiguration(
                prefix: context.layout.developmentRuntimeCurrent,
                selection: RuntimeBuildSelection()))
        #else
        return .none
        #endif
    }
}
