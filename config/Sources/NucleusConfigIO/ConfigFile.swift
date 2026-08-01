import Foundation
import NucleusConfig

/// Locating and reading the session configuration file.
public enum ConfigFile {
    public static let directoryName = "nucleus"
    public static let fileName = "config.json"

    /// `$XDG_CONFIG_HOME/nucleus/config.json`, falling back to
    /// `$HOME/.config/nucleus/config.json`.
    ///
    /// Returns nil only when neither variable is set, which means there is no
    /// meaningful place to look rather than that the file is missing.
    public static func defaultPath(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let configHome = environment["XDG_CONFIG_HOME"], !configHome.isEmpty {
            return "\(configHome)/\(directoryName)/\(fileName)"
        }
        if let home = environment["HOME"], !home.isEmpty {
            return "\(home)/.config/\(directoryName)/\(fileName)"
        }
        return nil
    }

    /// Read and resolve one configuration file.
    ///
    /// An absent file resolves to the built-in defaults with no diagnostics: a
    /// user who has never written a configuration is not in an error state, and
    /// the session must come up regardless.
    public static func load(path: String) -> ConfigLoadOutcome {
        let data: Data
        do {
            data = try Data(
                contentsOf: URL(filePath: path), options: [.mappedIfSafe])
        } catch let error as CocoaError
            where error.code == .fileReadNoSuchFile
        {
            return .loaded(.defaults, warnings: [])
        } catch {
            return .failed([
                ConfigDiagnostic(
                    severity: .error,
                    message: "could not read configuration: \(error)")
            ])
        }
        return ConfigLoader.load(text: String(decoding: data, as: UTF8.self))
    }

    /// Read from the default location. Also yields defaults when no location
    /// can be determined at all.
    public static func loadDefault(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ConfigLoadOutcome {
        guard let path = defaultPath(environment: environment) else {
            return .loaded(.defaults, warnings: [])
        }
        return load(path: path)
    }
}
