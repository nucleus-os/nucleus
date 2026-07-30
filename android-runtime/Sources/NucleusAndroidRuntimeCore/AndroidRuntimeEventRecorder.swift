import Foundation

public struct AndroidRuntimeEventRecorder {
    private struct Event: Encodable {
        let elapsedMilliseconds: Int64
        let stage: String
        let fields: [String: String]
    }

    private let output: URL
    private let origin = ContinuousClock.now
    private let encoder = JSONEncoder()

    public init(output: URL) throws {
        self.output = output
        if !FileManager.default.fileExists(atPath: output.path) {
            _ = FileManager.default.createFile(
                atPath: output.path,
                contents: nil,
                attributes: [.posixPermissions: 0o600])
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: output.path)
    }

    public func record(
        _ stage: String,
        fields: [String: String] = [:]
    ) throws {
        var data = try encoder.encode(Event(
            elapsedMilliseconds: Self.milliseconds(
                origin.duration(to: ContinuousClock.now)),
            stage: stage,
            fields: fields))
        data.append(0x0A)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    public func recordHostSample(
        cgroup: URL,
        processIdentifiers: [String: Int32]
    ) throws {
        var fields: [String: String] = [:]
        for name in [
            "cpu.stat",
            "memory.current",
            "memory.events",
            "io.stat",
            "pids.current",
            "cgroup.events",
            "cgroup.controllers",
            "cgroup.subtree_control",
        ] {
            if let value = Self.read(cgroup.appendingPathComponent(name)) {
                fields["cgroup.\(name)"] = value
            }
        }
        for resource in ["cpu", "memory", "io"] {
            if let value = Self.read(URL(
                fileURLWithPath: "/proc/pressure/\(resource)"))
            {
                fields["pressure.\(resource)"] = value
            }
        }
        for (name, processIdentifier) in processIdentifiers {
            let process = URL(
                fileURLWithPath: "/proc/\(processIdentifier)",
                isDirectory: true)
            if let value = Self.read(process.appendingPathComponent("stat")) {
                fields["process.\(name).stat"] = value
            }
            if let value = Self.read(process.appendingPathComponent("wchan")) {
                fields["process.\(name).wchan"] = value
            }
        }
        try record("host.sample", fields: fields)
    }

    public static func milliseconds(_ duration: Duration) -> Int64 {
        let components = duration.components
        let seconds = components.seconds.multipliedReportingOverflow(
            by: 1_000)
        let attoseconds = components.attoseconds / 1_000_000_000_000_000
        if seconds.overflow {
            return components.seconds >= 0 ? .max : .min
        }
        return seconds.partialValue.addingReportingOverflow(
            Int64(attoseconds)
        ).partialValue
    }

    private static func read(_ url: URL) -> String? {
        guard let value = try? String(
            contentsOf: url,
            encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !value.isEmpty
        else {
            return nil
        }
        return value
    }
}
