import TracyBridge

public enum Trace {
    public enum Color {
        public static let red: UInt32 = 0xff3030
        public static let yellow: UInt32 = 0xffcc33
        public static let blue: UInt32 = 0x409cff
        public static let green: UInt32 = 0x45d483
    }

    public static var enabled: Bool {
        swift_tracy.TraceBridge.enabled()
    }

    public static var connected: Bool {
        swift_tracy.TraceBridge.connected()
    }

    public static func beginZone(
        _ name: StaticString,
        color: UInt32 = 0,
        function: String = #function,
        file: String = #fileID,
        line: UInt = #line
    ) -> TraceZone {
        withStaticStringBytes(name) { namePointer, nameLength in
            function.withCString { functionPointer in
                file.withCString { filePointer in
                    TraceZone(context: swift_tracy.TraceBridge.beginZone(
                        namePointer,
                        nameLength,
                        functionPointer,
                        function.utf8.count,
                        filePointer,
                        file.utf8.count,
                        UInt32(clamping: line),
                        color
                    ))
                }
            }
        }
    }

    public static func zone<Result>(
        _ name: StaticString,
        color: UInt32 = 0,
        function: String = #function,
        file: String = #fileID,
        line: UInt = #line,
        _ body: () throws -> Result
    ) rethrows -> Result {
        let zone = beginZone(name, color: color, function: function, file: file, line: line)
        defer {
            zone.end()
        }
        return try body()
    }

    public static func setThreadName(_ name: String) {
        name.withCString { pointer in
            swift_tracy.TraceBridge.setThreadName(pointer, name.utf8.count)
        }
    }

    public static func message(_ text: String) {
        text.withCString { pointer in
            swift_tracy.TraceBridge.message(pointer, text.utf8.count)
        }
    }

    public static func message(_ text: String, color: UInt32) {
        text.withCString { pointer in
            swift_tracy.TraceBridge.messageColor(pointer, text.utf8.count, color)
        }
    }

    public static func plot(_ name: String, _ value: Double) {
        name.withCString { pointer in
            swift_tracy.TraceBridge.plot(pointer, value)
        }
    }

    public static func plot(_ name: String, _ value: Int64) {
        name.withCString { pointer in
            swift_tracy.TraceBridge.plotInt(pointer, value)
        }
    }

    public static func plot(_ name: String, _ value: UInt64) {
        plot(name, Int64(clamping: value))
    }

    /// Open/close a named discontinuous frame range. Tracy requires the name's
    /// storage to outlive the capture; the C++ bridge interns dynamic names.
    public static func frameMarkStart(_ name: String) {
        name.withCString { swift_tracy.TraceBridge.frameMarkStart($0) }
    }

    public static func frameMarkEnd(_ name: String) {
        name.withCString { swift_tracy.TraceBridge.frameMarkEnd($0) }
    }
}

public struct TraceZone {
    private let context: swift_tracy.ZoneContext

    fileprivate init(context: swift_tracy.ZoneContext) {
        self.context = context
    }

    public func end() {
        swift_tracy.TraceBridge.endZone(context)
    }

    public func value(_ value: UInt64) {
        swift_tracy.TraceBridge.zoneValue(context, value)
    }

    public func text(_ text: String) {
        text.withCString { pointer in
            swift_tracy.TraceBridge.zoneText(context, pointer, text.utf8.count)
        }
    }
}

private func withStaticStringBytes<Result>(
    _ string: StaticString,
    _ body: (UnsafePointer<CChar>, Int) -> Result
) -> Result {
    let pointer = UnsafeRawPointer(string.utf8Start).assumingMemoryBound(to: CChar.self)
    return body(pointer, string.utf8CodeUnitCount)
}
