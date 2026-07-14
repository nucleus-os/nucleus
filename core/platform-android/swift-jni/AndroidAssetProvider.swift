// Asset checksum + path validation.
//
// The raw NUL-terminated path pointer is passed straight through to
// `nucleus_android_asset_open`. The djb2-ish checksum and path normalization
// are bit-exact.

import NucleusAndroidC

private let AASSET_MODE_BUFFER: Int32 = 3

enum AssetReadError: Error {
    case pathRejected
    case openFailed
    case readFailed
}

struct AndroidAssetProvider {
    var manager: UnsafeMutableRawPointer

    init(manager: UnsafeMutableRawPointer) {
        self.manager = manager
    }

    func smokeValue(path: UnsafePointer<CChar>) throws -> Int32 {
        if !isNormalizedAssetPath(path) {
            throw AssetReadError.pathRejected
        }

        guard let asset = nucleus_android_asset_open(manager, path, AASSET_MODE_BUFFER) else {
            throw AssetReadError.openFailed
        }
        defer { nucleus_android_asset_close(asset) }

        var checksum: UInt32 = 5381
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let readCount: Int32 = buffer.withUnsafeMutableBytes { raw in
                nucleus_android_asset_read(asset, raw.baseAddress, 1024)
            }
            if readCount < 0 { throw AssetReadError.readFailed }
            if readCount == 0 { break }

            let readLen = Int(readCount)
            for i in 0..<readLen {
                checksum = (checksum &* 33) &+ UInt32(buffer[i])
            }
        }

        let length = nucleus_android_asset_get_length64(asset)
        checksum = checksum &+ UInt32(truncatingIfNeeded: max(length, 0))
        return Int32(checksum & 0x7fffffff)
    }
}

private func isNormalizedAssetPath(_ path: UnsafePointer<CChar>) -> Bool {
    let slash = UInt8(ascii: "/")
    let dot = UInt8(ascii: ".")

    var len = 0
    while path[len] != 0 { len += 1 }

    if len == 0 || UInt8(bitPattern: path[0]) == slash { return false }

    var segmentStart = 0
    var i = 0
    while i <= len {
        if i == len || UInt8(bitPattern: path[i]) == slash {
            let segLen = i - segmentStart
            if segLen == 0 { return false }
            if segLen == 1 && UInt8(bitPattern: path[segmentStart]) == dot { return false }
            if segLen == 2 && UInt8(bitPattern: path[segmentStart]) == dot
                && UInt8(bitPattern: path[segmentStart + 1]) == dot { return false }
            segmentStart = i + 1
        }
        i += 1
    }
    return true
}
