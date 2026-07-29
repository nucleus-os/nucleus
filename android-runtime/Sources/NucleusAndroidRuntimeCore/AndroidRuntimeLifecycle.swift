import Foundation

public struct AndroidFrameworkMountLedger {
    private var mountPoints: [URL] = []

    public init() {}

    public mutating func record(_ mountPoint: URL) {
        mountPoints.append(mountPoint)
    }

    public mutating func takeInReverseOrder() -> [URL] {
        defer { mountPoints.removeAll(keepingCapacity: false) }
        return mountPoints.reversed()
    }
}

public func androidPersistentDataMountPoint(instance: URL) -> URL {
    instance.appendingPathComponent(
        "persistent-data",
        isDirectory: true)
}

public func androidLXCPrimaryFailure(logFile: URL) -> String? {
    guard let contents = try? String(
        contentsOf: logFile,
        encoding: .utf8)
    else { return nil }
    let lines = contents.split(separator: "\n").map(String.init)
    if let hookLoaderFailure = lines.first(where: {
        $0.contains("produced output:")
            && $0.contains("error while loading shared libraries:")
    }) {
        return hookLoaderFailure
    }
    return lines.first { $0.contains(" ERROR ") }
}

public struct AndroidLXCStartInvocation: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]

    public init(
        name: String,
        configuration: String,
        logFile: String
    ) {
        executable = "sudo"
        arguments = [
            "--non-interactive",
            "systemd-run",
            "--scope",
            "--quiet",
            "--collect",
            "--unit",
            name,
            "--property",
            "Delegate=yes",
            "--",
            "lxc-start",
            "--foreground",
            "--name",
            name,
            "--rcfile",
            configuration,
            "--logfile",
            logFile,
            "--logpriority",
            "TRACE",
        ]
    }
}

public struct AndroidLogcatInvocation: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]

    public init(name: String, sinceEpochSecond: Int64) {
        executable = "sudo"
        arguments = [
            "--non-interactive",
            "lxc-attach",
            "--name",
            name,
            "--",
            "/system/bin/logcat",
            "-b",
            "all",
            "-D",
            "-v",
            "threadtime,year,usec,uid,descriptive",
            "-T",
            "\(sinceEpochSecond).000",
        ]
    }
}
