import Foundation

public struct AndroidRuntimeMountLedger {
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
        helperExecutable: String,
        ownerProcessIdentifier: Int32,
        name: String,
        configuration: String,
        logFile: String
    ) {
        let supervisor = AndroidContainerSupervisorInvocation(
            helperExecutable: helperExecutable,
            ownerProcessIdentifier: ownerProcessIdentifier,
            name: name,
            configuration: configuration,
            logFile: logFile)
        executable = supervisor.executable
        arguments = supervisor.arguments
    }
}

public func androidRuntimeContainerNames(
    _ output: String
) -> [String] {
    output.split(whereSeparator: \.isWhitespace)
        .map(String.init)
        .filter(isNucleusAndroidRuntimeContainerName)
}

public func isNucleusAndroidRuntimeContainerName(
    _ name: String
) -> Bool {
    for prefix in [
        "nucleus-android-runtime-",
        "nucleus-framework-",
    ] where name.hasPrefix(prefix) {
        let identifier = name.dropFirst(prefix.count)
        return !identifier.isEmpty
            && identifier.allSatisfy {
                $0.isASCII && $0.isNumber
            }
    }
    return false
}

public func androidRuntimeMountDiscoveryArguments(
    instance: String
) -> [String] {
    [
        "--target",
        instance,
        "--submounts",
        "--noheadings",
        "--raw",
        "--output",
        "TARGET",
    ]
}

public func androidRuntimeMountPoints(
    _ output: String,
    instance: String
) -> [String] {
    output.split(separator: "\n")
        .map(String.init)
        .filter {
            $0 == instance
                || $0.hasPrefix(instance + "/")
        }
        .sorted {
            let leftDepth = $0.split(separator: "/").count
            let rightDepth = $1.split(separator: "/").count
            if leftDepth == rightDepth {
                return $0 < $1
            }
            return leftDepth > rightDepth
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
