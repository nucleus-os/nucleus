import TracyBridge

package enum Trace {
    package enum Color {
        package static let red: UInt32 = 0xff3030
        package static let yellow: UInt32 = 0xffcc33
        package static let blue: UInt32 = 0x409cff
        package static let green: UInt32 = 0x45d483
    }

    package static var enabled: Bool {
        swift_tracy_enabled()
    }

    package static var connected: Bool {
        swift_tracy_connected()
    }

    package static func beginZone(
        _ name: StaticString,
        color: UInt32 = 0,
        function: String = #function,
        file: String = #fileID,
        line: UInt = #line
    ) -> TraceZone {
        unsafe withStaticStringBytes(name) { namePointer, nameLength in
            function.withCString { functionPointer in
                file.withCString { filePointer in
                    unsafe TraceZone(
                        context: swift_tracy_begin_zone(
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

    package static func zone<Result>(
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

    package static func setThreadName(_ name: String) {
        name.withCString { pointer in
            unsafe swift_tracy_set_thread_name(pointer, name.utf8.count)
        }
    }

    package static func message(_ text: String) {
        text.withCString { pointer in
            unsafe swift_tracy_message(pointer, text.utf8.count)
        }
    }

    package static func message(_ text: String, color: UInt32) {
        text.withCString { pointer in
            unsafe swift_tracy_message_color(pointer, text.utf8.count, color)
        }
    }

    package static func plot(_ name: String, _ value: Double) {
        name.withCString { pointer in
            unsafe swift_tracy_plot(pointer, value)
        }
    }

    package static func plot(_ name: String, _ value: Int64) {
        name.withCString { pointer in
            unsafe swift_tracy_plot_int(pointer, value)
        }
    }

    package static func plot(_ name: String, _ value: UInt64) {
        plot(name, Int64(clamping: value))
    }

    /// Open/close a named discontinuous frame range. Tracy requires the name's
    /// storage to outlive the capture; the C++ bridge interns dynamic names.
    package static func frameMarkStart(_ name: String) {
        name.withCString { unsafe swift_tracy_frame_mark_start($0) }
    }

    package static func frameMarkEnd(_ name: String) {
        name.withCString { unsafe swift_tracy_frame_mark_end($0) }
    }
}

package struct TraceZone {
    private let context: SwiftTracyZoneContext

    fileprivate init(context: SwiftTracyZoneContext) {
        self.context = context
    }

    package func end() {
        swift_tracy_end_zone(context)
    }

    package func value(_ value: UInt64) {
        swift_tracy_zone_value(context, value)
    }

    package func text(_ text: String) {
        text.withCString { pointer in
            unsafe swift_tracy_zone_text(context, pointer, text.utf8.count)
        }
    }
}

/// Borrows the immutable, process-lifetime UTF-8 storage of `StaticString`.
/// The pointer is aligned for bytes and must not escape `body`.
@unsafe private func withStaticStringBytes<Result>(
    _ string: StaticString,
    _ body: (UnsafePointer<CChar>, Int) -> Result
) -> Result {
    let pointer = unsafe UnsafeRawPointer(string.utf8Start)
        .assumingMemoryBound(to: CChar.self)
    return unsafe body(pointer, string.utf8CodeUnitCount)
}
