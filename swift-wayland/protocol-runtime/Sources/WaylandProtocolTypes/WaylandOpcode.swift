/// A request opcode whose numeric value is fixed by one Wayland interface XML.
public protocol WaylandRequestOpcode: RawRepresentable, Sendable
where RawValue == UInt16 {}

/// An event opcode whose numeric value is fixed by one Wayland interface XML.
public protocol WaylandEventOpcode: RawRepresentable, Sendable
where RawValue == UInt16 {}
