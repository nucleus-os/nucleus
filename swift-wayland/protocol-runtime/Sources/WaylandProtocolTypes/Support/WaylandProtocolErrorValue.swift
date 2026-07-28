/// A generated Wayland protocol error value.
///
/// The marker keeps cross-interface factory errors typed. Some XML protocols
/// declare a request on a manager while defining the applicable error enum on
/// the child interface that request creates.
public protocol WaylandProtocolErrorValue:
    RawRepresentable,
    Sendable
where RawValue == UInt32 {}
