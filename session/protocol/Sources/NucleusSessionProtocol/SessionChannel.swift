import NucleusIPCTransport

public enum SessionChannel {
    public static func socketPair() throws -> (Int32, Int32) {
        let (first, second) = try PacketConnection.socketPair()
        return (
            first.takeFileDescriptor(),
            second.takeFileDescriptor())
    }

    public static func send(
        _ bytes: some Collection<UInt8>,
        to descriptor: Int32
    ) throws {
        try PacketConnection(borrowing: descriptor).send(bytes)
    }

    public static func receive(
        from descriptor: Int32,
        maximumBytes: Int
    ) throws -> [UInt8] {
        try PacketConnection(borrowing: descriptor)
            .receive(maximumBytes: maximumBytes, maximumDescriptors: 0)
            .bytes
    }
}
