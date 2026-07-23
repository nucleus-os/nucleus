public import FoundationEssentials
import FoundationInternationalization

#if os(Linux)
  import Glibc
#endif

public typealias LaunchableAppID = String

public struct LaunchableAppRecord: Sendable, Equatable {
  public var id: LaunchableAppID
  public var name: String
  public var desktopFileID: String
  public var iconName: String
  public var executable: [String]
  public var categories: [String]

  public init(
    id: LaunchableAppID,
    name: String,
    desktopFileID: String,
    iconName: String = "",
    executable: [String],
    categories: [String] = []
  ) {
    self.id = id
    self.name = name
    self.desktopFileID = desktopFileID
    self.iconName = iconName
    self.executable = executable
    self.categories = categories
  }
}

public struct DesktopApplicationIndex: Sendable {
  public var applications: [LaunchableAppRecord]

  public init(applications: [LaunchableAppRecord] = []) {
    self.applications = applications
  }

  public static func resolved(
    environment: [String: String]? = nil,
    fileManager: FileManager = .default
  ) -> DesktopApplicationIndex {
    DesktopApplicationIndex(
      applications: scanApplications(
        environment: environment ?? appDiscoveryEnvironment(),
        fileManager: fileManager))
  }

  public func app(id: LaunchableAppID) -> LaunchableAppRecord? {
    applications.first { $0.id == id }
  }

  public func preferredApp(matching ids: [String], executable fallbackExecutable: String? = nil)
    -> LaunchableAppRecord?
  {
    for id in ids {
      if let app = app(id: id) { return app }
      if let app = applications.first(where: { $0.desktopFileID == id }) { return app }
    }
    if let fallbackExecutable {
      return applications.first { $0.executable.first == fallbackExecutable }
    }
    return nil
  }

  private static func scanApplications(
    environment: [String: String],
    fileManager: FileManager
  ) -> [LaunchableAppRecord] {
    var records: [LaunchableAppRecord] = []
    for directory in applicationDirectories(environment: environment) {
      for url in desktopFiles(in: directory, fileManager: fileManager) {
        if let record = parseDesktopFile(url: url, root: directory, fileManager: fileManager) {
          records.append(record)
        }
      }
    }
    var seen: Set<LaunchableAppID> = []
    return
      records
      .filter { seen.insert($0.id).inserted }
      .sorted(using: KeyPathComparator(\.name, comparator: String.Comparator(options: [.numeric])))
  }

  private static func desktopFiles(in root: URL, fileManager: FileManager) -> [URL] {
    var pendingDirectories = [root]
    var desktopFiles: [URL] = []

    while let directory = pendingDirectories.popLast() {
      guard
        let entries = try? fileManager.contentsOfDirectory(atPath: directory.path).sorted()
      else { continue }

      for entry in entries {
        let url = directory.appendingPathComponent(entry)
        if url.pathExtension == "desktop" {
          desktopFiles.append(url)
          continue
        }

        guard
          let attributes = try? fileManager.attributesOfItem(atPath: url.path),
          attributes[.type] as? FileAttributeType == .typeDirectory
        else { continue }
        pendingDirectories.append(url)
      }
    }

    return desktopFiles.sorted { $0.path < $1.path }
  }

  private static func applicationDirectories(environment: [String: String]) -> [URL] {
    var dirs: [URL] = []
    if let dataHome = environment["XDG_DATA_HOME"], !dataHome.isEmpty {
      dirs.append(
        URL(fileURLWithPath: dataHome, isDirectory: true).appendingPathComponent(
          "applications", isDirectory: true))
    } else if let home = environment["HOME"], !home.isEmpty {
      dirs.append(
        URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(
          ".local/share/applications", isDirectory: true))
    }
    let dataDirs =
      environment["XDG_DATA_DIRS"]?.split(separator: ":").map(String.init) ?? [
        "/usr/local/share", "/usr/share",
      ]
    dirs.append(
      contentsOf: dataDirs.map {
        URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(
          "applications", isDirectory: true)
      })
    return dirs
  }

  public static func appDiscoveryEnvironment(
    base: [String: String] = ProcessInfo.processInfo.environment,
    currentValue: ((String) -> String?)? = nil
  ) -> [String: String] {
    var environment = base
    let valueForKey = currentValue ?? currentCEnvironmentValue
    for key in appDiscoveryEnvironmentKeys {
      if let value = valueForKey(key) {
        environment[key] = value
      } else {
        environment.removeValue(forKey: key)
      }
    }
    return environment
  }

  private static func currentCEnvironmentValue(_ key: String) -> String? {
    #if os(Linux)
      // Nucleus treats the process environment as immutable after bring-up.
      // `getenv` therefore returns a live NUL-terminated value for the duration
      // of this immediate copy; tests inject `currentValue` instead of mutating it.
      guard let value = unsafe getenv(key) else { return nil }
      return unsafe String(cString: value)
    #else
      return ProcessInfo.processInfo.environment[key]
    #endif
  }

  private static let appDiscoveryEnvironmentKeys = [
    "HOME",
    "XDG_DATA_HOME",
    "XDG_DATA_DIRS",
  ]

  private static func parseDesktopFile(url: URL, root: URL, fileManager: FileManager)
    -> LaunchableAppRecord?
  {
    guard let data = fileManager.contents(atPath: url.path),
      let text = String(data: data, encoding: .utf8)
    else { return nil }

    var inEntry = false
    var fields: [String: String] = [:]
    for rawLine in text.split(whereSeparator: \.isNewline) {
      let line = trimmedWhitespace(rawLine)
      if line.isEmpty || line.hasPrefix("#") { continue }
      if line.hasPrefix("[") && line.hasSuffix("]") {
        inEntry = line == "[Desktop Entry]"
        continue
      }
      guard inEntry, let equals = line.firstIndex(of: "=") else { continue }
      let key = String(line[..<equals])
      let value = String(line[line.index(after: equals)...])
      if fields[key] == nil {
        fields[key] = value
      }
    }

    guard fields["Type"] == nil || fields["Type"] == "Application" else { return nil }
    if fields["Hidden"] == "true" || fields["NoDisplay"] == "true" { return nil }
    guard let name = fields["Name"], !name.isEmpty,
      let exec = fields["Exec"], !exec.isEmpty
    else { return nil }

    let desktopID = desktopFileID(for: url, root: root)
    let executable = shellWords(removingDesktopFieldCodes(from: exec))
    guard !executable.isEmpty else { return nil }
    let categories =
      fields["Categories"]?
      .split(separator: ";")
      .map(String.init)
      .filter { !$0.isEmpty } ?? []
    return LaunchableAppRecord(
      id: desktopID,
      name: name,
      desktopFileID: desktopID,
      iconName: fields["Icon"] ?? "",
      executable: executable,
      categories: categories
    )
  }

  private static func desktopFileID(for url: URL, root: URL) -> String {
    let rootPath = root.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    let relative =
      path.hasPrefix(rootPath + "/")
      ? String(path.dropFirst(rootPath.count + 1)) : url.lastPathComponent
    return relative.replacing("/", with: "-")
  }

  private static func removingDesktopFieldCodes(from exec: String) -> String {
    var result = ""
    var iterator = exec.makeIterator()
    while let char = iterator.next() {
      if char == "%" {
        _ = iterator.next()
      } else {
        result.append(char)
      }
    }
    return result
  }

  private static func shellWords(_ command: String) -> [String] {
    var words: [String] = []
    var current = ""
    var quote: Character?
    var escaping = false
    for char in command {
      if escaping {
        current.append(char)
        escaping = false
        continue
      }
      if char == "\\" {
        escaping = true
        continue
      }
      if let activeQuote = quote {
        if char == activeQuote {
          quote = nil
        } else {
          current.append(char)
        }
        continue
      }
      if char == "'" || char == "\"" {
        quote = char
      } else if char.isWhitespace {
        if !current.isEmpty {
          words.append(current)
          current.removeAll(keepingCapacity: true)
        }
      } else {
        current.append(char)
      }
    }
    if !current.isEmpty {
      words.append(current)
    }
    return words
  }
}

private func trimmedWhitespace(_ value: Substring) -> Substring {
  var lowerBound = value.startIndex
  while lowerBound < value.endIndex, value[lowerBound].isWhitespace {
    value.formIndex(after: &lowerBound)
  }

  var upperBound = value.endIndex
  while upperBound > lowerBound {
    let previous = value.index(before: upperBound)
    guard value[previous].isWhitespace else { break }
    upperBound = previous
  }
  return value[lowerBound..<upperBound]
}
