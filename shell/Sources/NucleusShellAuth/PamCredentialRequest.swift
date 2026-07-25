import Glibc
import NucleusShellAuthWire

package struct PamCredentialRequest: ~Copyable {
    package private(set) var storage: [UInt8]
    package let reservedCapacity: Int

    package init?(
        service: [UInt8],
        password: UnsafeRawBufferPointer
    ) {
        guard service.count <= PamHelperWire.maximumServiceBytes,
              password.count <= PamHelperWire.maximumPasswordBytes
        else { return nil }
        let fields = service.count.addingReportingOverflow(password.count)
        let framed = fields.partialValue.addingReportingOverflow(8)
        guard !fields.overflow, !framed.overflow,
              framed.partialValue <= 4_096
        else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(framed.partialValue)
        let capacity = bytes.capacity
        PamHelperWire.encodeField(service, into: &bytes)
        unsafe PamHelperWire.encodeField(password, into: &bytes)
        precondition(bytes.capacity == capacity)
        storage = bytes
        reservedCapacity = capacity
    }

    package mutating func scrub() {
        storage.withUnsafeMutableBytes {
            if let base = $0.baseAddress { unsafe explicit_bzero(base, $0.count) }
        }
    }
}
