import Foundation

@MainActor
public final class CursorTheme {
    public static let shared = CursorTheme()

    private init() {}

    func load(name: String, size: UInt32) -> XCursorImage {
        let theme = ProcessInfo.processInfo.environment["XCURSOR_THEME"].flatMap { $0.isEmpty ? nil : $0 } ?? "default"
        let names = ([name] + ["left_ptr", "arrow", "top_left_arrow"]).reduce(into: [String]()) { result, candidate in
            if !result.contains(candidate) { result.append(candidate) }
        }
        for candidate in names {
            if let image = load(theme: theme, name: candidate, size: size, depth: 0) {
                return image
            }
        }
        return defaultCursor()
    }

    private func load(theme: String, name: String, size: UInt32, depth: UInt32) -> XCursorImage? {
        guard depth <= 16 else { return nil }
        var inherits: [String] = []
        for directory in libraryPath() {
            let themeURL = directory.appendingPathComponent(theme, isDirectory: true)
            let cursorURL = themeURL.appendingPathComponent("cursors").appendingPathComponent(name)
            if let data = try? Data(contentsOf: cursorURL),
               let image = XCursor.parse(data, targetSize: size) {
                return image
            }
            if inherits.isEmpty {
                inherits = readInherits(themeURL.appendingPathComponent("index.theme"))
            }
        }
        for parent in inherits where parent != theme {
            if let image = load(theme: parent, name: name, size: size, depth: depth + 1) {
                return image
            }
        }
        return nil
    }

    private func libraryPath() -> [URL] {
        let env = ProcessInfo.processInfo.environment
        let raw: String
        if let path = env["XCURSOR_PATH"], !path.isEmpty {
            raw = path
        } else if let xdg = env["XDG_DATA_HOME"], !xdg.isEmpty, xdg.first == "/" {
            raw = "\(xdg)/icons:" + defaultPaths
        } else if let home = env["HOME"], !home.isEmpty {
            raw = "\(home)/.local/share/icons:" + defaultPaths
        } else {
            raw = defaultPaths
        }
        return raw.split(separator: ":").compactMap { component in
            let expanded = expandTilde(String(component))
            return expanded.isEmpty ? nil : URL(fileURLWithPath: expanded, isDirectory: true)
        }
    }

    private func expandTilde(_ path: String) -> String {
        guard path.first == "~" else { return path }
        guard let home = ProcessInfo.processInfo.environment["HOME"] else { return "" }
        return home + path.dropFirst()
    }

    private func readInherits(_ url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("Inherits") else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            return parts[1]
                .split { $0 == "," || $0 == ";" || $0 == ":" }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        return []
    }

    private func defaultCursor() -> XCursorImage {
        let width = 24
        let height = 24
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let arrow: [(Int, Int)] = [
            (0, 1), (0, 2), (0, 3), (0, 4), (0, 5), (0, 6),
            (0, 7), (0, 8), (0, 9), (0, 10), (0, 11), (0, 12),
            (0, 7), (0, 6), (0, 5), (2, 5), (3, 6), (3, 6),
            (4, 7), (4, 7), (5, 7), (5, 7), (0, 0), (0, 0),
        ]
        for row in 0..<arrow.count {
            let (start, end) = arrow[row]
            guard start < end else { continue }
            for col in start..<end {
                let prev = row > 0 ? arrow[row - 1] : (0, 0)
                let next = row + 1 < arrow.count ? arrow[row + 1] : (0, 0)
                let edge = row == 0 || col == start || col == end - 1 ||
                    row == arrow.count - 1 ||
                    col < prev.0 || col >= prev.1 ||
                    col < next.0 || col >= next.1
                let index = (row * width + col) * 4
                bytes[index + 0] = edge ? 0x00 : 0xFF
                bytes[index + 1] = edge ? 0x00 : 0xFF
                bytes[index + 2] = edge ? 0x00 : 0xFF
                bytes[index + 3] = 0xFF
            }
        }
        return XCursorImage(width: 24, height: 24, hotSpotX: 1, hotSpotY: 1, pixels: Data(bytes))
    }
}

private let defaultPaths = "~/.icons:/usr/share/icons:/usr/share/pixmaps:~/.cursors:/usr/share/cursors/xorg-x11:/usr/X11R6/lib/X11/icons"
