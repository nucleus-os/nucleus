// Parity fixture for the XSETTINGS serializer + RESOURCE_MANAGER string
// (XwaylandXSettings.swift). Round-trips the binary payload through a decoder and
// checks the decoded settings + header, plus the Xrdb string — the byte layout
// toolkits depend on. Pure data; no live X server.

import Glibc

@main
enum XwaylandXSettingsFixture {
    struct Setting { let name: String; let value: Int32 }

    static func fail(_ msg: String) -> Never {
        print("FAIL xwayland-xsettings: \(msg)")
        exit(1)
    }

    // Decode an XSETTINGS payload back to (serial, settings) by walking the same
    // layout the serializer writes. Test-only — the compositor only ever writes.
    static func decode(_ b: [UInt8]) -> (serial: UInt32, settings: [Setting])? {
        guard b.count >= 12, b[0] == 0 else { return nil } // LSBFirst
        func le16(_ o: Int) -> UInt16 { UInt16(b[o]) | (UInt16(b[o + 1]) << 8) }
        func le32(_ o: Int) -> UInt32 {
            UInt32(b[o]) | (UInt32(b[o + 1]) << 8) | (UInt32(b[o + 2]) << 16) | (UInt32(b[o + 3]) << 24)
        }
        let serial = le32(4)
        let count = le32(8)
        var o = 12
        var out: [Setting] = []
        for _ in 0..<count {
            guard o + 4 <= b.count else { return nil }
            let nameLen = Int(le16(o + 2)) // [0]=type [1]=unused [2..3]=name_len
            o += 4
            guard o + nameLen <= b.count else { return nil }
            let name = String(decoding: b[o..<(o + nameLen)], as: UTF8.self)
            o += nameLen
            o += (4 - (nameLen % 4)) % 4 // skip name padding to 4-byte boundary
            guard o + 8 <= b.count else { return nil }
            let value = Int32(bitPattern: le32(o + 4)) // [o..3]=serial [o+4..7]=value
            o += 8
            out.append(Setting(name: name, value: value))
        }
        return (serial, out)
    }

    static func checkSettings(scale: Double, serial: UInt32, expected: [(String, Int32)]) {
        let blob = serializeXSettings(scale: scale, serial: serial)
        guard let (decodedSerial, settings) = decode(blob) else {
            fail("decode failed scale=\(scale)")
        }
        if decodedSerial != serial { fail("serial \(decodedSerial) != \(serial)") }
        if settings.count != expected.count { fail("count \(settings.count) != \(expected.count)") }
        for (i, exp) in expected.enumerated() {
            if settings[i].name != exp.0 || settings[i].value != exp.1 {
                fail("setting[\(i)] = (\(settings[i].name), \(settings[i].value)) != \(exp)")
            }
        }
    }

    static func main() {
        // scale 1.0: Xft/DPI = 96*1024, scaling = 1, unscaled = 96*1024.
        checkSettings(scale: 1.0, serial: 1, expected: [
            ("Xft/DPI", 98304),
            ("Gdk/WindowScalingFactor", 1),
            ("Gdk/UnscaledDPI", 98304),
        ])
        // scale 1.5: Xft/DPI = 1.5*96*1024, scaling = round(1.5)=2, unscaled = 96*1024/1.5.
        checkSettings(scale: 1.5, serial: 2, expected: [
            ("Xft/DPI", 147456),
            ("Gdk/WindowScalingFactor", 2),
            ("Gdk/UnscaledDPI", 65536),
        ])
        // Non-positive scale clamps to 1.0.
        checkSettings(scale: 0.0, serial: 3, expected: [
            ("Xft/DPI", 98304),
            ("Gdk/WindowScalingFactor", 1),
            ("Gdk/UnscaledDPI", 98304),
        ])

        // The header is little-endian: byte order 0, serial, n_settings=3.
        let blob = serializeXSettings(scale: 1.0, serial: 7)
        if blob[0] != 0 || blob[4] != 7 || blob[8] != 3 {
            fail("header bytes \(blob[0]),\(blob[4]),\(blob[8])")
        }

        // RESOURCE_MANAGER string: Xft.dpi + Xcursor.size scale with the factor.
        let rm1 = resourceManagerString(scale: 1.0)
        let rm2 = resourceManagerString(scale: 2.0)
        if !rm1.hasPrefix("Xft.dpi:\t96\n") || !rm1.contains("Xcursor.size:\t24\n") {
            fail("resource-manager scale 1.0: \(rm1.debugDescription)")
        }
        if !rm2.hasPrefix("Xft.dpi:\t192\n") || !rm2.contains("Xcursor.size:\t48\n") {
            fail("resource-manager scale 2.0: \(rm2.debugDescription)")
        }

        print("OK xwayland-xsettings settings=3 roundtrip=ok")
    }
}
