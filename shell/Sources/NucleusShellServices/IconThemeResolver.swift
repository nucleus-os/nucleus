internal import FoundationEssentials

/// One directory a theme keeps icons in, and what size they are.
struct IconSearchDirectory: Sendable, Equatable {
    var path: String
    /// The nominal pixel size. Meaningless for `isScalable` entries.
    var size: Int
    var isScalable: Bool
}

/// Resolves an XDG icon name to a file on disk.
///
/// Needed by anything displaying a *third-party* application — the taskbar, the
/// dock, the tray, the launcher. Glyphs cover the shell's own iconography; this
/// covers everyone else's, and the two are unrelated systems on purpose.
///
/// Size-aware, because the alternative is visibly worse: scaling a 1024px PNG
/// down to a 22px bar slot produces mush, and scaling a 16px one up produces
/// blur. Scalable SVG wins outright; among bitmaps the smallest size at or above
/// the target wins, so a downscale is always gentle.
public final class IconThemeResolver {
    /// The theme to search first. Falling back through `hicolor` is the XDG
    /// contract — it is the theme every application is guaranteed to install
    /// into.
    public var themeName: String {
        didSet { if themeName != oldValue { invalidate() } }
    }

    /// Bumped whenever the cache is dropped. A caller holding resolved paths
    /// compares this to know its icons are stale, without being called back.
    public private(set) var generation: UInt64 = 0

    private let roots: [String]
    private var directoryCache: [String: [IconSearchDirectory]] = [:]

    /// - Parameter roots: icon-theme roots, most specific first. Defaults to the
    ///   XDG search path.
    public init(themeName: String = "hicolor", roots: [String]? = nil) {
        self.themeName = themeName
        self.roots = roots ?? IconThemeResolver.defaultRoots()
    }

    /// The XDG icon search path: the user's own icons first, then data
    /// directories, then the legacy pixmaps location that older applications
    /// still use.
    static func defaultRoots(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        var result: [String] = []
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : $0 }

        if let home {
            result.append("\(home)/.icons")
        }
        if let dataHome = environment["XDG_DATA_HOME"], !dataHome.isEmpty {
            result.append("\(dataHome)/icons")
        } else if let home {
            result.append("\(home)/.local/share/icons")
        }

        let dataDirs = environment["XDG_DATA_DIRS"] ?? "/usr/local/share:/usr/share"
        for dir in dataDirs.split(separator: ":") where !dir.isEmpty {
            result.append("\(dir)/icons")
        }
        result.append("/usr/share/pixmaps")
        return result
    }

    /// Drop everything cached. Call when the icon theme changes.
    public func invalidate() {
        directoryCache.removeAll(keepingCapacity: true)
        generation &+= 1
    }

    /// The best file for `name` at `size`, or `nil` when the theme has none.
    ///
    /// A miss is cached as a miss. Icon lookups happen per window in a taskbar
    /// that rebuilds often, and re-walking the filesystem for an icon known to
    /// be absent is the expensive case, not the cheap one.
    public func resolve(_ name: String, size: Int = 22) -> String? {
        // An absolute path is already an answer. Applications set icon fields to
        // full paths often enough that treating one as a theme name would fail
        // for no reason.
        if name.hasPrefix("/") {
            return fileExists(name) ? name : nil
        }
        guard !name.isEmpty else { return nil }

        return search(name, size: size)
    }

    private func search(_ name: String, size: Int) -> String? {
        for theme in themeChain() {
            var exactBitmap: String?
            var smallestAbove: (path: String, size: Int)?
            var largestBelow: (path: String, size: Int)?

            for directory in searchDirectories(theme: theme) {
                guard let path = iconFile(in: directory.path, named: name) else {
                    continue
                }
                // Scalable wins outright: it is exact at every size.
                if directory.isScalable { return path }

                if directory.size == size {
                    exactBitmap = exactBitmap ?? path
                    continue
                }
                // Prefer the smallest size at or above the target, so any
                // rescale is a gentle downscale.
                if directory.size > size {
                    if smallestAbove == nil || directory.size < smallestAbove!.size {
                        smallestAbove = (path, directory.size)
                    }
                } else if largestBelow == nil || directory.size > largestBelow!.size {
                    // Nothing big enough: retain the largest below the target.
                    largestBelow = (path, directory.size)
                }
            }
            if let exactBitmap { return exactBitmap }
            if let smallestAbove { return smallestAbove.path }
            if let largestBelow { return largestBelow.path }
        }

        // Last resort: a flat directory with no theme structure, which is what
        // /usr/share/pixmaps is.
        for root in roots {
            if let path = iconFile(in: root, named: name) { return path }
        }
        return nil
    }

    /// The theme, then `hicolor`. Inheritance beyond one level is not followed:
    /// it needs `index.theme` parsing, and in practice a theme that lacks an
    /// icon falls through to `hicolor` anyway.
    private func themeChain() -> [String] {
        themeName == "hicolor" ? ["hicolor"] : [themeName, "hicolor"]
    }

    /// Directories a theme keeps icons in, discovered by walking rather than by
    /// parsing `index.theme`.
    ///
    /// The layout is `<root>/<theme>/<size>/<category>` or
    /// `<root>/<theme>/<category>/<size>`, and both appear in the wild — reading
    /// the sizes off the directory names handles both without an INI parser.
    func searchDirectories(theme: String) -> [IconSearchDirectory] {
        if let cached = directoryCache[theme] { return cached }

        var result: [IconSearchDirectory] = []
        for root in roots {
            let themeRoot = "\(root)/\(theme)"
            for entry in subdirectories(of: themeRoot) {
                let path = "\(themeRoot)/\(entry)"
                if entry == "scalable" {
                    for category in subdirectories(of: path) {
                        result.append(IconSearchDirectory(
                            path: "\(path)/\(category)", size: 0, isScalable: true))
                    }
                    result.append(IconSearchDirectory(
                        path: path, size: 0, isScalable: true))
                    continue
                }
                guard let size = IconThemeResolver.parseSize(entry) else {
                    // A category directory at the top level: sizes are below it.
                    for sub in subdirectories(of: path) {
                        if let nested = IconThemeResolver.parseSize(sub) {
                            result.append(IconSearchDirectory(
                                path: "\(path)/\(sub)", size: nested,
                                isScalable: false))
                        }
                    }
                    continue
                }
                for category in subdirectories(of: path) {
                    result.append(IconSearchDirectory(
                        path: "\(path)/\(category)", size: size, isScalable: false))
                }
                result.append(IconSearchDirectory(
                    path: path, size: size, isScalable: false))
            }
        }
        directoryCache[theme] = result
        return result
    }

    /// `48x48` and `48` both appear. `symbolic` and category names do not parse,
    /// which is how they are told apart.
    static func parseSize(_ component: String) -> Int? {
        if let separator = component.firstIndex(of: "x") {
            let width = String(component[component.startIndex..<separator])
            return Int(width)
        }
        return Int(component)
    }

    /// Extensions in preference order. SVG first because it is exact at any
    /// size; XPM last because it is ancient and only pixmaps still carries it.
    private static let extensions = ["svg", "png", "xpm"]

    private func iconFile(in directory: String, named name: String) -> String? {
        for ext in IconThemeResolver.extensions {
            let path = "\(directory)/\(name).\(ext)"
            if fileExists(path) { return path }
        }
        return nil
    }

    private func fileExists(_ path: String) -> Bool {
        var isDirectory = false
        return FileManager.default.fileExists(
            atPath: path, isDirectory: &isDirectory)
            && !isDirectory
    }

    private func subdirectories(of path: String) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path)
        else { return [] }
        return entries.filter { entry in
            var isDirectory = false
            return FileManager.default.fileExists(
                atPath: "\(path)/\(entry)", isDirectory: &isDirectory)
                && isDirectory
        }.sorted()
    }
}
