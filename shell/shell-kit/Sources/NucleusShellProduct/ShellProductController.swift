package import NucleusUI

/// One output's retained wallpaper hierarchy.
@MainActor
package final class ShellWallpaperProduct {
    package let imageView: ImageView
    package let sourcePath: String

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
package final class ShellBarProduct {
    package let barView: BarView
    package let taskbarWidget: TaskbarWidget
    package let clockWidget: ClockWidget
    package let batteryWidget: BatteryWidget

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
package final class ShellProductController {
    package var onWindowAction: ((UInt64, ShellWindowAction) -> Void)?

    package private(set) var wallpapersByOutput: [UInt32: ShellWallpaperProduct] = [:]
    package private(set) var barsByOutput: [UInt32: ShellBarProduct] = [:]
    package private(set) var windows: [ShellWindowSnapshot] = []
    package private(set) var clockText = ""
    package private(set) var batteryLevel: BatteryLevel = .absent

    package init() {}

    package func makeWallpaper(
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

    package func removeWallpaper(forOutput outputID: UInt32) {
        wallpapersByOutput[outputID] = nil
    }

    package func makeBar(forOutput outputID: UInt32) -> ShellBarProduct {
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

    package func removeBar(forOutput outputID: UInt32) {
        barsByOutput[outputID] = nil
    }

    package func updateWindows(_ windows: [ShellWindowSnapshot]) {
        guard windows != self.windows else { return }
        self.windows = windows
        for bar in barsByOutput.values {
            bar.taskbarWidget.update(windows: windows)
        }
    }

    package func updateClock(displayText: String) {
        guard displayText != clockText else { return }
        clockText = displayText
        for bar in barsByOutput.values {
            bar.clockWidget.update(displayText: displayText)
        }
    }

    package func updateBattery(_ level: BatteryLevel) {
        guard level != batteryLevel else { return }
        batteryLevel = level
        for bar in barsByOutput.values {
            bar.batteryWidget.update(level)
        }
    }
}
