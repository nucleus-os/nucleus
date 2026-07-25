import Foundation
import SwiftWaylandGenerator

do {
    try SwiftWaylandGenerator.run(arguments: CommandLine.arguments)
} catch {
    FileHandle.standardError.write(
        "\(error)\n".data(using: .utf8)!)
    exit(1)
}
