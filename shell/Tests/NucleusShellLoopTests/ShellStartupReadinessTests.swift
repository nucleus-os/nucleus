import NucleusShellLoop
import Testing

private func startupSurface(
    output: UInt32,
    surface: UInt64,
    renderOutput: UInt64,
    ready: Bool = true
) -> ShellStartupSurface {
    ShellStartupSurface(
        outputID: output,
        surfaceID: surface,
        renderOutputID: renderOutput,
        contentReady: ready)
}

@Suite struct ShellStartupReadinessTests {
    @Test func configurationWithoutAcceptedFramesIsNotReady() {
        var tracker = ShellStartupReadinessTracker()
        let ready = tracker.observe(
            postedRenderOutputIDs: [],
            liveOutputIDs: [1],
            wallpapers: [startupSurface(
                output: 1, surface: 10, renderOutput: 100)],
            bars: [startupSurface(
                output: 1, surface: 11, renderOutput: 101)])
        #expect(!ready)
    }

    @Test func wallpaperMustPresentAfterItBecomesResident() {
        var tracker = ShellStartupReadinessTracker()
        let pendingWallpaper = startupSurface(
            output: 1, surface: 10, renderOutput: 100, ready: false)
        let residentWallpaper = startupSurface(
            output: 1, surface: 10, renderOutput: 100)
        let bar = startupSurface(
            output: 1, surface: 11, renderOutput: 101)

        let placeholderAccepted = tracker.observe(
            postedRenderOutputIDs: [100, 101],
            liveOutputIDs: [1],
            wallpapers: [pendingWallpaper],
            bars: [bar])
        #expect(!placeholderAccepted)
        let residentWithoutFrame = tracker.observe(
            postedRenderOutputIDs: [],
            liveOutputIDs: [1],
            wallpapers: [residentWallpaper],
            bars: [bar])
        #expect(!residentWithoutFrame)
        let residentFrameAccepted = tracker.observe(
            postedRenderOutputIDs: [100],
            liveOutputIDs: [1],
            wallpapers: [residentWallpaper],
            bars: [bar])
        #expect(residentFrameAccepted)
    }

    @Test func everyLiveOutputRequiresWallpaperAndBarAcceptance() {
        var tracker = ShellStartupReadinessTracker()
        let wallpapers = [
            startupSurface(output: 1, surface: 10, renderOutput: 100),
            startupSurface(output: 2, surface: 20, renderOutput: 200),
        ]
        let bars = [
            startupSurface(output: 1, surface: 11, renderOutput: 101),
            startupSurface(output: 2, surface: 21, renderOutput: 201),
        ]
        let firstOutputAccepted = tracker.observe(
            postedRenderOutputIDs: [100, 101],
            liveOutputIDs: [1, 2],
            wallpapers: wallpapers,
            bars: bars)
        #expect(!firstOutputAccepted)
        let bothOutputsAccepted = tracker.observe(
            postedRenderOutputIDs: [200, 201],
            liveOutputIDs: [1, 2],
            wallpapers: wallpapers,
            bars: bars)
        #expect(bothOutputsAccepted)
    }
}
