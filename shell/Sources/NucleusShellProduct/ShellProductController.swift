public import NucleusUI

/// One output's retained wallpaper hierarchy.
@MainActor
public final class ShellWallpaperProduct {
    public let imageView: ImageView
    public let sourcePath: String

    init(sourcePath: String, sourceSize: Size) {
        self.sourcePath = sourcePath
        imageView = ImageView(
            source: .resource(sourcePath),
            imageSize: sourceSize)
        imageView.contentMode = .cover
        imageView.backgroundColor = Color(0, 0, 0, 1)
        imageView.isHitTestingEnabled = false
        imageView.isAccessibilityElement = false
        imageView.layerPresentation = ViewLayerPresentation(role: .wallpaper)
    }
}

/// One output's retained native bar hierarchy.
@MainActor
public final class ShellBarProduct {
    public let barView: BarView
    public let taskbarWidget: TaskbarWidget
    public let clockWidget: ClockWidget
    public let batteryWidget: BatteryWidget

    init(
        windows: [ShellWindowSnapshot],
        clockText: String,
        batteryLevel: BatteryLevel,
        onWindowAction: @escaping (UInt64, ShellWindowAction) -> Void
    ) {
        barView = BarView()
        taskbarWidget = TaskbarWidget()
        clockWidget = ClockWidget()
        batteryWidget = BatteryWidget()

        taskbarWidget.onWindowAction = onWindowAction
        barView.setWidgets([taskbarWidget], in: .start)
        barView.setWidgets([clockWidget], in: .center)
        barView.setWidgets([batteryWidget], in: .end)
        taskbarWidget.update(windows: windows)
        clockWidget.update(displayText: clockText)
        batteryWidget.update(batteryLevel)
    }
}

/// Process-lifetime native product composition. It retains typed state while
/// output-specific bar view trees come and go during hotplug.
@MainActor
public final class ShellProductController {
    public var onWindowAction:
        ((UInt64, ShellWindowAction) -> Void)?

    public private(set) var wallpapersByOutput:
        [UInt32: ShellWallpaperProduct] = [:]
    public private(set) var barsByOutput: [UInt32: ShellBarProduct] = [:]
    public private(set) var windows: [ShellWindowSnapshot] = []
    public private(set) var clockText = ""
    public private(set) var batteryLevel: BatteryLevel = .absent

    public init() {}

    public func makeWallpaper(
        forOutput outputID: UInt32,
        sourcePath: String,
        sourceSize: Size
    ) -> ShellWallpaperProduct {
        if let existing = wallpapersByOutput[outputID] {
            precondition(
                existing.sourcePath == sourcePath,
                "an output's wallpaper source is immutable while hosted")
            return existing
        }
        let wallpaper = ShellWallpaperProduct(
            sourcePath: sourcePath,
            sourceSize: sourceSize)
        wallpapersByOutput[outputID] = wallpaper
        return wallpaper
    }

    public func removeWallpaper(forOutput outputID: UInt32) {
        wallpapersByOutput[outputID] = nil
    }

    public func makeBar(forOutput outputID: UInt32) -> ShellBarProduct {
        if let existing = barsByOutput[outputID] { return existing }
        let bar = ShellBarProduct(
            windows: windows,
            clockText: clockText,
            batteryLevel: batteryLevel,
            onWindowAction: { [weak self] id, action in
                self?.onWindowAction?(id, action)
            })
        barsByOutput[outputID] = bar
        return bar
    }

    public func removeBar(forOutput outputID: UInt32) {
        barsByOutput[outputID] = nil
    }

    public func updateWindows(_ windows: [ShellWindowSnapshot]) {
        guard windows != self.windows else { return }
        self.windows = windows
        for bar in barsByOutput.values {
            bar.taskbarWidget.update(windows: windows)
        }
    }

    public func updateClock(displayText: String) {
        guard displayText != clockText else { return }
        clockText = displayText
        for bar in barsByOutput.values {
            bar.clockWidget.update(displayText: displayText)
        }
    }

    public func updateBattery(_ level: BatteryLevel) {
        guard level != batteryLevel else { return }
        batteryLevel = level
        for bar in barsByOutput.values {
            bar.batteryWidget.update(level)
        }
    }
}
