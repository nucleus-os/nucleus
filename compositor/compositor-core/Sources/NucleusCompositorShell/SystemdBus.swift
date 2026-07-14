//! Swift-owned sd-bus substrate for the compositor's D-Bus shell services
//! (platform-host Stage 7). Swift owns the three session-bus connections, the
//! notification object vtable, and every message read/append; the reactor only borrows the bus fds and
//! drives the pumps. The libc-shaped variadic/vtable plumbing the Swift clang
//! importer cannot express against <systemd/sd-bus.h> is provided by the
//! `NucleusCompositorSystemdC` first-party façade.
//!
//! Two buses:
//!   - notification: connects to org.freedesktop.Notifications and registers the
//!     object vtable, but never claims the name (Noctalia owns it), so Notify
//!     reaches the daemon; the connection only keeps the fd live and emits
//!     NotificationClosed.
//!   - appearance: subscribes to org.freedesktop.portal.Settings SettingChanged
//!     and folds color-scheme / contrast into AppearancePortal.

import Foundation
import NucleusCompositorSystemdC

private func systemdLog(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

// ── D-Bus type-code constants (sd-bus container/basic type chars) ────────────
private let TYPE_ARRAY = CChar(bitPattern: UInt8(ascii: "a"))
private let TYPE_VARIANT = CChar(bitPattern: UInt8(ascii: "v"))

private let appearanceNamespace = "org.freedesktop.appearance"

// ── Process-lifetime C strings for the registered vtable ─────────────────────
// sd-bus stores the vtable's path/interface/member/signature/result pointers and
// references them for the connection's lifetime, so they must outlive the build
// call. The D-Bus service catalog is a fixed compile-time set, so this interning
// is bounded and never freed.
@MainActor private var persistentCStrings: [UnsafeMutablePointer<CChar>] = []

@MainActor private func persistentCString(_ s: String) -> UnsafePointer<CChar> {
    let bytes = Array(s.utf8)
    let buf = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count + 1)
    for (i, b) in bytes.enumerated() { buf[i] = CChar(bitPattern: b) }
    buf[bytes.count] = 0
    persistentCStrings.append(buf)
    return UnsafePointer(buf)
}

private func cString(_ ptr: UnsafePointer<CChar>?) -> String? {
    guard let ptr else { return nil }
    return String(cString: ptr)
}

// MARK: - sd-bus method handlers (org.freedesktop.Notifications object vtable)

private func nucleusNotifyHandler(
    _ m: OpaquePointer?, _ userdata: UnsafeMutableRawPointer?,
    _ err: UnsafeMutablePointer<sd_bus_error>?
) -> Int32 {
    guard let m else { return -1 }
    var appName: UnsafePointer<CChar>? = nil
    var appIcon: UnsafePointer<CChar>? = nil
    var summary: UnsafePointer<CChar>? = nil
    var body: UnsafePointer<CChar>? = nil
    var replacesID: UInt32 = 0
    var expireTimeout: Int32 = -1

    var r = nucleus_sdbus_read_sus(m, &appName, &replacesID, &appIcon)
    if r < 0 { return r }
    r = nucleus_sdbus_read_ss(m, &summary, &body)
    if r < 0 { return r }
    r = sd_bus_message_skip(m, "as")
    if r < 0 { return r }
    r = sd_bus_message_skip(m, "a{sv}")
    if r < 0 { return r }
    r = nucleus_sdbus_read_i(m, &expireTimeout)
    if r < 0 { return r }

    // Copy the borrowed message strings into Sendable `String`s before crossing
    // into the actor closure — the raw pointers are not Sendable.
    let appNameStr = cString(appName)
    let summaryStr = cString(summary)
    let bodyStr = cString(body)
    let id = MainActor.assumeIsolated {
        NotificationService.shared.notify(
            appName: appNameStr,
            replacesID: replacesID,
            summary: summaryStr,
            body: bodyStr,
            expireTimeout: expireTimeout
        )
    }
    return nucleus_sdbus_reply_u(m, id)
}

private func nucleusCloseNotificationHandler(
    _ m: OpaquePointer?, _ userdata: UnsafeMutableRawPointer?,
    _ err: UnsafeMutablePointer<sd_bus_error>?
) -> Int32 {
    guard let m else { return -1 }
    var id: UInt32 = 0
    let r = nucleus_sdbus_read_u(m, &id)
    if r < 0 { return r }
    MainActor.assumeIsolated { NotificationService.shared.dismiss(id: id, reason: 2) }
    return nucleus_sdbus_reply_empty(m)
}

private func nucleusGetCapabilitiesHandler(
    _ m: OpaquePointer?, _ userdata: UnsafeMutableRawPointer?,
    _ err: UnsafeMutablePointer<sd_bus_error>?
) -> Int32 {
    guard let m else { return -1 }
    var reply: OpaquePointer? = nil
    var r = sd_bus_message_new_method_return(m, &reply)
    if r < 0 { return r }
    guard let rep = reply else { return -1 }
    r = sd_bus_message_open_container(rep, TYPE_ARRAY, "s")
    if r < 0 { return r }
    _ = nucleus_sdbus_append_s(rep, "body")
    _ = nucleus_sdbus_append_s(rep, "persistence")
    r = sd_bus_message_close_container(rep)
    if r < 0 { return r }
    return sd_bus_send(nil, rep, nil)
}

private func nucleusGetServerInformationHandler(
    _ m: OpaquePointer?, _ userdata: UnsafeMutableRawPointer?,
    _ err: UnsafeMutablePointer<sd_bus_error>?
) -> Int32 {
    guard let m else { return -1 }
    return nucleus_sdbus_reply_ssss(m, "Nucleus", "nucleus", "0.1.0", "1.2")
}

private func nucleusNoopHandler(
    _ m: OpaquePointer?, _ userdata: UnsafeMutableRawPointer?,
    _ err: UnsafeMutablePointer<sd_bus_error>?
) -> Int32 {
    0
}

private func notificationHandler(forMember member: String) -> sd_bus_message_handler_t {
    switch member {
    case "Notify": return nucleusNotifyHandler
    case "CloseNotification": return nucleusCloseNotificationHandler
    case "GetCapabilities": return nucleusGetCapabilitiesHandler
    case "GetServerInformation": return nucleusGetServerInformationHandler
    default: return nucleusNoopHandler
    }
}

// MARK: - sd-bus signal handlers

private func nucleusAppearanceSettingChanged(
    _ m: OpaquePointer?, _ userdata: UnsafeMutableRawPointer?,
    _ err: UnsafeMutablePointer<sd_bus_error>?
) -> Int32 {
    guard let m else { return 0 }
    var namespace: UnsafePointer<CChar>? = nil
    var key: UnsafePointer<CChar>? = nil
    if nucleus_sdbus_read_ss(m, &namespace, &key) < 0 { return 0 }
    if (cString(namespace) ?? "") != appearanceNamespace {
        _ = sd_bus_message_skip(m, "v")
        return 0
    }
    applyAppearanceVariant(m, key: cString(key) ?? "")
    return 0
}

/// Read the `v` value of one appearance setting and fold it into AppearancePortal.
/// Only color-scheme / contrast `u` variants are consumed; anything else is skipped.
private func applyAppearanceVariant(_ m: OpaquePointer, key: String) {
    var typ: CChar = 0
    var contents: UnsafePointer<CChar>? = nil
    if sd_bus_message_peek_type(m, &typ, &contents) < 0 { return }
    let cs = cString(contents) ?? ""
    if typ != TYPE_VARIANT {
        _ = sd_bus_message_skip(m, "v")
        return
    }
    if key == "color-scheme" && cs == "u" {
        var value: UInt32 = 0
        if nucleus_sdbus_read_variant_u(m, &value) < 0 { return }
        MainActor.assumeIsolated { AppearancePortal.shared.setColorScheme(value) }
    } else if key == "contrast" && cs == "u" {
        var value: UInt32 = 0
        if nucleus_sdbus_read_variant_u(m, &value) < 0 { return }
        MainActor.assumeIsolated { AppearancePortal.shared.setContrast(value) }
    } else {
        _ = sd_bus_message_skip(m, "v")
    }
}

// MARK: - The bus owner

@MainActor
final class SystemdBus {
    static let shared = SystemdBus()

    private var notificationBus: OpaquePointer?
    private var notificationSlot: OpaquePointer?
    private var vtableStorage: UnsafeMutableRawPointer?

    private var appearanceBus: OpaquePointer?
    private var appearanceSlot: OpaquePointer?

    private init() {}

    func start() {
        startNotifications()
        startAppearance()
    }

    func deinitialize() {
        if let slot = appearanceSlot { _ = sd_bus_slot_unref(slot); appearanceSlot = nil }
        if appearanceBus != nil { appearanceBus = sd_bus_unref(appearanceBus) }
        if let slot = notificationSlot { _ = sd_bus_slot_unref(slot); notificationSlot = nil }
        if notificationBus != nil { notificationBus = sd_bus_unref(notificationBus) }
        if let storage = vtableStorage { storage.deallocate(); vtableStorage = nil }
    }

    // ── Notifications ────────────────────────────────────────────────────────

    private func startNotifications() {
        let descriptor = NotificationService.dbusInterface
        var bus: OpaquePointer? = nil
        if sd_bus_open_user(&bus) < 0 || bus == nil {
            systemdLog("notification server: failed to open session bus")
            return
        }
        let vtable = buildNotificationVtable(descriptor)
        var slot: OpaquePointer? = nil
        let path = persistentCString(descriptor.path.stringValue)
        let interface = persistentCString(descriptor.interface.stringValue)
        let r = sd_bus_add_object_vtable(bus, &slot, path, interface, UnsafePointer(vtable), nil)
        if r < 0 {
            systemdLog("notification server: failed to register vtable: \(r)")
            // buildNotificationVtable allocated vtableStorage; free it on the failure
            // path so a rejected registration (or a later retry overwriting the
            // pointer) does not leak the buffer.
            vtableStorage?.deallocate()
            vtableStorage = nil
            _ = sd_bus_unref(bus)
            return
        }
        // Noctalia owns org.freedesktop.Notifications; the compositor connects but
        // never claims the name, so Notify reaches the daemon and the connection
        // only keeps the fd wired and emits NotificationClosed.
        notificationBus = bus
        notificationSlot = slot
        systemdLog("notification service: D-Bus connected without owning the name")
    }

    private func buildNotificationVtable(
        _ descriptor: DBusInterfaceDescription
    ) -> UnsafeMutablePointer<sd_bus_vtable> {
        let methods = descriptor.methods
        let signals = descriptor.signals
        let bytes = nucleus_sdbus_vtable_bytes(UInt32(methods.count), UInt32(signals.count))
        let raw = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 16)
        vtableStorage = raw
        let table = raw.assumingMemoryBound(to: sd_bus_vtable.self)
        nucleus_sdbus_vtable_start(table, 0)
        var index = 1
        for method in methods {
            nucleus_sdbus_vtable_method(
                table, index,
                persistentCString(method.member.stringValue),
                persistentCString(method.signature.stringValue),
                persistentCString(method.result.stringValue),
                notificationHandler(forMember: method.member.stringValue)
            )
            index += 1
        }
        for signal in signals {
            nucleus_sdbus_vtable_signal(
                table, index,
                persistentCString(signal.member.stringValue),
                persistentCString(signal.signature.stringValue)
            )
            index += 1
        }
        nucleus_sdbus_vtable_end(table, index)
        return table
    }

    func notificationClosed(id: UInt32, reason: UInt32) {
        guard let bus = notificationBus else { return }
        let descriptor = NotificationService.dbusInterface
        _ = descriptor.path.stringValue.withCString { path in
            descriptor.interface.stringValue.withCString { interface in
                "NotificationClosed".withCString { member in
                    nucleus_sdbus_emit_uu(bus, path, interface, member, id, reason)
                }
            }
        }
    }

    var notificationFd: Int32 { notificationBus.map { sd_bus_get_fd($0) } ?? -1 }
    func pumpNotifications() { pump(notificationBus) }

    // ── Appearance portal ────────────────────────────────────────────────────

    private func startAppearance() {
        let descriptor = AppearancePortal.dbusInterface
        guard let destination = descriptor.wellKnownName?.stringValue else { return }
        var bus: OpaquePointer? = nil
        if sd_bus_open_user(&bus) < 0 || bus == nil {
            systemdLog("appearance portal: failed to open session bus")
            return
        }
        appearanceBus = bus
        var slot: OpaquePointer? = nil
        let rc = destination.withCString { d in
            descriptor.path.stringValue.withCString { p in
                descriptor.interface.stringValue.withCString { i in
                    sd_bus_match_signal(
                        bus, &slot, d, p, i, "SettingChanged",
                        nucleusAppearanceSettingChanged, nil)
                }
            }
        }
        if rc < 0 {
            systemdLog("appearance portal: SettingChanged match failed: \(rc)")
            appearanceBus = sd_bus_unref(bus)
            return
        }
        appearanceSlot = slot
    }

    var appearanceFd: Int32 { appearanceBus.map { sd_bus_get_fd($0) } ?? -1 }
    func pumpAppearance() { pump(appearanceBus) }

    private func pump(_ bus: OpaquePointer?) {
        guard let bus else { return }
        while sd_bus_process(bus, nil) > 0 {}
    }
}

// MARK: - Shell D-Bus surface (driven directly by the compositor bring-up + loop)

@MainActor public func nucleus_shell_dbus_start() {
    SystemdBus.shared.start()
}

@MainActor public func nucleus_shell_dbus_notification_fd() -> Int32 {
    SystemdBus.shared.notificationFd
}

@MainActor public func nucleus_shell_dbus_appearance_fd() -> Int32 {
    SystemdBus.shared.appearanceFd
}

@MainActor public func nucleus_shell_dbus_pump_notifications() {
    SystemdBus.shared.pumpNotifications()
}

@MainActor public func nucleus_shell_dbus_pump_appearance() {
    SystemdBus.shared.pumpAppearance()
}


