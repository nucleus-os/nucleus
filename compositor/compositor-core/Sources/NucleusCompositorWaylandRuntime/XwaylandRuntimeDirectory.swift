import Foundation
import Glibc

enum XwaylandRuntimeDirectoryError: Error, Equatable {
    case missingPath
    case relativePath
    case openFailed(Int32)
    case invalidDirectory
    case wrongOwner
    case unsafePermissions
    case childCreationFailed(Int32)
    case childOpenFailed(Int32)
    case invalidChildDirectory
}

final class XwaylandRuntimeDirectory {
    let fileDescriptor: Int32

    private init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    deinit {
        _ = close(fileDescriptor)
    }

    static func openFromEnvironment() throws -> XwaylandRuntimeDirectory {
        guard let value = unsafe getenv("XDG_RUNTIME_DIR") else {
            throw XwaylandRuntimeDirectoryError.missingPath
        }
        return try open(runtimePath: unsafe String(cString: value))
    }

    static func open(
        runtimePath: String,
        expectedUID: uid_t = geteuid()
    ) throws -> XwaylandRuntimeDirectory {
        guard runtimePath.hasPrefix("/") else {
            throw XwaylandRuntimeDirectoryError.relativePath
        }
        let base = runtimePath.withCString {
            unsafe Glibc.open(
                $0,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard base >= 0 else {
            throw XwaylandRuntimeDirectoryError.openFailed(errno)
        }
        defer { _ = close(base) }
        var metadata = stat()
        guard unsafe fstat(base, &metadata) == 0,
            metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        else {
            throw XwaylandRuntimeDirectoryError.invalidDirectory
        }
        guard metadata.st_uid == expectedUID else {
            throw XwaylandRuntimeDirectoryError.wrongOwner
        }
        guard metadata.st_mode & 0o077 == 0 else {
            throw XwaylandRuntimeDirectoryError.unsafePermissions
        }

        let creation = "nucleus".withCString {
            unsafe mkdirat(base, $0, 0o700)
        }
        guard creation == 0 || errno == EEXIST else {
            throw XwaylandRuntimeDirectoryError.childCreationFailed(errno)
        }
        let child = "nucleus".withCString {
            unsafe openat(
                base,
                $0,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard child >= 0 else {
            throw XwaylandRuntimeDirectoryError.childOpenFailed(errno)
        }
        var childMetadata = stat()
        guard unsafe fstat(child, &childMetadata) == 0,
            childMetadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
            childMetadata.st_uid == expectedUID,
            childMetadata.st_mode & 0o777 == 0o700
        else {
            _ = close(child)
            throw XwaylandRuntimeDirectoryError.invalidChildDirectory
        }
        return XwaylandRuntimeDirectory(fileDescriptor: child)
    }
}

final class XwaylandTraceSink {
    static let fileLimit = 3
    static let byteLimit = 8 * 1024 * 1024

    private let directoryFD: Int32
    private let nameGenerator: () -> String?
    private var files: [Int32] = []
    private var activeIndex = 0
    private(set) var activeBytes = 0
    private(set) var droppedBytes: UInt64 = 0
    private(set) var failed = false

    init(
        directoryFD: Int32,
        nameGenerator: @escaping () -> String? = {
            "xwayland-\(UUID().uuidString.lowercased()).log"
        }
    ) {
        self.directoryFD = directoryFD
        self.nameGenerator = nameGenerator
    }

    deinit {
        for descriptor in files {
            _ = close(descriptor)
        }
    }

    func drain(_ descriptor: Int32) -> Bool {
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = bytes.withUnsafeMutableBytes {
                unsafe read(descriptor, $0.baseAddress, $0.count)
            }
            if count > 0 {
                consume(Array(bytes.prefix(count)))
                continue
            }
            if count == 0 { return false }
            if errno == EINTR { continue }
            return errno == EAGAIN || errno == EWOULDBLOCK
        }
    }

    func consume(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { unsafe write($0) }
    }

    @unsafe private func write(_ bytes: UnsafeRawBufferPointer) {
        guard unsafe !bytes.isEmpty else { return }
        guard !failed else {
            droppedBytes &+= UInt64(bytes.count)
            return
        }
        var offset = 0
        while offset < bytes.count {
            if files.isEmpty || activeBytes == Self.byteLimit {
                guard rotate() else {
                    failed = true
                    droppedBytes &+= UInt64(bytes.count - offset)
                    return
                }
            }
            let accepted = min(
                bytes.count - offset,
                Self.byteLimit - activeBytes)
            let descriptor = files[activeIndex]
            var written = 0
            while written < accepted {
                let result = unsafe Glibc.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset + written),
                    accepted - written)
                if result > 0 {
                    written += result
                } else if result == -1 && errno == EINTR {
                    continue
                } else {
                    failed = true
                    droppedBytes &+= UInt64(bytes.count - offset - written)
                    return
                }
            }
            activeBytes += accepted
            offset += accepted
        }
    }

    private func rotate() -> Bool {
        if files.count < Self.fileLimit {
            guard let descriptor = createLogFile() else { return false }
            files.append(descriptor)
            activeIndex = files.count - 1
        } else {
            activeIndex = (activeIndex + 1) % Self.fileLimit
            let descriptor = files[activeIndex]
            guard ftruncate(descriptor, 0) == 0,
                lseek(descriptor, 0, SEEK_SET) == 0
            else {
                return false
            }
        }
        activeBytes = 0
        return true
    }

    private func createLogFile() -> Int32? {
        for _ in 0..<32 {
            guard let name = nameGenerator() else { return nil }
            let descriptor = name.withCString {
                unsafe openat(
                    directoryFD,
                    $0,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                    0o600)
            }
            if descriptor >= 0 { return descriptor }
            if errno != EEXIST { return nil }
        }
        return nil
    }
}
