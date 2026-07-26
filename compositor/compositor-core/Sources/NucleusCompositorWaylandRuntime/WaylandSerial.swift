/// A serial in one semantic Wayland domain.
///
/// Wayland serials wrap modulo 2^32. The phantom domain prevents configure
/// serials, seat input serials, and unrelated protocol counters from being mixed
/// while preserving the exact wire representation at request/event boundaries.
struct WaylandSerial<Domain>: RawRepresentable, Hashable, Sendable {
    let rawValue: UInt32

    init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// RFC-1982-style ordering for distances smaller than half the serial space.
    func isNewer(than other: Self) -> Bool {
        Int32(bitPattern: rawValue &- other.rawValue) > 0
    }
}

enum XdgConfigureSerialDomain: Sendable {}
enum SeatInputSerialDomain: Sendable {}

typealias XdgConfigureSerial = WaylandSerial<XdgConfigureSerialDomain>
typealias SeatInputSerial = WaylandSerial<SeatInputSerialDomain>
