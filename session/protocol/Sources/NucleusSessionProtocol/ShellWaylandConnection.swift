public enum ShellWaylandConnectionFailure: Error, CustomStringConvertible {
    case invalidDescriptor(String)

    public var description: String {
        switch self {
        case .invalidDescriptor(let value):
            "invalid shell Wayland descriptor '\(value)'"
        }
    }
}

public enum ShellWaylandConnection {
    public static let descriptorArgument = "--nucleus-shell-wayland-fd"

    public static func inherited(
        arguments: [String] = CommandLine.arguments
    ) throws -> Int32? {
        let indices = arguments.indices.filter {
            arguments[$0] == descriptorArgument
        }
        guard !indices.isEmpty else { return nil }
        guard indices.count == 1, let index = indices.first else {
            throw ShellWaylandConnectionFailure.invalidDescriptor("<duplicate>")
        }
        guard arguments.indices.contains(index + 1),
            let descriptor = Int32(arguments[index + 1]), descriptor >= 3
        else {
            throw ShellWaylandConnectionFailure.invalidDescriptor(
                arguments.indices.contains(index + 1)
                    ? arguments[index + 1] : "<missing>")
        }
        return descriptor
    }
}
