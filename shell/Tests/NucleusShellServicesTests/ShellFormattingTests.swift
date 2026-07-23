import FoundationEssentials
import FoundationInternationalization
import Testing
@testable import NucleusShellServices

@Suite struct ShellFormattingTests {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let nineFortyOne = Date(timeIntervalSince1970: 9 * 3600 + 41 * 60)

    @Test func shortenedClockPreservesLocalizedTwelveHourDisplay() {
        let text = nineFortyOne.formatted(ShellFormatting.clockStyle(
            locale: Locale(identifier: "en_US_POSIX"),
            timeZone: utc))

        #expect(text == "9:41\u{202F}AM")
    }

    @Test func shortenedClockPreservesLocalizedTwentyFourHourDisplay() {
        let text = nineFortyOne.formatted(ShellFormatting.clockStyle(
            locale: Locale(identifier: "de_DE"),
            timeZone: utc))

        #expect(text == "09:41")
    }

    @Test func wallpaperDefaultsAndTildeUseTheExplicitHomeDirectory() {
        let home = URL(fileURLWithPath: "/home/nucleus", isDirectory: true)

        #expect(ShellFormatting.wallpaperPath(
            configuredPath: nil,
            homeDirectory: home
        ) == "/home/nucleus/Pictures/Wallpapers/q2zr6juo2rch1.jpeg")
        #expect(ShellFormatting.wallpaperPath(
            configuredPath: "~/Pictures/custom.png",
            homeDirectory: home
        ) == "/home/nucleus/Pictures/custom.png")
        #expect(ShellFormatting.wallpaperPath(
            configuredPath: "/srv/wallpapers/custom.png",
            homeDirectory: home
        ) == "/srv/wallpapers/custom.png")
    }
}
