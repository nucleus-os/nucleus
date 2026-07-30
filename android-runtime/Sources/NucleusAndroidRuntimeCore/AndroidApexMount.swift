import NucleusAndroidRuntimePlatformC

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

extension AndroidRuntimeApexPayloadFileSystem {
    fileprivate var platformValue: UInt32 {
        switch self {
        case .erofs:
            UInt32(NUCLEUS_ANDROID_RUNTIME_APEX_PAYLOAD_FILESYSTEM_EROFS.rawValue)
        case .ext4:
            UInt32(NUCLEUS_ANDROID_RUNTIME_APEX_PAYLOAD_FILESYSTEM_EXT4.rawValue)
        }
    }
}

public struct AndroidApexMountRequest: Equatable, Sendable {
    public let rootFileSystem: String
    public let source: String
    public let target: String
    public let payloadFileSystem: AndroidRuntimeApexPayloadFileSystem
    public let payloadOffset: UInt64

    public init(
        rootFileSystem: String,
        source: String,
        target: String,
        payloadFileSystem: AndroidRuntimeApexPayloadFileSystem,
        payloadOffset: UInt64
    ) throws {
        let rootComponents = try absoluteComponents(
            rootFileSystem,
            field: "root filesystem")
        guard rootComponents.count == 5,
            rootComponents[0] == "run",
            rootComponents[1] == "nucleus",
            rootComponents[2] == "android",
            rootComponents[3].hasPrefix("nucleus-android-runtime-"),
            !rootComponents[3]
                .dropFirst("nucleus-android-runtime-".count)
                .isEmpty,
            rootComponents[3]
                .dropFirst("nucleus-android-runtime-".count)
                .allSatisfy(\.isNumber),
            rootComponents[4] == "rootfs"
        else {
            throw AndroidApexMountFailure.invalidRootFileSystem(
                rootFileSystem)
        }

        let sourceComponents = try absoluteComponents(
            source,
            field: "APEX source")
        let permittedPartitions: Set<Substring> = [
            "system",
            "system_ext",
            "product",
            "vendor",
        ]
        guard sourceComponents.count == 3,
            permittedPartitions.contains(sourceComponents[0]),
            sourceComponents[1] == "apex",
            sourceComponents[2].hasSuffix(".apex")
        else {
            throw AndroidApexMountFailure.invalidSource(source)
        }
        let sourceName = sourceComponents[2].dropLast(".apex".count)
        guard isValidPackageName(sourceName) else {
            throw AndroidApexMountFailure.invalidSource(source)
        }

        let targetComponents = try absoluteComponents(
            target,
            field: "APEX target")
        guard targetComponents.count == 2,
            targetComponents[0] == "apex",
            let separator = targetComponents[1].lastIndex(of: "@")
        else {
            throw AndroidApexMountFailure.invalidTarget(target)
        }
        let targetName = targetComponents[1][..<separator]
        let targetVersion = targetComponents[1][
            targetComponents[1].index(after: separator)...]
        guard isValidPackageName(targetName),
            !targetVersion.isEmpty,
            targetVersion.allSatisfy(\.isNumber),
            targetVersion.contains(where: { $0 != "0" })
        else {
            throw AndroidApexMountFailure.invalidTarget(target)
        }
        guard payloadOffset > 0,
            payloadOffset.isMultiple(of: 4_096)
        else {
            throw AndroidApexMountFailure.invalidPayloadOffset(
                payloadOffset)
        }

        self.rootFileSystem = rootFileSystem
        self.source = source
        self.target = target
        self.payloadFileSystem = payloadFileSystem
        self.payloadOffset = payloadOffset
    }

    public func mount() throws {
        guard geteuid() == 0 else {
            throw AndroidApexMountFailure.requiresRoot
        }
        let status = rootFileSystem.withCString { rootPath in
            source.withCString { sourcePath in
                target.withCString { targetPath in
                    unsafe nucleus_android_runtime_mount_apex_in_chroot(
                        rootPath,
                        sourcePath,
                        targetPath,
                        payloadFileSystem.platformValue,
                        payloadOffset)
                }
            }
        }
        guard status == 0 else {
            throw AndroidApexMountFailure.system(
                operation: "mount \(source) at \(target)",
                code: errno)
        }
    }
}

public enum AndroidApexMountFailure:
    Error,
    CustomStringConvertible,
    Equatable,
    Sendable
{
    case invalidPath(field: String, value: String)
    case invalidRootFileSystem(String)
    case invalidSource(String)
    case invalidTarget(String)
    case invalidPayloadOffset(UInt64)
    case requiresRoot
    case system(operation: String, code: Int32)

    public var description: String {
        switch self {
        case .invalidPath(let field, let value):
            "invalid \(field) path: \(value)"
        case .invalidRootFileSystem(let path):
            "invalid Android framework root filesystem: \(path)"
        case .invalidSource(let path):
            "invalid Android APEX source: \(path)"
        case .invalidTarget(let path):
            "invalid Android APEX target: \(path)"
        case .invalidPayloadOffset(let offset):
            "invalid Android APEX payload offset: \(offset)"
        case .requiresRoot:
            "the internal Android APEX mount operation requires root"
        case .system(let operation, let code):
            "\(operation) failed with errno \(code)"
        }
    }
}

private func absoluteComponents(
    _ path: String,
    field: String
) throws -> [Substring] {
    let components = path.split(
        separator: "/",
        omittingEmptySubsequences: false)
    guard components.first == "",
        components.count > 1,
        components.dropFirst().allSatisfy({
            !$0.isEmpty && $0 != "." && $0 != ".."
        })
    else {
        throw AndroidApexMountFailure.invalidPath(
            field: field,
            value: path)
    }
    return Array(components.dropFirst())
}

private func isValidPackageName(
    _ name: Substring
) -> Bool {
    guard let first = name.first,
        first.isASCII,
        first.isLetter
    else {
        return false
    }
    return name.allSatisfy {
        $0.isASCII
            && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_")
    }
}
