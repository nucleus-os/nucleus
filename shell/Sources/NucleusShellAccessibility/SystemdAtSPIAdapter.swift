import Foundation
import NucleusShellDBusC
import NucleusUI
#if canImport(Glibc)
import Glibc
#endif

public struct AtSPIServiceError: Error, Sendable, Equatable {
    public var operation: String
    public var code: Int32

    public init(operation: String, code: Int32) {
        self.operation = operation
        self.code = code
    }
}

private let dbusTypeArray = CChar(UInt8(ascii: "a"))
private let dbusTypeBoolean = CChar(UInt8(ascii: "b"))
private let dbusTypeDictEntry = CChar(UInt8(ascii: "e"))
private let dbusTypeDouble = CChar(UInt8(ascii: "d"))
private let dbusTypeInt16 = CChar(UInt8(ascii: "n"))
private let dbusTypeInt32 = CChar(UInt8(ascii: "i"))
private let dbusTypeObjectPath = CChar(UInt8(ascii: "o"))
private let dbusTypeString = CChar(UInt8(ascii: "s"))
private let dbusTypeStruct = CChar(UInt8(ascii: "r"))
private let dbusTypeUInt32 = CChar(UInt8(ascii: "u"))
private let dbusTypeVariant = CChar(UInt8(ascii: "v"))

private func atspiFallbackHandler(
    _ message: OpaquePointer?,
    _ userData: UnsafeMutableRawPointer?,
    _ error: UnsafeMutablePointer<sd_bus_error>?
) -> Int32 {
    guard let message, let userData else { return -EINVAL }
    let adapter = Unmanaged<SystemdAtSPIAdapter>
        .fromOpaque(userData)
        .takeUnretainedValue()
    let messageAddress = UInt(bitPattern: message)
    return MainActor.assumeIsolated {
        guard let isolatedMessage = OpaquePointer(
            bitPattern: messageAddress)
        else { return -EINVAL }
        return adapter.handle(isolatedMessage)
    }
}

/// Nonblocking AT-SPI2 provider driven by the shell's existing poll loop.
///
/// The adapter connects to the dedicated accessibility bus, registers one
/// fallback object subtree, and answers requests from its latest immutable
/// export snapshot. `process()` never waits for I/O; actions are the only calls
/// that cross back into NucleusUI, and they run on the UI actor.
@MainActor
public final class SystemdAtSPIAdapter: AccessibilityPlatformAdapter {
    public var onAction:
        (@MainActor (AccessibilityActionRequest) -> Bool)?

    private var bus: OpaquePointer?
    private var fallbackSlot: OpaquePointer?
    private var model: AtSPIExportModel
    private var uniqueName = ""
    private var registryName = ""
    private var registryPath = AtSPIExportModel.nullPath
    private var applicationID: Int32 = 0
    private let busAddress: String
    private let locale: String

    public init(applicationName: String) throws(AtSPIServiceError) {
        model = AtSPIExportModel(applicationName: applicationName)
        _ = model.apply(
            snapshot: AccessibilityTreeSnapshot(),
            update: AccessibilityTreeUpdate(
                revision: 0,
                rootIDs: [],
                inserted: [],
                updated: [],
                removed: [],
                notifications: []))
        busAddress = try Self.accessibilityBusAddress()
        locale = Locale.current.identifier

        var handle: OpaquePointer?
        var result = sd_bus_new(&handle)
        guard result >= 0, let handle else {
            throw AtSPIServiceError(operation: "creating accessibility bus", code: result)
        }
        bus = handle
        result = busAddress.withCString {
            sd_bus_set_address(handle, $0)
        }
        guard result >= 0 else {
            close()
            throw AtSPIServiceError(operation: "setting accessibility bus address", code: result)
        }
        result = sd_bus_set_bus_client(handle, 1)
        guard result >= 0 else {
            close()
            throw AtSPIServiceError(operation: "configuring accessibility bus client", code: result)
        }
        result = sd_bus_start(handle)
        guard result >= 0 else {
            close()
            throw AtSPIServiceError(operation: "starting accessibility bus", code: result)
        }
        var rawName: UnsafePointer<CChar>?
        result = sd_bus_get_unique_name(handle, &rawName)
        guard result >= 0, let rawName else {
            close()
            throw AtSPIServiceError(
                operation: "reading accessibility bus name",
                code: result)
        }
        uniqueName = String(cString: rawName)

        var slot: OpaquePointer?
        result = sd_bus_add_fallback(
            handle,
            &slot,
            "/org/a11y/atspi",
            atspiFallbackHandler,
            Unmanaged.passUnretained(self).toOpaque())
        guard result >= 0 else {
            close()
            throw AtSPIServiceError(operation: "registering AT-SPI objects", code: result)
        }
        fallbackSlot = slot
        do {
            try embedApplication()
        } catch {
            close()
            throw error
        }
    }

    isolated deinit {
        if let fallbackSlot {
            sd_bus_slot_unref(fallbackSlot)
        }
        if let bus {
            sd_bus_flush(bus)
            sd_bus_unref(bus)
        }
    }

    public func close() {
        if let fallbackSlot {
            sd_bus_slot_unref(fallbackSlot)
            self.fallbackSlot = nil
        }
        if let bus {
            sd_bus_flush(bus)
            sd_bus_unref(bus)
            self.bus = nil
        }
    }

    public var fileDescriptor: Int32 {
        guard let bus else { return -1 }
        return sd_bus_get_fd(bus)
    }

    public var pollEvents: Int16 {
        guard let bus else { return 0 }
        let events = sd_bus_get_events(bus)
        return events < 0 ? 0 : Int16(truncatingIfNeeded: events)
    }

    public func timeoutMicroseconds() -> UInt64? {
        guard let bus else { return nil }
        var deadline: UInt64 = 0
        guard sd_bus_get_timeout(bus, &deadline) >= 0,
              deadline != UInt64.max
        else { return nil }
        var now = timespec()
        clock_gettime(CLOCK_MONOTONIC, &now)
        let current = UInt64(now.tv_sec) &* 1_000_000
            &+ UInt64(now.tv_nsec) / 1_000
        return deadline > current ? deadline - current : 0
    }

    @discardableResult
    public func process() throws(AtSPIServiceError) -> Bool {
        guard let bus else { return false }
        var handled = false
        while true {
            let result = sd_bus_process(bus, nil)
            if result < 0 {
                throw AtSPIServiceError(
                    operation: "processing accessibility bus",
                    code: result)
            }
            if result == 0 { break }
            handled = true
        }
        sd_bus_flush(bus)
        return handled
    }

    public func apply(
        snapshot: AccessibilityTreeSnapshot,
        update: AccessibilityTreeUpdate
    ) {
        let exported = model.apply(snapshot: snapshot, update: update)
        for event in exported.events {
            emit(event)
        }
    }

    // MARK: - Connection and registration

    private static func accessibilityBusAddress()
        throws(AtSPIServiceError) -> String
    {
        if let address = ProcessInfo.processInfo.environment[
            "AT_SPI_BUS_ADDRESS"],
           !address.isEmpty
        {
            return address
        }

        var session: OpaquePointer?
        let opened = sd_bus_open_user(&session)
        guard opened >= 0, let session else {
            throw AtSPIServiceError(
                operation: "opening session bus for AT-SPI discovery",
                code: opened)
        }
        defer { sd_bus_unref(session) }
        var call: OpaquePointer?
        let created = sd_bus_message_new_method_call(
            session,
            &call,
            "org.a11y.Bus",
            "/org/a11y/bus",
            "org.a11y.Bus",
            "GetAddress")
        guard created >= 0, let call else {
            throw AtSPIServiceError(
                operation: "building AT-SPI address request",
                code: created)
        }
        defer { sd_bus_message_unref(call) }
        var reply: OpaquePointer?
        var error = sd_bus_error()
        nucleus_dbus_error_init(&error)
        defer { sd_bus_error_free(&error) }
        let called = sd_bus_call(session, call, 0, &error, &reply)
        guard called >= 0, let reply else {
            throw AtSPIServiceError(
                operation: "querying AT-SPI bus address",
                code: called)
        }
        defer { sd_bus_message_unref(reply) }
        var raw: UnsafePointer<CChar>?
        let read = sd_bus_message_read_basic(
            reply,
            dbusTypeString,
            &raw)
        guard read >= 0, let raw else {
            throw AtSPIServiceError(
                operation: "decoding AT-SPI bus address",
                code: read)
        }
        return String(cString: raw)
    }

    private func embedApplication() throws(AtSPIServiceError) {
        guard let bus else {
            throw AtSPIServiceError(
                operation: "embedding closed AT-SPI provider",
                code: -ENOTCONN)
        }
        var call: OpaquePointer?
        let created = sd_bus_message_new_method_call(
            bus,
            &call,
            "org.a11y.atspi.Registry",
            "/org/a11y/atspi/registry",
            "org.a11y.atspi.Socket",
            "Embed")
        guard created >= 0, let call else {
            throw AtSPIServiceError(
                operation: "building AT-SPI registry request",
                code: created)
        }
        defer { sd_bus_message_unref(call) }
        var writer = MessageWriter(call)
        guard writer.objectReference(
            busName: uniqueName,
            path: AtSPIExportModel.rootPath) >= 0
        else {
            throw AtSPIServiceError(
                operation: "encoding AT-SPI registry request",
                code: writer.result)
        }

        var reply: OpaquePointer?
        var error = sd_bus_error()
        nucleus_dbus_error_init(&error)
        defer { sd_bus_error_free(&error) }
        let called = sd_bus_call(bus, call, 0, &error, &reply)
        guard called >= 0, let reply else {
            throw AtSPIServiceError(
                operation: "registering with AT-SPI registry",
                code: called)
        }
        defer { sd_bus_message_unref(reply) }
        guard let reference = readObjectReference(reply) else {
            throw AtSPIServiceError(
                operation: "decoding AT-SPI registry reference",
                code: -EBADMSG)
        }
        registryName = reference.0
        registryPath = reference.1
    }

    // MARK: - Message dispatch

    fileprivate func handle(_ message: OpaquePointer) -> Int32 {
        let path = string(sd_bus_message_get_path(message))
        let interface = string(sd_bus_message_get_interface(message))
        let member = string(sd_bus_message_get_member(message))
        guard let object = model.objects[path] else {
            return replyError(
                message,
                name: "org.freedesktop.DBus.Error.UnknownObject",
                text: "No accessible object exists at \(path)")
        }

        switch interface {
        case "org.freedesktop.DBus.Properties":
            return handleProperties(message, object: object, member: member)
        case "org.freedesktop.DBus.Introspectable":
            guard member == "Introspect" else {
                return unknownMethod(message, interface: interface, member: member)
            }
            return reply(message) {
                $0.string(introspectionXML(for: object))
            }
        case AtSPIInterface.accessible:
            return handleAccessible(message, object: object, member: member)
        case AtSPIInterface.action:
            return handleAction(message, object: object, member: member)
        case AtSPIInterface.application:
            return handleApplication(message, object: object, member: member)
        case AtSPIInterface.component:
            return handleComponent(message, object: object, member: member)
        case AtSPIInterface.editableText:
            return handleEditableText(message, object: object, member: member)
        case AtSPIInterface.selection:
            return handleSelection(message, object: object, member: member)
        case AtSPIInterface.text:
            return handleText(message, object: object, member: member)
        case AtSPIInterface.value:
            return handleValue(message, object: object, member: member)
        default:
            return replyError(
                message,
                name: "org.freedesktop.DBus.Error.UnknownInterface",
                text: "Unsupported interface \(interface)")
        }
    }

    private func handleProperties(
        _ message: OpaquePointer,
        object: AtSPIExportedObject,
        member: String
    ) -> Int32 {
        switch member {
        case "Get":
            guard let interface = readString(message),
                  let property = readString(message),
                  let value = propertyValue(
                    object: object,
                    interface: interface,
                    property: property)
            else {
                return replyError(
                    message,
                    name: "org.freedesktop.DBus.Error.InvalidArgs",
                    text: "Unknown AT-SPI property")
            }
            return reply(message) { value.appendVariant(to: &$0) }
        case "GetAll":
            guard let interface = readString(message) else {
                return invalidArguments(message)
            }
            let values = allProperties(
                object: object,
                interface: interface)
            return reply(message) { writer in
                writer.dictionary(values)
            }
        case "Set":
            guard let interface = readString(message),
                  let property = readString(message)
            else { return invalidArguments(message) }
            if interface == AtSPIInterface.application,
               property == "Id",
               let value = readVariantInt32(message)
            {
                applicationID = value
                return reply(message) { _ in 0 }
            }
            if interface == AtSPIInterface.value,
               property == "CurrentValue",
               let value = readVariantDouble(message),
               let id = object.id
            {
                let accepted = onAction?(.init(
                    target: id,
                    action: .setValue,
                    value: value)) ?? false
                return accepted
                    ? reply(message) { _ in 0 }
                    : actionFailed(message)
            }
            return replyError(
                message,
                name: "org.freedesktop.DBus.Error.PropertyReadOnly",
                text: "\(interface).\(property) is read-only")
        default:
            return unknownMethod(
                message,
                interface: "org.freedesktop.DBus.Properties",
                member: member)
        }
    }

    private func handleAccessible(
        _ message: OpaquePointer,
        object: AtSPIExportedObject,
        member: String
    ) -> Int32 {
        switch member {
        case "GetRole":
            return reply(message) { $0.uint32(object.role) }
        case "GetRoleName", "GetLocalizedRoleName":
            return reply(message) { $0.string(object.roleName) }
        case "GetState":
            return reply(message) { $0.uint32Array(object.states) }
        case "GetAttributes":
            return reply(message) { $0.stringDictionary([:]) }
        case "GetRelationSet":
            return reply(message) { writer in
                writer.relationSet(
                    object.relationships,
                    busName: uniqueName)
            }
        case "GetApplication":
            return reply(message) {
                $0.objectReference(
                    busName: uniqueName,
                    path: AtSPIExportModel.rootPath)
            }
        case "GetInterfaces":
            return reply(message) { $0.stringArray(object.interfaces) }
        case "GetChildAtIndex":
            guard let index = readInt32(message) else {
                return invalidArguments(message)
            }
            let path = object.childPaths.indices.contains(Int(index))
                ? object.childPaths[Int(index)]
                : AtSPIExportModel.nullPath
            return reply(message) {
                $0.objectReference(
                    busName: path == AtSPIExportModel.nullPath
                        ? "" : uniqueName,
                    path: path)
            }
        case "GetChildren":
            return reply(message) {
                $0.objectReferenceArray(
                    object.childPaths,
                    busName: uniqueName)
            }
        case "GetIndexInParent":
            let index: Int32
            if let parentPath = object.parentPath,
               let parent = model.objects[parentPath],
               let found = parent.childPaths.firstIndex(of: object.path)
            {
                index = Int32(clamping: found)
            } else {
                index = -1
            }
            return reply(message) { $0.int32(index) }
        default:
            return unknownMethod(
                message,
                interface: AtSPIInterface.accessible,
                member: member)
        }
    }

    private func handleAction(
        _ message: OpaquePointer,
        object: AtSPIExportedObject,
        member: String
    ) -> Int32 {
        let actions = object.parameterlessActions
        switch member {
        case "GetName", "GetLocalizedName":
            guard let action = indexedAction(message, actions: actions) else {
                return invalidArguments(message)
            }
            return reply(message) { $0.string(actionName(action)) }
        case "GetDescription":
            guard let action = indexedAction(message, actions: actions) else {
                return invalidArguments(message)
            }
            return reply(message) {
                $0.string(actionDescription(action))
            }
        case "GetKeyBinding":
            guard indexedAction(message, actions: actions) != nil else {
                return invalidArguments(message)
            }
            return reply(message) { $0.string("") }
        case "GetActions":
            return reply(message) { writer in
                writer.actionDescriptions(actions)
            }
        case "DoAction":
            guard let action = indexedAction(message, actions: actions),
                  let id = object.id
            else { return invalidArguments(message) }
            let accepted = onAction?(.init(
                target: id,
                action: action)) ?? false
            return reply(message) { $0.boolean(accepted) }
        default:
            return unknownMethod(
                message,
                interface: AtSPIInterface.action,
                member: member)
        }
    }

    private func handleApplication(
        _ message: OpaquePointer,
        object: AtSPIExportedObject,
        member: String
    ) -> Int32 {
        guard object.path == AtSPIExportModel.rootPath else {
            return unknownMethod(
                message,
                interface: AtSPIInterface.application,
                member: member)
        }
        switch member {
        case "GetLocale":
            _ = readUInt32(message)
            return reply(message) { $0.string(locale) }
        case "GetApplicationBusAddress":
            return reply(message) { $0.string(busAddress) }
        default:
            return unknownMethod(
                message,
                interface: AtSPIInterface.application,
                member: member)
        }
    }

    private func handleComponent(
        _ message: OpaquePointer,
        object: AtSPIExportedObject,
        member: String
    ) -> Int32 {
        switch member {
        case "Contains":
            guard let x = readInt32(message),
                  let y = readInt32(message),
                  readUInt32(message) != nil
            else { return invalidArguments(message) }
            return reply(message) {
                $0.boolean(object.frame.contains(Point(
                    x: Double(x),
                    y: Double(y))))
            }
        case "GetAccessibleAtPoint":
            guard let x = readInt32(message),
                  let y = readInt32(message),
                  readUInt32(message) != nil
            else { return invalidArguments(message) }
            let point = Point(x: Double(x), y: Double(y))
            let path = deepestObject(at: point, below: object)
                ?? AtSPIExportModel.nullPath
            return reply(message) {
                $0.objectReference(busName: uniqueName, path: path)
            }
        case "GetExtents":
            guard readUInt32(message) != nil else {
                return invalidArguments(message)
            }
            return reply(message) {
                $0.rect(object.frame)
            }
        case "GetPosition":
            guard readUInt32(message) != nil else {
                return invalidArguments(message)
            }
            return reply(message) {
                let first = $0.int32(Int32(clamping: Int(object.frame.origin.x)))
                guard first >= 0 else { return first }
                return $0.int32(Int32(clamping: Int(object.frame.origin.y)))
            }
        case "GetSize":
            return reply(message) {
                let first = $0.int32(Int32(clamping: Int(object.frame.size.width)))
                guard first >= 0 else { return first }
                return $0.int32(Int32(clamping: Int(object.frame.size.height)))
            }
        case "GetLayer":
            return reply(message) {
                $0.uint32(Self.isWindowRole(object.role) ? 7 : 3)
            }
        case "GetMDIZOrder":
            return reply(message) { $0.int16(0) }
        case "GrabFocus":
            guard let id = object.id else {
                return reply(message) { $0.boolean(false) }
            }
            let accepted = onAction?(.init(
                target: id,
                action: .focus)) ?? false
            return reply(message) { $0.boolean(accepted) }
        case "GetAlpha":
            return reply(message) { $0.double(1) }
        default:
            return unknownMethod(
                message,
                interface: AtSPIInterface.component,
                member: member)
        }
    }

    private func handleValue(
        _ message: OpaquePointer,
        object: AtSPIExportedObject,
        member: String
    ) -> Int32 {
        guard object.range != nil else {
            return unknownMethod(
                message,
                interface: AtSPIInterface.value,
                member: member)
        }
        switch member {
        case "SetCurrentValue":
            guard let value = readDouble(message),
                  let id = object.id
            else { return invalidArguments(message) }
            let accepted = onAction?(.init(
                target: id,
                action: .setValue,
                value: value)) ?? false
            return reply(message) { $0.boolean(accepted) }
        default:
            return unknownMethod(
                message,
                interface: AtSPIInterface.value,
                member: member)
        }
    }

    private func handleText(
        _ message: OpaquePointer,
        object: AtSPIExportedObject,
        member: String
    ) -> Int32 {
        guard !object.isSecure else {
            return replyError(
                message,
                name: "org.freedesktop.DBus.Error.AccessDenied",
                text: "Secure text is not exported")
        }
        switch member {
        case "GetText":
            guard let start = readInt32(message),
                  let end = readInt32(message)
            else { return invalidArguments(message) }
            return reply(message) {
                $0.string(textSlice(
                    object.text,
                    start: Int(start),
                    end: Int(end)))
            }
        case "SetCaretOffset":
            guard let offset = readInt32(message),
                  let id = object.id
            else { return invalidArguments(message) }
            let utf16 = utf16Offset(
                in: object.text,
                characterOffset: Int(offset))
            let accepted = onAction?(.init(
                target: id,
                action: .setSelection,
                selection: .init(utf16Range: utf16..<utf16))) ?? false
            return reply(message) { $0.boolean(accepted) }
        case "GetNSelections":
            let count: Int32 = object.textSelection.map {
                $0.utf16Range.isEmpty ? 0 : 1
            } ?? 0
            return reply(message) { $0.int32(count) }
        case "GetSelection":
            guard readInt32(message) == 0,
                  let selection = object.textSelection
            else { return invalidArguments(message) }
            let range = characterRange(
                in: object.text,
                utf16Range: selection.utf16Range)
            return reply(message) {
                let first = $0.int32(Int32(clamping: range.lowerBound))
                guard first >= 0 else { return first }
                return $0.int32(Int32(clamping: range.upperBound))
            }
        case "SetSelection":
            guard readInt32(message) == 0,
                  let start = readInt32(message),
                  let end = readInt32(message),
                  let id = object.id
            else { return invalidArguments(message) }
            let lower = utf16Offset(
                in: object.text,
                characterOffset: Int(start))
            let upper = utf16Offset(
                in: object.text,
                characterOffset: Int(end))
            let accepted = onAction?(.init(
                target: id,
                action: .setSelection,
                selection: .init(
                    utf16Range: min(lower, upper)..<max(lower, upper)))) ?? false
            return reply(message) { $0.boolean(accepted) }
        default:
            return unknownMethod(
                message,
                interface: AtSPIInterface.text,
                member: member)
        }
    }

    private func handleEditableText(
        _ message: OpaquePointer,
        object: AtSPIExportedObject,
        member: String
    ) -> Int32 {
        guard !object.isSecure, let id = object.id else {
            return replyError(
                message,
                name: "org.freedesktop.DBus.Error.AccessDenied",
                text: "Secure text is not editable through accessibility")
        }
        switch member {
        case "SetTextContents":
            guard let text = readString(message) else {
                return invalidArguments(message)
            }
            let accepted = onAction?(.init(
                target: id,
                action: .setText,
                text: text)) ?? false
            return reply(message) { $0.boolean(accepted) }
        case "CopyText", "CutText":
            guard let start = readInt32(message),
                  let end = readInt32(message)
            else { return invalidArguments(message) }
            let lower = utf16Offset(
                in: object.text,
                characterOffset: Int(start))
            let upper = utf16Offset(
                in: object.text,
                characterOffset: Int(end))
            let selected = onAction?(.init(
                target: id,
                action: .setSelection,
                selection: .init(
                    utf16Range: min(lower, upper)..<max(lower, upper)))) ?? false
            let action: AccessibilityAction =
                member == "CopyText" ? .copy : .cut
            let accepted = selected
                && (onAction?(.init(target: id, action: action)) ?? false)
            return reply(message) { $0.boolean(accepted) }
        case "PasteText":
            guard let position = readInt32(message) else {
                return invalidArguments(message)
            }
            let offset = utf16Offset(
                in: object.text,
                characterOffset: Int(position))
            let selected = onAction?(.init(
                target: id,
                action: .setSelection,
                selection: .init(utf16Range: offset..<offset))) ?? false
            let accepted = selected
                && (onAction?(.init(target: id, action: .paste)) ?? false)
            return reply(message) { $0.boolean(accepted) }
        default:
            return unknownMethod(
                message,
                interface: AtSPIInterface.editableText,
                member: member)
        }
    }

    private func handleSelection(
        _ message: OpaquePointer,
        object: AtSPIExportedObject,
        member: String
    ) -> Int32 {
        let selected = object.childPaths.filter {
            model.objects[$0].map(isSelected) == true
        }
        switch member {
        case "GetNSelectedChildren":
            return reply(message) {
                $0.int32(Int32(clamping: selected.count))
            }
        case "GetSelectedChild":
            guard let index = readInt32(message) else {
                return invalidArguments(message)
            }
            let path = selected.indices.contains(Int(index))
                ? selected[Int(index)]
                : AtSPIExportModel.nullPath
            return reply(message) {
                $0.objectReference(
                    busName: path == AtSPIExportModel.nullPath
                        ? "" : uniqueName,
                    path: path)
            }
        case "SelectChild":
            guard let index = readInt32(message),
                  object.childPaths.indices.contains(Int(index)),
                  let child = model.objects[object.childPaths[Int(index)]],
                  let id = child.id
            else { return invalidArguments(message) }
            let accepted = onAction?(.init(
                target: id,
                action: .select)) ?? false
            return reply(message) { $0.boolean(accepted) }
        default:
            return unknownMethod(
                message,
                interface: AtSPIInterface.selection,
                member: member)
        }
    }

    // MARK: - Properties

    fileprivate enum PropertyValue {
        case string(String)
        case int32(Int32)
        case uint32(UInt32)
        case double(Double)
        case objectReference(busName: String, path: String)

        func appendVariant(to writer: inout MessageWriter) -> Int32 {
            switch self {
            case .string(let value):
                return writer.variant(signature: "s") {
                    $0.string(value)
                }
            case .int32(let value):
                return writer.variant(signature: "i") {
                    $0.int32(value)
                }
            case .uint32(let value):
                return writer.variant(signature: "u") {
                    $0.uint32(value)
                }
            case .double(let value):
                return writer.variant(signature: "d") {
                    $0.double(value)
                }
            case .objectReference(let busName, let path):
                return writer.variant(signature: "(so)") {
                    $0.objectReference(
                        busName: busName,
                        path: path)
                }
            }
        }
    }

    private func propertyValue(
        object: AtSPIExportedObject,
        interface: String,
        property: String
    ) -> PropertyValue? {
        switch (interface, property) {
        case (AtSPIInterface.accessible, "Name"):
            .string(object.name)
        case (AtSPIInterface.accessible, "Description"):
            .string(object.description)
        case (AtSPIInterface.accessible, "Parent"):
            .objectReference(
                busName: object.parentPath == nil ? "" : uniqueName,
                path: object.parentPath ?? AtSPIExportModel.nullPath)
        case (AtSPIInterface.accessible, "ChildCount"):
            .int32(Int32(clamping: object.childPaths.count))
        case (AtSPIInterface.accessible, "Locale"):
            .string(locale)
        case (AtSPIInterface.accessible, "AccessibleId"):
            .string(object.id?.pathComponent ?? "application")
        case (AtSPIInterface.accessible, "HelpText"):
            .string(object.description)
        case (AtSPIInterface.accessible, "version"):
            .uint32(2)
        case (AtSPIInterface.action, "NActions"):
            .int32(Int32(clamping: object.parameterlessActions.count))
        case (AtSPIInterface.action, "version"):
            .uint32(1)
        case (AtSPIInterface.application, "ToolkitName"):
            .string("NucleusUI")
        case (AtSPIInterface.application, "ToolkitVersion"):
            .string("0.1")
        case (AtSPIInterface.application, "Version"):
            .string("0.1")
        case (AtSPIInterface.application, "AtspiVersion"):
            .string("2.1")
        case (AtSPIInterface.application, "InterfaceVersion"):
            .uint32(1)
        case (AtSPIInterface.application, "Id"):
            .int32(applicationID)
        case (AtSPIInterface.component, "version"):
            .uint32(1)
        case (AtSPIInterface.text, "CharacterCount"):
            .int32(Int32(clamping: object.text.count))
        case (AtSPIInterface.text, "CaretOffset"):
            .int32(Int32(clamping: characterRange(
                in: object.text,
                utf16Range: object.textSelection?.utf16Range ?? 0..<0
            ).upperBound))
        case (AtSPIInterface.text, "version"):
            .uint32(1)
        case (AtSPIInterface.editableText, "version"):
            .uint32(1)
        case (AtSPIInterface.selection, "version"):
            .uint32(1)
        case (AtSPIInterface.value, "MinimumValue"):
            object.range.map { .double($0.minimum) }
        case (AtSPIInterface.value, "MaximumValue"):
            object.range.map { .double($0.maximum) }
        case (AtSPIInterface.value, "MinimumIncrement"):
            object.range.map { .double($0.increment ?? 0) }
        case (AtSPIInterface.value, "CurrentValue"):
            object.range.map { .double($0.current) }
        case (AtSPIInterface.value, "Text"):
            .string(object.valueText)
        case (AtSPIInterface.value, "version"):
            .uint32(1)
        default:
            nil
        }
    }

    private func allProperties(
        object: AtSPIExportedObject,
        interface: String
    ) -> [(String, PropertyValue)] {
        let names: [String] = switch interface {
        case AtSPIInterface.accessible:
            ["Name", "Description", "Parent", "ChildCount", "Locale",
             "AccessibleId", "HelpText", "version"]
        case AtSPIInterface.action:
            ["NActions", "version"]
        case AtSPIInterface.application:
            ["ToolkitName", "ToolkitVersion", "Version", "AtspiVersion",
             "InterfaceVersion", "Id"]
        case AtSPIInterface.component:
            ["version"]
        case AtSPIInterface.text:
            ["CharacterCount", "CaretOffset", "version"]
        case AtSPIInterface.editableText, AtSPIInterface.selection:
            ["version"]
        case AtSPIInterface.value:
            ["MinimumValue", "MaximumValue", "MinimumIncrement",
             "CurrentValue", "Text", "version"]
        default:
            []
        }
        return names.compactMap { name in
            propertyValue(
                object: object,
                interface: interface,
                property: name).map { (name, $0) }
        }
    }

    // MARK: - Events

    private func emit(_ event: AtSPIEvent) {
        guard let bus else { return }
        let descriptor: (String, String)
        switch event.kind {
        case .windowCreated:
            descriptor = ("org.a11y.atspi.Event.Window", "Create")
        case .windowDestroyed:
            descriptor = ("org.a11y.atspi.Event.Window", "Destroy")
        case .focus:
            descriptor = ("org.a11y.atspi.Event.Focus", "Focus")
        case .valueChanged:
            descriptor = ("org.a11y.atspi.Event.Object", "PropertyChange")
        case .selectionChanged:
            descriptor = ("org.a11y.atspi.Event.Object", "SelectionChanged")
        case .childrenAdded, .childrenRemoved:
            descriptor = ("org.a11y.atspi.Event.Object", "ChildrenChanged")
        case .boundsChanged:
            descriptor = ("org.a11y.atspi.Event.Object", "BoundsChanged")
        case .announcement, .liveRegion:
            descriptor = ("org.a11y.atspi.Event.Object", "Announcement")
        }
        var signal: OpaquePointer?
        let created = event.sourcePath.withCString { path in
            descriptor.0.withCString { interface in
                descriptor.1.withCString { member in
                    sd_bus_message_new_signal(
                        bus,
                        &signal,
                        path,
                        interface,
                        member)
                }
            }
        }
        guard created >= 0, let signal else { return }
        defer { sd_bus_message_unref(signal) }
        var writer = MessageWriter(signal)
        guard writer.string(event.detail) >= 0,
              writer.int32(event.kind == .focus ? 1 : 0) >= 0,
              writer.int32(0) >= 0
        else { return }
        let variantResult: Int32
        if let related = event.relatedPath {
            variantResult = writer.variant(signature: "(so)") {
                $0.objectReference(busName: uniqueName, path: related)
            }
        } else if event.kind == .boundsChanged,
                  let object = model.objects[event.sourcePath]
        {
            variantResult = writer.variant(signature: "(iiii)") {
                $0.structValue(signature: "iiii") {
                    $0.rect(object.frame)
                }
            }
        } else {
            variantResult = writer.variant(signature: "s") {
                $0.string(event.text ?? "")
            }
        }
        guard variantResult >= 0,
              writer.stringVariantDictionary([:]) >= 0
        else { return }
        _ = sd_bus_send(bus, signal, nil)
    }

    // MARK: - Helpers

    private func reply(
        _ call: OpaquePointer,
        _ body: (inout MessageWriter) -> Int32
    ) -> Int32 {
        var message: OpaquePointer?
        let created = sd_bus_message_new_method_return(call, &message)
        guard created >= 0, let message else { return created }
        defer { sd_bus_message_unref(message) }
        var writer = MessageWriter(message)
        let encoded = body(&writer)
        guard encoded >= 0 else { return encoded }
        return sd_bus_send(nil, message, nil)
    }

    private func replyError(
        _ call: OpaquePointer,
        name: String,
        text: String
    ) -> Int32 {
        name.withCString { namePointer in
            text.withCString { textPointer in
                nucleus_dbus_reply_error(
                    call,
                    namePointer,
                    textPointer)
            }
        }
    }

    private func invalidArguments(_ call: OpaquePointer) -> Int32 {
        replyError(
            call,
            name: "org.freedesktop.DBus.Error.InvalidArgs",
            text: "The AT-SPI method arguments are invalid")
    }

    private func actionFailed(_ call: OpaquePointer) -> Int32 {
        replyError(
            call,
            name: "org.a11y.atspi.Error.Failed",
            text: "The accessibility action was rejected")
    }

    private func unknownMethod(
        _ call: OpaquePointer,
        interface: String,
        member: String
    ) -> Int32 {
        replyError(
            call,
            name: "org.freedesktop.DBus.Error.UnknownMethod",
            text: "Unsupported method \(interface).\(member)")
    }

    private func string(_ pointer: UnsafePointer<CChar>?) -> String {
        pointer.map { String(cString: $0) } ?? ""
    }

    private func readString(_ message: OpaquePointer) -> String? {
        var raw: UnsafePointer<CChar>?
        guard sd_bus_message_read_basic(
            message,
            dbusTypeString,
            &raw) >= 0,
              let raw
        else { return nil }
        return String(cString: raw)
    }

    private func readInt32(_ message: OpaquePointer) -> Int32? {
        var value: Int32 = 0
        return sd_bus_message_read_basic(
            message,
            dbusTypeInt32,
            &value) >= 0 ? value : nil
    }

    private func readUInt32(_ message: OpaquePointer) -> UInt32? {
        var value: UInt32 = 0
        return sd_bus_message_read_basic(
            message,
            dbusTypeUInt32,
            &value) >= 0 ? value : nil
    }

    private func readDouble(_ message: OpaquePointer) -> Double? {
        var value = 0.0
        return sd_bus_message_read_basic(
            message,
            dbusTypeDouble,
            &value) >= 0 ? value : nil
    }

    private func readVariantInt32(_ message: OpaquePointer) -> Int32? {
        guard sd_bus_message_enter_container(
            message,
            dbusTypeVariant,
            "i") >= 0
        else { return nil }
        defer { _ = sd_bus_message_exit_container(message) }
        return readInt32(message)
    }

    private func readVariantDouble(_ message: OpaquePointer) -> Double? {
        guard sd_bus_message_enter_container(
            message,
            dbusTypeVariant,
            "d") >= 0
        else { return nil }
        defer { _ = sd_bus_message_exit_container(message) }
        return readDouble(message)
    }

    private func readObjectReference(
        _ message: OpaquePointer
    ) -> (String, String)? {
        guard sd_bus_message_enter_container(
            message,
            dbusTypeStruct,
            "so") >= 0
        else { return nil }
        defer { _ = sd_bus_message_exit_container(message) }
        var name: UnsafePointer<CChar>?
        var path: UnsafePointer<CChar>?
        guard sd_bus_message_read_basic(
            message,
            dbusTypeString,
            &name) >= 0,
              sd_bus_message_read_basic(
                message,
                dbusTypeObjectPath,
                &path) >= 0,
              let name,
              let path
        else { return nil }
        return (String(cString: name), String(cString: path))
    }

    private func indexedAction(
        _ message: OpaquePointer,
        actions: [AccessibilityAction]
    ) -> AccessibilityAction? {
        guard let index = readInt32(message),
              index >= 0,
              actions.indices.contains(Int(index))
        else { return nil }
        return actions[Int(index)]
    }

    private func actionName(_ action: AccessibilityAction) -> String {
        switch action {
        case .press: "click"
        case .select: "select"
        case .focus: "focus"
        case .increment: "increment"
        case .decrement: "decrement"
        case .expand: "expand"
        case .collapse: "collapse"
        case .dismiss: "dismiss"
        case .copy: "copy"
        case .cut: "cut"
        case .paste: "paste"
        case .selectAll: "select-all"
        case .undo: "undo"
        case .redo: "redo"
        case .setValue, .setText, .setSelection: ""
        }
    }

    private func actionDescription(_ action: AccessibilityAction) -> String {
        switch action {
        case .press: "Activates the control"
        case .select: "Selects the item"
        case .focus: "Moves keyboard focus to the control"
        case .increment: "Increases the value"
        case .decrement: "Decreases the value"
        case .expand: "Expands the control"
        case .collapse: "Collapses the control"
        case .dismiss: "Dismisses the control"
        case .copy: "Copies the selected text"
        case .cut: "Cuts the selected text"
        case .paste: "Pastes text"
        case .selectAll: "Selects all text"
        case .undo: "Undoes the previous edit"
        case .redo: "Redoes the previous edit"
        case .setValue, .setText, .setSelection: ""
        }
    }

    private func isSelected(_ object: AtSPIExportedObject) -> Bool {
        let state = 23
        return object.states.indices.contains(state / 32)
            && object.states[state / 32] & (UInt32(1) << UInt32(state % 32)) != 0
    }

    private func deepestObject(
        at point: Point,
        below root: AtSPIExportedObject
    ) -> String? {
        func descend(_ object: AtSPIExportedObject) -> String? {
            for path in object.childPaths.reversed() {
                guard let child = model.objects[path],
                      child.frame.contains(point)
                else { continue }
                return descend(child) ?? path
            }
            return nil
        }
        return descend(root)
    }

    private func textSlice(
        _ text: String,
        start: Int,
        end: Int
    ) -> String {
        let characters = Array(text)
        let lower = min(max(0, start), characters.count)
        let proposedEnd = end < 0 ? characters.count : end
        let upper = min(max(lower, proposedEnd), characters.count)
        return String(characters[lower..<upper])
    }

    private func utf16Offset(
        in text: String,
        characterOffset: Int
    ) -> Int {
        let offset = min(max(0, characterOffset), text.count)
        let index = text.index(
            text.startIndex,
            offsetBy: offset)
        return index.utf16Offset(in: text)
    }

    private func characterRange(
        in text: String,
        utf16Range: Range<Int>
    ) -> Range<Int> {
        func characterOffset(_ utf16Offset: Int) -> Int {
            let bounded = min(
                max(0, utf16Offset),
                text.utf16.count)
            let utf16Index = text.utf16.index(
                text.utf16.startIndex,
                offsetBy: bounded)
            guard let index = String.Index(
                utf16Index,
                within: text)
            else { return text.count }
            return text.distance(from: text.startIndex, to: index)
        }
        let lower = characterOffset(utf16Range.lowerBound)
        let upper = characterOffset(utf16Range.upperBound)
        return min(lower, upper)..<max(lower, upper)
    }

    private func introspectionXML(
        for object: AtSPIExportedObject
    ) -> String {
        let interfaces = object.interfaces.map {
            "<interface name=\"\($0)\"/>"
        }.joined()
        return """
        <node>
          <interface name="org.freedesktop.DBus.Introspectable">
            <method name="Introspect"><arg direction="out" type="s"/></method>
          </interface>
          <interface name="org.freedesktop.DBus.Properties">
            <method name="Get"><arg direction="in" type="s"/><arg direction="in" type="s"/><arg direction="out" type="v"/></method>
            <method name="GetAll"><arg direction="in" type="s"/><arg direction="out" type="a{sv}"/></method>
            <method name="Set"><arg direction="in" type="s"/><arg direction="in" type="s"/><arg direction="in" type="v"/></method>
          </interface>
          \(interfaces)
        </node>
        """
    }

    private static func isWindowRole(_ role: UInt32) -> Bool {
        role == 2 || role == 16 || role == 41 || role == 69
    }
}

private struct MessageWriter {
    let message: OpaquePointer
    private(set) var result: Int32 = 0

    init(_ message: OpaquePointer) {
        self.message = message
    }

    mutating func string(_ value: String) -> Int32 {
        guard result >= 0 else { return result }
        result = value.withCString {
            sd_bus_message_append_basic(
                message,
                dbusTypeString,
                $0)
        }
        return result
    }

    mutating func objectPath(_ value: String) -> Int32 {
        guard result >= 0 else { return result }
        result = value.withCString {
            sd_bus_message_append_basic(
                message,
                dbusTypeObjectPath,
                $0)
        }
        return result
    }

    mutating func int16(_ value: Int16) -> Int32 {
        var value = value
        result = withUnsafePointer(to: &value) {
            sd_bus_message_append_basic(
                message,
                dbusTypeInt16,
                $0)
        }
        return result
    }

    mutating func int32(_ value: Int32) -> Int32 {
        var value = value
        result = withUnsafePointer(to: &value) {
            sd_bus_message_append_basic(
                message,
                dbusTypeInt32,
                $0)
        }
        return result
    }

    mutating func uint32(_ value: UInt32) -> Int32 {
        var value = value
        result = withUnsafePointer(to: &value) {
            sd_bus_message_append_basic(
                message,
                dbusTypeUInt32,
                $0)
        }
        return result
    }

    mutating func boolean(_ value: Bool) -> Int32 {
        var raw: Int32 = value ? 1 : 0
        result = withUnsafePointer(to: &raw) {
            sd_bus_message_append_basic(
                message,
                dbusTypeBoolean,
                $0)
        }
        return result
    }

    mutating func double(_ value: Double) -> Int32 {
        var value = value
        result = withUnsafePointer(to: &value) {
            sd_bus_message_append_basic(
                message,
                dbusTypeDouble,
                $0)
        }
        return result
    }

    mutating func container(
        type: CChar,
        signature: String,
        _ body: (inout MessageWriter) -> Int32
    ) -> Int32 {
        guard result >= 0 else { return result }
        result = signature.withCString {
            sd_bus_message_open_container(message, type, $0)
        }
        guard result >= 0 else { return result }
        let bodyResult = body(&self)
        guard bodyResult >= 0 else {
            result = bodyResult
            return result
        }
        result = sd_bus_message_close_container(message)
        return result
    }

    mutating func structValue(
        signature: String,
        _ body: (inout MessageWriter) -> Int32
    ) -> Int32 {
        container(type: dbusTypeStruct, signature: signature, body)
    }

    mutating func variant(
        signature: String,
        _ body: (inout MessageWriter) -> Int32
    ) -> Int32 {
        container(type: dbusTypeVariant, signature: signature, body)
    }

    mutating func objectReference(
        busName: String,
        path: String
    ) -> Int32 {
        structValue(signature: "so") { writer in
            let first = writer.string(busName)
            guard first >= 0 else { return first }
            return writer.objectPath(path)
        }
    }

    mutating func objectReferenceArray(
        _ paths: [String],
        busName: String
    ) -> Int32 {
        container(type: dbusTypeArray, signature: "(so)") { writer in
            for path in paths {
                let result = writer.objectReference(
                    busName: busName,
                    path: path)
                guard result >= 0 else { return result }
            }
            return 0
        }
    }

    mutating func stringArray(_ values: [String]) -> Int32 {
        container(type: dbusTypeArray, signature: "s") { writer in
            for value in values {
                let result = writer.string(value)
                guard result >= 0 else { return result }
            }
            return 0
        }
    }

    mutating func uint32Array(_ values: [UInt32]) -> Int32 {
        container(type: dbusTypeArray, signature: "u") { writer in
            for value in values {
                let result = writer.uint32(value)
                guard result >= 0 else { return result }
            }
            return 0
        }
    }

    mutating func stringDictionary(
        _ values: [String: String]
    ) -> Int32 {
        container(type: dbusTypeArray, signature: "{ss}") { writer in
            for key in values.keys.sorted() {
                let result = writer.container(
                    type: dbusTypeDictEntry,
                    signature: "ss"
                ) {
                    let first = $0.string(key)
                    guard first >= 0 else { return first }
                    return $0.string(values[key] ?? "")
                }
                guard result >= 0 else { return result }
            }
            return 0
        }
    }

    mutating func stringVariantDictionary(
        _ values: [String: String]
    ) -> Int32 {
        container(type: dbusTypeArray, signature: "{sv}") { writer in
            for key in values.keys.sorted() {
                let result = writer.container(
                    type: dbusTypeDictEntry,
                    signature: "sv"
                ) {
                    let first = $0.string(key)
                    guard first >= 0 else { return first }
                    return $0.variant(signature: "s") {
                        $0.string(values[key] ?? "")
                    }
                }
                guard result >= 0 else { return result }
            }
            return 0
        }
    }

    mutating func dictionary(
        _ values: [(String, SystemdAtSPIAdapter.PropertyValue)]
    ) -> Int32 {
        container(type: dbusTypeArray, signature: "{sv}") { writer in
            for (name, value) in values {
                let result = writer.container(
                    type: dbusTypeDictEntry,
                    signature: "sv"
                ) {
                    let first = $0.string(name)
                    guard first >= 0 else { return first }
                    return value.appendVariant(to: &$0)
                }
                guard result >= 0 else { return result }
            }
            return 0
        }
    }

    mutating func relationSet(
        _ relations: [UInt32: [String]],
        busName: String
    ) -> Int32 {
        container(type: dbusTypeArray, signature: "(ua(so))") { writer in
            for relation in relations.keys.sorted() {
                let result = writer.structValue(signature: "ua(so)") {
                    let first = $0.uint32(relation)
                    guard first >= 0 else { return first }
                    return $0.objectReferenceArray(
                        relations[relation] ?? [],
                        busName: busName)
                }
                guard result >= 0 else { return result }
            }
            return 0
        }
    }

    mutating func actionDescriptions(
        _ actions: [AccessibilityAction]
    ) -> Int32 {
        container(type: dbusTypeArray, signature: "(sss)") { writer in
            for action in actions {
                let result = writer.structValue(signature: "sss") {
                    let name = String(describing: action)
                    let first = $0.string(name)
                    guard first >= 0 else { return first }
                    let second = $0.string(name)
                    guard second >= 0 else { return second }
                    return $0.string("")
                }
                guard result >= 0 else { return result }
            }
            return 0
        }
    }

    mutating func rect(_ rect: Rect) -> Int32 {
        let values = [
            Int32(clamping: Int(rect.origin.x)),
            Int32(clamping: Int(rect.origin.y)),
            Int32(clamping: Int(rect.size.width)),
            Int32(clamping: Int(rect.size.height)),
        ]
        for value in values {
            let result = int32(value)
            guard result >= 0 else { return result }
        }
        return 0
    }
}
