public struct DBusCString: Sendable, Equatable {
    private let value: StaticString

    public init(_ value: StaticString) {
        self.value = value
    }

    public var stringValue: String {
        String(decoding: UnsafeBufferPointer(start: value.utf8Start, count: value.utf8CodeUnitCount), as: UTF8.self)
    }

    public static func == (lhs: DBusCString, rhs: DBusCString) -> Bool {
        lhs.stringValue == rhs.stringValue
    }
}

public struct DBusMethodDescription: Sendable, Equatable {
    public var member: DBusCString
    public var signature: DBusCString
    public var result: DBusCString

    public init(member: StaticString, signature: StaticString, result: StaticString) {
        self.member = DBusCString(member)
        self.signature = DBusCString(signature)
        self.result = DBusCString(result)
    }
}

public struct DBusSignalDescription: Sendable, Equatable {
    public var member: DBusCString
    public var signature: DBusCString

    public init(member: StaticString, signature: StaticString) {
        self.member = DBusCString(member)
        self.signature = DBusCString(signature)
    }
}

public struct DBusInterfaceDescription: Sendable, Equatable {
    public var path: DBusCString
    public var interface: DBusCString
    public var wellKnownName: DBusCString?
    public var methods: [DBusMethodDescription]
    public var signals: [DBusSignalDescription]

    public init(
        path: StaticString,
        interface: StaticString,
        wellKnownName: StaticString? = nil,
        methods: [DBusMethodDescription],
        signals: [DBusSignalDescription] = []
    ) {
        self.path = DBusCString(path)
        self.interface = DBusCString(interface)
        self.wellKnownName = wellKnownName.map(DBusCString.init)
        self.methods = methods
        self.signals = signals
    }
}

public protocol DBusService {
    static var dbusInterface: DBusInterfaceDescription { get }
}

extension NotificationService: DBusService {
    nonisolated public static let dbusInterface = DBusInterfaceDescription(
        path: "/org/freedesktop/Notifications",
        interface: "org.freedesktop.Notifications",
        wellKnownName: "org.freedesktop.Notifications",
        methods: [
            .init(member: "Notify", signature: "susssasa{sv}i", result: "u"),
            .init(member: "CloseNotification", signature: "u", result: ""),
            .init(member: "GetCapabilities", signature: "", result: "as"),
            .init(member: "GetServerInformation", signature: "", result: "ssss"),
        ],
        signals: [
            .init(member: "NotificationClosed", signature: "uu"),
            .init(member: "ActionInvoked", signature: "us"),
        ]
    )
}

extension AppearancePortal: DBusService {
    nonisolated public static let dbusInterface = DBusInterfaceDescription(
        path: "/org/freedesktop/portal/desktop",
        interface: "org.freedesktop.portal.Settings",
        wellKnownName: "org.freedesktop.portal.Desktop",
        methods: [
            .init(member: "ReadAll", signature: "as", result: "a{sa{sv}}"),
        ],
        signals: [
            .init(member: "SettingChanged", signature: "ssv"),
        ]
    )
}

// The fixed D-Bus service catalog. `NucleusCompositorShell/SystemdBus.swift` reads these
// descriptors directly to build the notification object vtable and to address the
// appearance portal — there is no cross-ABI catalog host; Swift owns the bus.
public let compositorShellDBusInterfaces: [DBusInterfaceDescription] = [
    NotificationService.dbusInterface,
    AppearancePortal.dbusInterface,
]
