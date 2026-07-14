import Foundation
import NucleusCompositorShellSurface

#if os(Linux)
  import Glibc
#endif

@MainActor
public final class LauncherService {
  public static let shared = LauncherService()

  private var applicationIndex: DesktopApplicationIndex
  private var launched: [Process] = []

  public init(applicationIndex: DesktopApplicationIndex = .resolved()) {
    self.applicationIndex = applicationIndex
  }

  public func reloadApplications(_ index: DesktopApplicationIndex = .resolved()) {
    applicationIndex = index
  }

  public func launchableApps() -> [LaunchableAppRecord] {
    applicationIndex.applications
  }

  @discardableResult
  public func launch(_ app: LaunchableAppRecord) -> Bool {
    spawn(arguments(for: app))
  }

  @discardableResult
  public func launchApp(id: LaunchableAppID) -> Bool {
    guard let app = applicationIndex.app(id: id) else { return false }
    return launch(app)
  }

  public func playScreenshotSound() {
    _ = spawn(
      ["pw-play", "/usr/share/sounds/freedesktop/stereo/screen-capture.oga"], logLaunch: false)
  }

  @discardableResult
  public func launchPreferred(ids: [String], fallback: [String]) -> Bool {
    if let app = applicationIndex.preferredApp(matching: ids, executable: fallback.first) {
      return launch(app)
    }
    return spawn(fallback)
  }

  @discardableResult
  public func spawn(_ args: [String], logLaunch: Bool = true) -> Bool {
    _ = logLaunch
    guard !args.isEmpty else { return false }
    let launchArgs = Self.adjustedArguments(args)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = launchArgs
    process.environment = launcherEnvironment()
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.terminationHandler = { [weak self, weak process] _ in
      guard let self, let process else { return }
      Task { @MainActor in
        self.launched.removeAll { $0 === process }
      }
    }

    do {
      try process.run()
      launched.append(process)
      return true
    } catch {
      return false
    }
  }

  private func arguments(for app: LaunchableAppRecord) -> [String] {
    if Self.isFirefox(app) {
      return Self.adjustedFirefoxArguments(app.executable)
    }
    return app.executable
  }

  private static func isFirefox(_ app: LaunchableAppRecord) -> Bool {
    let ids = [app.id, app.desktopFileID]
    return ids.contains { value in
      let lower = value.lowercased()
      return lower == "firefox" || lower == "firefox.desktop" || lower.hasSuffix("-firefox.desktop")
        || lower.contains("org.mozilla.firefox")
    } || app.executable.first.map(isFirefoxExecutable) == true
  }

  static func adjustedArguments(_ args: [String]) -> [String] {
    let sanitized = sanitizedSessionEnvironmentOverrides(expandedEnvSplitArguments(args))
    guard let executableIndex = executableArgumentIndex(in: sanitized) else {
      return sanitized
    }
    let executable = sanitized[executableIndex]
    if isFirefoxExecutable(executable) {
      return adjustedFirefoxArguments(sanitized)
    }
    if isChromeExecutable(executable) {
      return adjustedChromeArguments(sanitized)
    }
    return sanitized
  }

  private static func adjustedFirefoxArguments(_ args: [String]) -> [String] {
    var adjusted = args
    if !containsFirefoxProfileOverride(adjusted) {
      adjusted += ["-P", "NucleusProfile"]
    }
    if !containsFirefoxNoRemote(adjusted) {
      adjusted.append("-no-remote")
    }
    return adjusted
  }

  private static func containsFirefoxProfileOverride(_ args: [String]) -> Bool {
    args.contains { arg in
      arg.hasPrefix("-P") || arg == "--profile" || arg.hasPrefix("--profile=") || arg == "-profile"
        || arg.hasPrefix("-profile=")
    }
  }

  private static func containsFirefoxNoRemote(_ args: [String]) -> Bool {
    args.contains { arg in
      arg == "-no-remote" || arg == "--no-remote"
    }
  }

  /// Force Chrome/Chromium onto native Wayland with server-side window
  /// decorations so it honors the compositor's xdg-decoration `server_side`
  /// mode and stops drawing its own client-side titlebar and rounded corners
  /// (which otherwise double up under the compositor's chrome).
  private static func adjustedChromeArguments(_ args: [String]) -> [String] {
    var adjusted = args
    if !containsChromeOzonePlatform(adjusted) {
      adjusted.append("--ozone-platform=wayland")
    }
    if !containsChromeWaylandDecorations(adjusted) {
      adjusted.append("--enable-features=WaylandWindowDecorations")
    }
    return adjusted
  }

  private static func containsChromeOzonePlatform(_ args: [String]) -> Bool {
    args.contains { $0 == "--ozone-platform" || $0.hasPrefix("--ozone-platform=") }
  }

  private static func containsChromeWaylandDecorations(_ args: [String]) -> Bool {
    args.contains { arg in
      arg.hasPrefix("--enable-features=") && arg.contains("WaylandWindowDecorations")
    }
  }

  private static func executableArgumentIndex(in args: [String]) -> Int? {
    guard let first = args.first else { return nil }
    if isEnvExecutable(first) {
      return envPayloadIndex(in: args)
    }
    return 0
  }

  private static func expandedEnvSplitArguments(_ args: [String]) -> [String] {
    guard let first = args.first, isEnvExecutable(first) else {
      return args
    }

    var expanded = [first]
    var index = 1
    while index < args.count {
      let arg = args[index]
      if arg == "-S" || arg == "--split-string" {
        if index + 1 < args.count {
          expanded.append(contentsOf: splitEnvString(args[index + 1]))
          index += 2
        } else {
          index += 1
        }
        continue
      }
      if arg.hasPrefix("--split-string=") {
        expanded.append(contentsOf: splitEnvString(String(arg.dropFirst("--split-string=".count))))
        index += 1
        continue
      }
      if arg.hasPrefix("-S"), arg.count > 2 {
        expanded.append(contentsOf: splitEnvString(String(arg.dropFirst(2))))
        index += 1
        continue
      }
      expanded.append(arg)
      index += 1
    }
    return expanded
  }

  private static func splitEnvString(_ text: String) -> [String] {
    var result: [String] = []
    var current = ""
    var quote: Character?
    var escaping = false

    for character in text {
      if escaping {
        current.append(character)
        escaping = false
        continue
      }
      if character == "\\" {
        escaping = true
        continue
      }
      if let activeQuote = quote {
        if character == activeQuote {
          quote = nil
        } else {
          current.append(character)
        }
        continue
      }
      if character == "'" || character == "\"" {
        quote = character
        continue
      }
      if character.isWhitespace {
        if !current.isEmpty {
          result.append(current)
          current = ""
        }
        continue
      }
      current.append(character)
    }
    if escaping {
      current.append("\\")
    }
    if quote != nil {
      return []
    }
    if !current.isEmpty {
      result.append(current)
    }
    return result
  }

  private static func envPayloadIndex(in args: [String]) -> Int? {
    var index = 1
    while index < args.count {
      let arg = args[index]
      if arg == "-i" || arg == "-" || arg == "--ignore-environment" {
        index += 1
        continue
      }
      if arg == "-u" || arg == "--unset" || arg == "-C" || arg == "--chdir" || arg == "-a"
        || arg == "--argv0" || arg == "-S" || arg == "--split-string"
      {
        index += 2
        continue
      }
      if arg.hasPrefix("-u") || arg.hasPrefix("--unset=") || arg.hasPrefix("-C")
        || arg.hasPrefix("--chdir=") || arg.hasPrefix("-a") || arg.hasPrefix("--argv0=")
        || arg.hasPrefix("-S") || arg.hasPrefix("--split-string=")
      {
        index += 1
        continue
      }
      if arg.hasPrefix("-") {
        index += 1
        continue
      }
      if environmentAssignmentKey(arg) != nil {
        index += 1
        continue
      }
      return index
    }
    return nil
  }

  private static func environmentAssignmentKey(_ arg: String) -> String? {
    guard let equals = arg.firstIndex(of: "="), equals != arg.startIndex else {
      return nil
    }
    let key = String(arg[..<equals])
    return key.contains("/") ? nil : key
  }

  private static func sanitizedSessionEnvironmentOverrides(_ args: [String]) -> [String] {
    guard let first = args.first, isEnvExecutable(first) else {
      return args
    }

    var sanitized = [first]
    var index = 1
    while index < args.count {
      let arg = args[index]

      if arg == "-i" || arg == "-" || arg == "--ignore-environment" {
        index += 1
        continue
      }

      if arg == "--" {
        sanitized.append(arg)
        index += 1
        continue
      }

      if arg == "-u" || arg == "--unset" {
        guard index + 1 < args.count else {
          sanitized.append(arg)
          index += 1
          continue
        }
        let key = args[index + 1]
        if isSessionEnvironmentKey(key) {
          index += 2
          continue
        }
        sanitized.append(arg)
        sanitized.append(key)
        index += 2
        continue
      }
      if arg.hasPrefix("--unset=") {
        let key = String(arg.dropFirst("--unset=".count))
        if !isSessionEnvironmentKey(key) {
          sanitized.append(arg)
        }
        index += 1
        continue
      }
      if arg.hasPrefix("-u"), arg.count > 2 {
        let key = String(arg.dropFirst(2))
        if !isSessionEnvironmentKey(key) {
          sanitized.append(arg)
        }
        index += 1
        continue
      }

      if arg == "-C" || arg == "--chdir" || arg == "-a" || arg == "--argv0" || arg == "-S"
        || arg == "--split-string"
      {
        sanitized.append(arg)
        if index + 1 < args.count {
          sanitized.append(args[index + 1])
          index += 2
        } else {
          index += 1
        }
        continue
      }
      if arg.hasPrefix("--chdir=") || arg.hasPrefix("--argv0=") || arg.hasPrefix("--split-string=")
        || arg.hasPrefix("-C") || arg.hasPrefix("-a") || arg.hasPrefix("-S")
      {
        sanitized.append(arg)
        index += 1
        continue
      }

      if arg.hasPrefix("-") {
        sanitized.append(arg)
        index += 1
        continue
      }

      if let key = environmentAssignmentKey(arg) {
        if !isSessionEnvironmentKey(key) {
          sanitized.append(arg)
        }
        index += 1
        continue
      }

      sanitized.append(contentsOf: args[index...])
      break
    }
    return sanitized
  }

  private static func isSessionEnvironmentKey(_ key: String) -> Bool {
    sessionEnvironmentKeys.contains(key)
  }

  private static func isFirefoxExecutable(_ executable: String) -> Bool {
    let lower = URL(fileURLWithPath: executable).lastPathComponent.lowercased()
    return lower == "firefox" || lower == "firefox-bin" || lower == "org.mozilla.firefox"
  }

  private static func isChromeExecutable(_ executable: String) -> Bool {
    let lower = URL(fileURLWithPath: executable).lastPathComponent.lowercased()
    return lower.contains("chrome") || lower.contains("chromium")
  }

  private static func isEnvExecutable(_ executable: String) -> Bool {
    URL(fileURLWithPath: executable).lastPathComponent == "env"
  }

  private func launcherEnvironment() -> [String: String] {
    Self.launcherEnvironment(
      base: ProcessInfo.processInfo.environment,
      currentValue: Self.currentCEnvironmentValue,
      loginShell: Self.loginShell
    )
  }

  static func launcherEnvironment(
    base: [String: String],
    currentValue: (String) -> String?
  ) -> [String: String] {
    launcherEnvironment(
      base: base,
      currentValue: currentValue,
      loginShell: Self.loginShell
    )
  }

  static func launcherEnvironment(
    base: [String: String],
    currentValue: (String) -> String?,
    loginShell: () -> String?
  ) -> [String: String] {
    var environment = base
    for key in Self.sessionEnvironmentKeys {
      if Self.clearOnlySessionEnvironmentKeys.contains(key) {
        environment.removeValue(forKey: key)
        continue
      }
      if let value = currentValue(key) {
        environment[key] = value
      } else {
        environment.removeValue(forKey: key)
      }
    }
    if let shell = loginShell(), !shell.isEmpty {
      environment["SHELL"] = shell
    }
    return environment
  }

  private nonisolated static func loginShell() -> String? {
    #if os(Linux)
      guard let passwd = getpwuid(getuid()), let shell = passwd.pointee.pw_shell else { return nil }
      let value = String(cString: shell)
      return value.isEmpty ? nil : value
    #else
      let value = ProcessInfo.processInfo.environment["SHELL"]
      return value?.isEmpty == false ? value : nil
    #endif
  }

  private static func currentCEnvironmentValue(_ key: String) -> String? {
    #if os(Linux)
      guard let value = getenv(key) else { return nil }
      return String(cString: value)
    #else
      return ProcessInfo.processInfo.environment[key]
    #endif
  }

  private static let sessionEnvironmentKeys = [
    "NUCLEUS_SESSION_ID",
    "NUCLEUS_SESSION_RUNTIME_DIR",
    "NUCLEUS_SESSION_STATE_ROOT",
    "NUCLEUS_EPHEMERAL_CONFIG",
    "XDG_RUNTIME_DIR",
    "DBUS_SESSION_BUS_ADDRESS",
    "DBUS_STARTER_ADDRESS",
    "DBUS_STARTER_BUS_TYPE",
    "XDG_CONFIG_HOME",
    "XDG_DATA_HOME",
    "XDG_STATE_HOME",
    "XDG_CACHE_HOME",
    "GIT_CONFIG_GLOBAL",
    "PIPEWIRE_RUNTIME_DIR",
    "PIPEWIRE_REMOTE",
    "PULSE_SERVER",
    "WAYLAND_DISPLAY",
    "WAYLAND_SOCKET",
    "DISPLAY",
    "XAUTHORITY",
    "XDG_SESSION_TYPE",
    "XDG_CURRENT_DESKTOP",
    "XDG_SESSION_DESKTOP",
    "DESKTOP_SESSION",
  ]

  private static let clearOnlySessionEnvironmentKeys = [
    "DBUS_STARTER_ADDRESS",
    "DBUS_STARTER_BUS_TYPE",
    "WAYLAND_SOCKET",
    "XAUTHORITY",
  ]
}
