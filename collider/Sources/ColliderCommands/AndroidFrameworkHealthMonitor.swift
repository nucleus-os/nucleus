import Foundation

struct AndroidFrameworkHealthMonitor {
    private struct LogCursor {
        var offset: UInt64 = 0
        var pending = Data()
    }

    private var cursors: [String: LogCursor] = [:]
    private var surfaceFlingerCrashCount = 0
    private var zygoteCrashCount = 0
    private var zygoteCrashProcessIDs: Set<Int32> = []
    private var systemServerCrashCount = 0
    private var systemServerCrashProcessIDs: Set<Int32> = []

    mutating func check(
        kernelLog: URL,
        frameworkLog: URL,
        diagnostics: URL
    ) throws {
        let kernel = try readNewLines(from: kernelLog)
        if kernel.wasTruncated {
            surfaceFlingerCrashCount = 0
            zygoteCrashCount = 0
            zygoteCrashProcessIDs.removeAll(keepingCapacity: true)
        }
        for line in kernel.lines {
            try inspectKernelLine(line, diagnostics: diagnostics)
        }

        let framework = try readNewLines(from: frameworkLog)
        if framework.wasTruncated {
            systemServerCrashCount = 0
            systemServerCrashProcessIDs.removeAll(keepingCapacity: true)
        }
        for line in framework.lines {
            try inspectFrameworkLine(line, diagnostics: diagnostics)
        }
    }

    private mutating func readNewLines(
        from log: URL
    ) throws -> (lines: [String], wasTruncated: Bool) {
        guard
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: log.path),
            let size = (attributes[.size] as? NSNumber)?.uint64Value
        else {
            return ([], false)
        }
        var cursor = cursors[log.path] ?? LogCursor()
        let wasTruncated = size < cursor.offset
        if wasTruncated {
            cursor.offset = 0
            cursor.pending.removeAll(keepingCapacity: true)
        }
        guard size > cursor.offset else {
            cursors[log.path] = cursor
            return ([], wasTruncated)
        }

        let handle = try FileHandle(forReadingFrom: log)
        defer { try? handle.close() }
        try handle.seek(toOffset: cursor.offset)
        guard let data = try handle.readToEnd(), !data.isEmpty else {
            cursors[log.path] = cursor
            return ([], wasTruncated)
        }
        cursor.offset += UInt64(data.count)
        cursor.pending.append(data)

        var lines: [String] = []
        while let newline = cursor.pending.firstIndex(of: 0x0A) {
            let line = String(
                decoding: cursor.pending[..<newline],
                as: UTF8.self)
            cursor.pending.removeSubrange(...newline)
            lines.append(line)
        }
        cursors[log.path] = cursor
        return (lines, wasTruncated)
    }

    private mutating func inspectKernelLine(
        _ line: String,
        diagnostics: URL
    ) throws {
        if line.contains("init: Service 'zygote'"),
            line.contains("received SIGKILL")
        {
            if let processID = initServiceProcessID(line),
                !zygoteCrashProcessIDs.insert(processID).inserted
            {
                return
            }
            zygoteCrashCount += 1
            if zygoteCrashCount >= 2 {
                throw failure(
                    "Android zygote was killed \(zygoteCrashCount) times "
                        + "before framework boot",
                    diagnostics: diagnostics)
            }
            return
        }
        if line.contains(
            "process with updatable components 'surfaceflinger' exited "
                + "4 times before boot completed")
        {
            throw failure(
                "Android init declared SurfaceFlinger critically crashing",
                diagnostics: diagnostics)
        }
        guard line.contains("init: Service 'surfaceflinger'"),
            line.contains("received SIGABRT")
                || line.contains("received SIGSEGV")
        else {
            return
        }
        surfaceFlingerCrashCount += 1
        if surfaceFlingerCrashCount >= 2 {
            throw failure(
                "SurfaceFlinger crashed \(surfaceFlingerCrashCount) times "
                    + "before framework boot",
                diagnostics: diagnostics)
        }
    }

    private func initServiceProcessID(_ line: String) -> Int32? {
        guard
            let marker = line.range(of: "(pid "),
            let end = line[marker.upperBound...].firstIndex(of: ")")
        else {
            return nil
        }
        return Int32(line[marker.upperBound..<end])
    }

    private mutating func inspectFrameworkLine(
        _ line: String,
        diagnostics: URL
    ) throws {
        if line.contains("Zygote.nativeSpecializeAppProcess")
            || line.contains("Zygote.specializeAppProcess")
        {
            throw failure(
                "Android zygote specialization failed before framework boot",
                diagnostics: diagnostics)
        }
        if line.contains("Transaction failed on small parcel") {
            throw failure(
                "Android Binder reported a failed small-parcel transaction",
                diagnostics: diagnostics)
        }
        if line.contains("Failed to create app data for") {
            throw failure(
                "Android PackageManager reported an installd app-data failure",
                diagnostics: diagnostics)
        }
        if line.contains("Cannot connect to Keystore daemon")
            || line.contains(
                "Could not create keystore key: Failed to initialize "
                    + "keystore key")
        {
            throw failure(
                "Android Keystore became unavailable before framework boot",
                diagnostics: diagnostics)
        }
        if let startCount = systemServerStartCount(line), startCount >= 2 {
            throw failure(
                "Android framework restarted system_server "
                    + "\(startCount) times before framework boot",
                diagnostics: diagnostics)
        }

        let processID: Int32?
        if line.contains(
            "AndroidRuntime: *** FATAL EXCEPTION IN SYSTEM PROCESS:")
        {
            processID = logcatProcessID(line)
        } else if line.contains("Fatal signal"),
            line.contains("(system_server)")
        {
            processID = nativeCrashProcessID(line)
        } else {
            return
        }
        if let processID,
            !systemServerCrashProcessIDs.insert(processID).inserted
        {
            return
        }
        systemServerCrashCount += 1
        if systemServerCrashCount >= 2 {
            throw failure(
                "system_server crashed \(systemServerCrashCount) times "
                    + "before framework boot",
                diagnostics: diagnostics)
        }
    }

    private func systemServerStartCount(_ line: String) -> Int? {
        let marker = "system_server_start: [start_count="
        guard
            let start = line.range(of: marker)?.upperBound,
            let end = line[start...].firstIndex(of: ",")
        else {
            return nil
        }
        return Int(line[start..<end])
    }

    private func logcatProcessID(_ line: String) -> Int32? {
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard
            let tag = fields.firstIndex(of: "AndroidRuntime:"),
            tag >= 3
        else {
            return nil
        }
        return Int32(fields[tag - 3])
    }

    private func nativeCrashProcessID(_ line: String) -> Int32? {
        let fields = line.split(whereSeparator: \.isWhitespace)
        guard
            let pid = fields.lastIndex(of: "pid"),
            fields.indices.contains(pid + 2),
            fields[pid + 2] == "(system_server)"
        else {
            return nil
        }
        return Int32(fields[pid + 1])
    }

    private func failure(
        _ reason: String,
        diagnostics: URL
    ) -> WorkspaceFailure {
        .message("\(reason); diagnostics: \(diagnostics.path)")
    }
}
