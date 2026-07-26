import Glibc
import NucleusDiagnostics
import Testing

@Test
func loggerFormatsAndRedirectsRecords() {
    var descriptors: [Int32] = [0, 0]
    #expect(unsafe pipe(&descriptors) == 0)
    defer {
        NucleusLogging.resetToStandardError()
        _ = close(descriptors[0])
        _ = close(descriptors[1])
    }

    NucleusLogging.redirect(toFileDescriptor: descriptors[1])
    NucleusLogger(subsystem: "test-subsystem").warning("test message")
    NucleusLogging.resetToStandardError()

    var bytes = [UInt8](repeating: 0, count: 256)
    let count = bytes.withUnsafeMutableBytes {
        unsafe read(descriptors[0], $0.baseAddress, $0.count)
    }
    #expect(count > 0)
    let line = String(decoding: bytes.prefix(Int(count)), as: UTF8.self)
    #expect(line == "[nucleus][warning][test-subsystem] test message\n")
}
