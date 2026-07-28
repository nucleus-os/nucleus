import Testing
import NucleusUI
@testable import NucleusShellProduct

@MainActor
@Suite(.uiContext)
struct NativeBarProductTests {
    @Test func shellWindowDisplayTitleHasDeterministicFallbacks() {
        #expect(ShellWindowSnapshot(id: 1, title: "Editor").displayTitle == "Editor")
        #expect(ShellWindowSnapshot(id: 2, applicationID: "org.example.App").displayTitle
            == "org.example.App")
        #expect(ShellWindowSnapshot(id: 3).displayTitle == "Untitled")
    }

    @Test func clockRetainsItsLabelAcrossUpdates() {
        let clock = ClockWidget()
        let label = clock.label
        clock.update(displayText: "9:41 AM")
        #expect(clock.label === label)
        #expect(label.text == "9:41 AM")
        #expect(clock.accessibilityLabel == "Time, 9:41 AM")
    }

    @Test func taskbarPublishesTypedActionsAndIgnoresUnknownWindows() {
        let taskbar = TaskbarWidget()
        taskbar.update(windows: [
            ShellWindowSnapshot(id: 41, title: "Terminal", isActive: true),
            ShellWindowSnapshot(id: 42, applicationID: "org.example.Editor"),
        ])
        var received: [(UInt64, ShellWindowAction)] = []
        taskbar.onWindowAction = { received.append(($0, $1)) }

        taskbar.perform(.activate, forWindow: 42)
        taskbar.perform(.setMinimized(true), forWindow: 41)
        taskbar.perform(.close, forWindow: 999)

        taskbar.update(windows: [
            ShellWindowSnapshot(id: 42, title: "Renamed Editor"),
        ])
        taskbar.perform(.close, forWindow: 41)

        #expect(received.count == 2)
        #expect(received[0].0 == 42)
        #expect(received[0].1 == .activate)
        #expect(received[1].0 == 41)
        #expect(received[1].1 == .setMinimized(true))
        #expect(taskbar.windows.map(\.id) == [42])
    }

    @Test func productCompositionOwnsTheNativeBarSections() {
        let product = ShellProductController()
        product.updateWindows([
            ShellWindowSnapshot(id: 7, title: "Browser", isMinimized: true),
        ])
        product.updateClock(displayText: "10:08 PM")
        product.updateBattery(BatteryLevel(fraction: 0.62))

        let first = product.makeBar(forOutput: 1)
        let second = product.makeBar(forOutput: 2)
        #expect(first.barView.widgets(in: .start).first === first.taskbarWidget)
        #expect(first.barView.widgets(in: .center).first === first.clockWidget)
        #expect(first.barView.widgets(in: .end).first === first.batteryWidget)
        #expect(first.barView.backgroundColor == Color(0, 0, 0, 1))
        #expect(first.taskbarWidget.windows.map(\.id) == [7])
        #expect(second.clockWidget.displayText == "10:08 PM")
        #expect(second.batteryWidget.level.fraction == 0.62)

        product.removeBar(forOutput: 1)
        #expect(product.barsByOutput[1] == nil)
        #expect(product.barsByOutput[2] === second)
    }

    @Test func productCompositionOwnsCoveringWallpapersPerOutput() {
        let product = ShellProductController()
        let first = product.makeWallpaper(
            forOutput: 1,
            sourcePath: "/wallpapers/first.jpeg",
            sourceSize: Size(width: 16, height: 9))
        let same = product.makeWallpaper(
            forOutput: 1,
            sourcePath: "/wallpapers/first.jpeg",
            sourceSize: Size(width: 16, height: 9))
        let second = product.makeWallpaper(
            forOutput: 2,
            sourcePath: "/wallpapers/second.jpeg",
            sourceSize: Size(width: 16, height: 9))

        #expect(first === same)
        #expect(first.imageView.source == .resource("/wallpapers/first.jpeg"))
        #expect(first.imageView.contentMode == .cover)
        #expect(first.imageView.layerPresentation.role == .wallpaper)
        #expect(!first.imageView.isHitTestingEnabled)
        #expect(product.wallpapersByOutput[2] === second)

        product.removeWallpaper(forOutput: 1)
        #expect(product.wallpapersByOutput[1] == nil)
        #expect(product.wallpapersByOutput[2] === second)
    }
}
