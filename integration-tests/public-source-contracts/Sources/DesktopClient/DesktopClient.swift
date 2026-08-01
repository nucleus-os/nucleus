import NucleusDesktop

public func makeDesktopConfiguration() -> NucleusDesktopHostConfiguration {
    NucleusDesktopHostConfiguration()
}

@MainActor
public func makeDesktopHost(
    wakeSink: any AsyncRenderWakeSink
) -> NucleusDesktopHost? {
    NucleusDesktopHost(
        configuration: makeDesktopConfiguration(),
        asyncRenderWakeSink: wakeSink
    )
}
