import Foundation
import Glibc
import NucleusAndroidPresentationQualification

private struct Arguments {
    var broker: String?
    var brokerSocket: String?
    var workload: String?
    var expectedRenderDevice: String?
    var wayland = "wayland-0"
    var output: String?
    var supportBundle: String?
    var frames: UInt64 = 600

    static func parse(_ values: [String]) throws -> Arguments {
        var result = Arguments()
        var index = 1
        while index < values.count {
            let option = values[index]
            func value() throws -> String {
                guard index + 1 < values.count else {
                    throw ArgumentFailure("\(option) requires a value")
                }
                return values[index + 1]
            }
            switch option {
            case "--broker":
                result.broker = try value()
                index += 1
            case "--broker-socket":
                result.brokerSocket = try value()
                index += 1
            case "--workload":
                result.workload = try value()
                index += 1
            case "--expected-render-device":
                result.expectedRenderDevice = try value()
                index += 1
            case "--wayland":
                result.wayland = try value()
                index += 1
            case "--output":
                result.output = try value()
                index += 1
            case "--support-bundle":
                result.supportBundle = try value()
                index += 1
            case "--frames":
                guard let frames = UInt64(try value()), frames > 0 else {
                    throw ArgumentFailure("--frames must be a positive integer")
                }
                result.frames = frames
                index += 1
            case "--help", "-h":
                print(Self.usage)
                exit(0)
            default:
                throw ArgumentFailure("unknown argument: \(option)")
            }
            index += 1
        }
        guard result.broker != nil,
              result.brokerSocket != nil,
              result.workload != nil,
              result.expectedRenderDevice != nil,
              result.output != nil,
              result.supportBundle != nil
        else {
            throw ArgumentFailure(Self.usage)
        }
        return result
    }

    static let usage = """
    Usage: nucleus-android-presentation-qualifier
      --broker PATH --broker-socket PATH
      --workload PATH --expected-render-device PATH
      --output DIRECTORY --support-bundle PATH
      [--wayland NAME] [--frames COUNT]
    """
}

private struct ArgumentFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@main
private struct NucleusAndroidPresentationQualifier {
    @MainActor
    static func main() async {
        do {
            let arguments = try Arguments.parse(CommandLine.arguments)
            let summary = try await PresentationQualificationRunner(
                configuration: PresentationQualificationConfiguration(
                    brokerExecutable: arguments.broker!,
                    brokerSocket: URL(fileURLWithPath: arguments.brokerSocket!),
                    guestWorkloadExecutable: arguments.workload!,
                    expectedRenderDevice: arguments.expectedRenderDevice!,
                    waylandSocket: arguments.wayland,
                    outputDirectory: URL(fileURLWithPath: arguments.output!),
                    supportBundle: URL(fileURLWithPath: arguments.supportBundle!),
                    frameCount: arguments.frames)
            ).run()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            print(String(decoding: try encoder.encode(summary), as: UTF8.self))
            exit(summary.technicalPass ? 0 : 2)
        } catch {
            FileHandle.standardError.write(
                Data("nucleus-android-presentation-qualifier: \(error)\n".utf8))
            exit(1)
        }
    }
}
