import Foundation

public func isValidHostKernelConfiguration(_ data: Data) -> Bool {
    guard !data.isEmpty else {
        return false
    }
    if data.count >= 2, data[data.startIndex] == 0x1f,
        data[data.index(after: data.startIndex)] == 0x8b
    {
        return true
    }
    guard let contents = String(data: data, encoding: .utf8) else {
        return false
    }
    return contents.split(whereSeparator: \.isNewline).contains {
        $0.hasPrefix("CONFIG_") || $0.hasPrefix("# CONFIG_")
    }
}
