/// Renderer-independent startup acceptance facts for one desktop surface.
package struct NucleusWindowClientStartupSurface: Sendable, Equatable {
    package var outputID: UInt32
    package var surfaceID: UInt64
    package var renderOutputID: UInt64?
    package var contentReady: Bool

    package init(
        outputID: UInt32,
        surfaceID: UInt64,
        renderOutputID: UInt64?,
        contentReady: Bool
    ) {
        self.outputID = outputID
        self.surfaceID = surfaceID
        self.renderOutputID = renderOutputID
        self.contentReady = contentReady
    }
}

/// Monotonic startup acceptance state. A surface counts only when a frame was
/// accepted after its required content became ready; configuration alone and a
/// placeholder frame cannot satisfy the session protocol.
package struct NucleusWindowClientStartupReadinessTracker: Sendable, Equatable {
    private var acceptedWallpaperSurfaceIDs = Set<UInt64>()
    private var acceptedBarSurfaceIDs = Set<UInt64>()

    package init() {}

    package mutating func observe(
        postedRenderOutputIDs: Set<UInt64>,
        liveOutputIDs: Set<UInt32>,
        wallpapers: [NucleusWindowClientStartupSurface],
        bars: [NucleusWindowClientStartupSurface]
    ) -> Bool {
        for surface in wallpapers
        where surface.contentReady
            && surface.renderOutputID.map(
                postedRenderOutputIDs.contains) == true
        {
            acceptedWallpaperSurfaceIDs.insert(surface.surfaceID)
        }
        for surface in bars
        where surface.contentReady
            && surface.renderOutputID.map(
                postedRenderOutputIDs.contains) == true
        {
            acceptedBarSurfaceIDs.insert(surface.surfaceID)
        }

        guard !liveOutputIDs.isEmpty else { return false }
        for outputID in liveOutputIDs {
            guard
                let wallpaper = wallpapers.first(where: {
                    $0.outputID == outputID
                }),
                let bar = bars.first(where: { $0.outputID == outputID }),
                acceptedWallpaperSurfaceIDs.contains(wallpaper.surfaceID),
                acceptedBarSurfaceIDs.contains(bar.surfaceID)
            else { return false }
        }
        return true
    }
}
