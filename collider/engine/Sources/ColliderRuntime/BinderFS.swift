import ColliderPlatformC
import SystemPackage

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public struct BinderFSDeviceNumber: Hashable, Sendable {
    public let major: UInt32
    public let minor: UInt32

    public init(major: UInt32, minor: UInt32) {
        self.major = major
        self.minor = minor
    }
}

public enum BinderFS {
    public static func addDevice(
        control: FilePath,
        name: String
    ) throws -> BinderFSDeviceNumber {
        guard !name.isEmpty,
            name.utf8.count <= 255,
            name.allSatisfy({
                $0.isASCII
                    && ($0.isLowercase || $0.isNumber || $0 == "-")
            })
        else {
            throw BinderFSFailure.invalidDeviceName(name)
        }
        var major: UInt32 = 0
        var minor: UInt32 = 0
        let status = control.string.withCString { controlPath in
            name.withCString { deviceName in
                unsafe collider_binderfs_add_device(
                    controlPath,
                    deviceName,
                    &major,
                    &minor)
            }
        }
        guard status == 0 else {
            throw BinderFSFailure.system(
                operation: "create binderfs device \(name)",
                code: errno)
        }
        return BinderFSDeviceNumber(major: major, minor: minor)
    }
}

public enum BinderFSFailure: Error, CustomStringConvertible, Sendable {
    case invalidDeviceName(String)
    case system(operation: String, code: Int32)

    public var description: String {
        switch self {
        case .invalidDeviceName(let name):
            "invalid binderfs device name: \(name)"
        case .system(let operation, let code):
            "\(operation) failed with errno \(code)"
        }
    }
}
