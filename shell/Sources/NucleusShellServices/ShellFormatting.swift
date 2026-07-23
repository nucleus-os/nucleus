package import FoundationEssentials
package import FoundationInternationalization

package enum ShellFormatting {
    package static func clockStyle(
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> Date.FormatStyle {
        var style = Date.FormatStyle(
            date: .omitted,
            time: .omitted,
            locale: locale,
            timeZone: timeZone)
        if locale.hourCycle == .zeroToEleven
            || locale.hourCycle == .zeroToTwentyThree
        {
            style = style.hour(.twoDigits(amPM: .omitted))
        } else {
            style = style.hour(.defaultDigits(amPM: .abbreviated))
        }
        return style.minute(.twoDigits)
    }

    package static func wallpaperPath(
        configuredPath: String?,
        homeDirectory: URL
    ) -> String {
        guard let configuredPath else {
            return homeDirectory
                .appendingPathComponent("Pictures", isDirectory: true)
                .appendingPathComponent("Wallpapers", isDirectory: true)
                .appendingPathComponent("q2zr6juo2rch1.jpeg")
                .path
        }
        if configuredPath == "~" {
            return homeDirectory.path
        }
        if configuredPath.hasPrefix("~/") {
            return homeDirectory
                .appendingPathComponent(String(configuredPath.dropFirst(2)))
                .path
        }
        return configuredPath
    }
}
