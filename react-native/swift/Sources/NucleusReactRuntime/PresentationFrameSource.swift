public import NucleusAppHostProtocols
import NucleusDiagnostics
import NucleusReactRuntimeCxx

extension Host {
    /// Drives this runtime's native and JavaScript animations from one platform
    /// presentation source. Replacing the source cancels its outstanding
    /// one-shot callback before arming the replacement.
    public func setPresentationFrameSource(
        _ source: any NucleusPresentationFrameSource
    ) throws {
        try requireHost().setPresentationFrameSource(source)
    }
}

extension RuntimeHost {
    package func setPresentationFrameSource(
        _ source: any NucleusPresentationFrameSource
    ) throws {
        // ReactRuntimeHost invokes these synchronous C++ callbacks only on its
        // owning JS thread. RuntimeHost is main-actor-owned, so this is the
        // explicit actor boundary for the C++ callback seam.
        try setAnimationFrameScheduler(
            request: { [weak self, weak source] in
                MainActor.assumeIsolated {
                    guard let self, let source else { return false }
                    do {
                        try source.requestPresentationFrame {
                            [weak self] timestampNanoseconds in
                            do {
                                try self?.deliverAnimationFrame(
                                    timestampNanoseconds:
                                        timestampNanoseconds)
                            } catch {
                                NucleusLogger(subsystem: "react-runtime")
                                    .error(
                                        "presentation frame delivery failed: \(error)")
                            }
                        }
                        return true
                    } catch {
                        NucleusLogger(subsystem: "react-runtime").error(
                            "presentation frame request failed: \(error)")
                        return false
                    }
                }
            },
            cancel: { [weak source] in
                MainActor.assumeIsolated {
                    source?.cancelPresentationFrame()
                }
            })
    }
}
