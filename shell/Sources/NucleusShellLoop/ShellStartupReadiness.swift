/// Renderer-independent startup acceptance facts for one shell surface.
public struct ShellStartupSurface: Sendable, Equatable {
    public var outputID: UInt32
    public var surfaceID: UInt64
    public var renderOutputID: UInt64?
    public var contentReady: Bool

    public init(
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
public struct ShellStartupReadinessTracker: Sendable, Equatable {
    private var acceptedWallpaperSurfaceIDs = Set<UInt64>()
    private var acceptedBarSurfaceIDs = Set<UInt64>()

    public init() {}

    public mutating func observe(
        postedRenderOutputIDs: Set<UInt64>,
        liveOutputIDs: Set<UInt32>,
        wallpapers: [ShellStartupSurface],
        bars: [ShellStartupSurface]
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
            guard let wallpaper = wallpapers.first(where: {
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
