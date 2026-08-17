import ColliderPlatformC

public struct TerminalGeometry: Equatable, Sendable {
    public let columns: Int
    public let rows: Int

    public init(columns: Int, rows: Int) {
        precondition(columns > 0)
        precondition(rows > 0)
        self.columns = columns
        self.rows = rows
    }
}

public func terminalGeometry(descriptor: Int32) -> TerminalGeometry? {
    var columns: UInt16 = 0
    var rows: UInt16 = 0
    guard unsafe collider_terminal_size(descriptor, &columns, &rows) == 0 else {
        return nil
    }
    return TerminalGeometry(columns: Int(columns), rows: Int(rows))
}

public func terminalDisplayWidth(of scalar: Unicode.Scalar) -> Int {
    Int(collider_terminal_scalar_width(scalar.value))
}
