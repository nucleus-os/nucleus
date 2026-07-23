import Foundation
import Glibc
import NucleusAndroidSurfaceProbeCore

private struct Arguments {
    var configuration = SurfaceProbeConfiguration()

    static func parse(_ values: [String]) throws -> Arguments {
        var result = Arguments()
        var index = 1
        while index < values.count {
            let option = values[index]
            func value() throws -> String {
                guard index + 1 < values.count else {
                    throw ArgumentError("\(option) requires a value")
                }
                return values[index + 1]
            }
            switch option {
            case "--wayland":
                result.configuration.waylandSocket = try value()
                index += 1
            case "--broker":
                result.configuration.brokerSocket = try value()
                index += 1
            case "--width":
                guard let parsed = UInt32(try value()) else {
                    throw ArgumentError("--width must be an unsigned integer")
                }
                result.configuration.width = parsed
                index += 1
            case "--height":
                guard let parsed = UInt32(try value()) else {
                    throw ArgumentError("--height must be an unsigned integer")
                }
                result.configuration.height = parsed
                index += 1
            case "--frames":
                guard let parsed = UInt64(try value()) else {
                    throw ArgumentError("--frames must be an unsigned integer")
                }
                result.configuration.frameCount = parsed
                index += 1
            case "--timeout-ms":
                guard let parsed = Int32(try value()), parsed > 0 else {
                    throw ArgumentError("--timeout-ms must be a positive integer")
                }
                result.configuration.eventTimeoutMilliseconds = parsed
                index += 1
            case "--help", "-h":
                print("""
                Usage: nucleus-android-surface-probe [--wayland NAME]
                       [--broker PATH --width PIXELS --height PIXELS --frames COUNT]
                """)
                exit(0)
            default:
                throw ArgumentError("unknown argument: \(option)")
            }
            index += 1
        }
        if result.configuration.frameCount > 0,
           result.configuration.brokerSocket == nil {
            throw ArgumentError("--frames requires --broker")
        }
        return result
    }
}

private struct ArgumentError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

do {
    let arguments = try Arguments.parse(CommandLine.arguments)
    let report = try await AndroidSurfaceProbe(
        configuration: arguments.configuration
    ).run()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(report), as: UTF8.self))
} catch {
    FileHandle.standardError.write(Data("nucleus-android-surface-probe: \(error)\n".utf8))
    exit(1)
}
