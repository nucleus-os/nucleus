import Glibc
import WaylandClientDispatch
import WaylandProtocolTypes

/// One format/modifier pair advertised by the compositor's v4+ DMA-BUF
/// feedback table.
public struct NucleusDesktopDmaBufFormat:
    Sendable, Equatable, Hashable
{
    public let format: UInt32
    public let modifier: UInt64

    public init(format: UInt32, modifier: UInt64) {
        self.format = format
        self.modifier = modifier
    }
}

@MainActor
@safe final class NucleusDesktopDmaBufFeedback:
    ZwpLinuxDmabufFeedbackV1Events
{
    private let proxy:
        WaylandProxy<ZwpLinuxDmabufFeedbackV1Client>
    private let onFormatsChanged:
        ([NucleusDesktopDmaBufFormat]) -> Void
    private var formatTable: [NucleusDesktopDmaBufFormat] = []
    private var pendingIndices: [UInt16] = []
    private var publishedFormats:
        [NucleusDesktopDmaBufFormat] = []

    init(
        proxy: WaylandProxy<ZwpLinuxDmabufFeedbackV1Client>,
        onFormatsChanged:
            @escaping ([NucleusDesktopDmaBufFormat]) -> Void
    ) {
        self.proxy = proxy
        self.onFormatsChanged = onFormatsChanged
    }

    func start() -> Bool {
        do {
            try proxy.installListener(self)
            return true
        } catch {
            return false
        }
    }

    func done(
        _ proxy:
            WaylandBorrowedProxy<ZwpLinuxDmabufFeedbackV1Client>
    ) {
        let unique = Array(Set(publishedFormats)).sorted {
            ($0.format, $0.modifier) < ($1.format, $1.modifier)
        }
        onFormatsChanged(unique)
        publishedFormats.removeAll(keepingCapacity: true)
    }

    func formatTable(
        _ proxy:
            WaylandBorrowedProxy<ZwpLinuxDmabufFeedbackV1Client>,
        fd: consuming WaylandClientOwnedFileDescriptor,
        size: UInt32
    ) {
        let descriptor = fd.take()
        defer { _ = close(descriptor) }
        formatTable = Self.readFormatTable(
            descriptor: descriptor, size: size)
    }

    func mainDevice(
        _ proxy:
            WaylandBorrowedProxy<ZwpLinuxDmabufFeedbackV1Client>,
        device: WaylandClientArrayView
    ) {}

    func trancheDone(
        _ proxy:
            WaylandBorrowedProxy<ZwpLinuxDmabufFeedbackV1Client>
    ) {
        for index in pendingIndices {
            guard Int(index) < formatTable.count else { continue }
            publishedFormats.append(formatTable[Int(index)])
        }
        pendingIndices.removeAll(keepingCapacity: true)
    }

    func trancheTargetDevice(
        _ proxy:
            WaylandBorrowedProxy<ZwpLinuxDmabufFeedbackV1Client>,
        device: WaylandClientArrayView
    ) {}

    func trancheFormats(
        _ proxy:
            WaylandBorrowedProxy<ZwpLinuxDmabufFeedbackV1Client>,
        indices: WaylandClientArrayView
    ) {
        pendingIndices =
            indices.copiedElements(of: UInt16.self) ?? []
    }

    func trancheFlags(
        _ proxy:
            WaylandBorrowedProxy<ZwpLinuxDmabufFeedbackV1Client>,
        flags: ZwpLinuxDmabufFeedbackV1TrancheFlags
    ) {}

    static func readFormatTable(
        descriptor: Int32,
        size: UInt32
    ) -> [NucleusDesktopDmaBufFormat] {
        let entrySize = 16
        guard descriptor >= 0,
              size > 0,
              size <= 1_048_576,
              Int(size).isMultiple(of: entrySize)
        else { return [] }
        var bytes = [UInt8](repeating: 0, count: Int(size))
        let byteCount = bytes.count
        var offset = 0
        while offset < byteCount {
            let count = bytes.withUnsafeMutableBytes {
                unsafe pread(
                    descriptor,
                    $0.baseAddress!.advanced(by: offset),
                    byteCount - offset,
                    off_t(offset))
            }
            guard count > 0 else { return [] }
            offset += count
        }
        var formats: [NucleusDesktopDmaBufFormat] = []
        formats.reserveCapacity(bytes.count / entrySize)
        for base in stride(
            from: 0, to: bytes.count, by: entrySize)
        {
            let format = loadUInt32LE(bytes, at: base)
            let modifier = loadUInt64LE(bytes, at: base + 8)
            formats.append(NucleusDesktopDmaBufFormat(
                format: format, modifier: modifier))
        }
        return formats
    }

    private static func loadUInt32LE(
        _ bytes: [UInt8], at index: Int
    ) -> UInt32 {
        UInt32(bytes[index])
            | UInt32(bytes[index + 1]) << 8
            | UInt32(bytes[index + 2]) << 16
            | UInt32(bytes[index + 3]) << 24
    }

    private static func loadUInt64LE(
        _ bytes: [UInt8], at index: Int
    ) -> UInt64 {
        var result: UInt64 = 0
        for byte in 0..<8 {
            result |= UInt64(bytes[index + byte])
                << UInt64(byte * 8)
        }
        return result
    }
}
