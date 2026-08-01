import Foundation  // FileHandle supplies generator diagnostics.
import SwiftSyntax
import SwiftSyntaxBuilder
import WaylandProtocolModel

#if canImport(FoundationXML)
import FoundationXML
#endif

// The unified Wayland C-binding generator, shared by Wayland server and client consumers
// shell (client) through the render core both embed. It emits `<Module>.h` + `module.modulemap`
// for a `.systemLibrary` that façades libwayland's own headers.
//
// The server/client difference is a `--mode` flag: the base include (`<wayland-server.h>` vs
// `<wayland-client.h>`), the emitted extension include (`"<name>-{server,client}-protocol.h"`),
// and the server-only request-vtable typedefs. It links no Wayland — a shallow Foundation
// XMLParser pass — so it lives beside the shared protocol XML in third-party/.
//
// DEPENDENCY CLOSURE: a protocol's marshalling table can reference another protocol's
// interface (e.g. cursor-shape's set_shape takes a `zwp_tablet_tool_v2`), whose `wl_interface`
// symbol is *defined* by that other protocol's `-protocol.c`. Generating only the selected
// protocols then leaves an undefined symbol at link. So the generator computes the transitive
// closure: it indexes every protocol XML under the `--search-dir`s by the interfaces it
// defines, and pulls in the defining protocol for any referenced-but-undefined interface. Core
// wayland interfaces (wl_*) are defined by wayland.xml (always passed) and provided by
// libwayland, so they add nothing. The closure is written to `generated-protocols.tsv` so the
// plugin runs wayland-scanner over the SAME set (selected + pulled-in dependencies).
//
//   SwiftWaylandGen --mode <server|client> --module <ModuleName>
//                     [--search-dir <dir> ...] <out_dir> <xml...>

enum Mode: String { case server, client }

public struct WaylandGeneratorDiagnostic: Error, Equatable, CustomStringConvertible {
    public let path: String
    public let context: String
    public let problem: String

    public init(path: String, context: String, problem: String) {
        self.path = path
        self.context = context
        self.problem = problem
    }

    public var description: String {
        "\(path): \(context): \(problem)"
    }
}

typealias WArg = WaylandArgument
typealias WMsg = WaylandMessage
typealias Iface = WaylandInterface
typealias Proto = WaylandProtocol

extension WaylandMessage {
    fileprivate var args: [WaylandArgument] {
        get { arguments }
        set { arguments = newValue }
    }
}

extension WaylandProtocol {
    fileprivate var defines: Set<String> {
        get { definedInterfaces }
        set { definedInterfaces = newValue }
    }

    fileprivate var references: Set<String> {
        get { referencedInterfaces }
        set { referencedInterfaces = newValue }
    }
}

private func parseProtocol(_ path: String) throws -> Proto {
    try WaylandProtocolParser.parse(path: path)
}

public enum SwiftWaylandGenerator {
    public static func run(arguments: [String]) throws {
        // ── Parse args: --mode X --module Y [--search-dir D...] <out_dir> <xml...> ───────
        var mode: Mode?
        var module: String?
        var searchDirs: [String] = []
        var positional: [String] = []
        var dispatchDir: String?  // emit typed Swift dispatch here (server mode)
        var typesDir: String?  // emit shared Swift protocol value types here
        var dispatchOnly: Set<String>?  // restrict dispatch emission to these interfaces
        var it = arguments.dropFirst().makeIterator()
        while let a = it.next() {
            switch a {
            case "--mode": mode = it.next().flatMap(Mode.init(rawValue:))
            case "--module": module = it.next()
            case "--search-dir": if let d = it.next() { searchDirs.append(d) }
            case "--dispatch": dispatchDir = it.next()
            case "--types": typesDir = it.next()
            case "--dispatch-only":
                dispatchOnly = it.next().map { Set($0.split(separator: ",").map(String.init)) }
            default: positional.append(a)
            }
        }
        guard let mode, let module, positional.count >= 1 else {
            FileHandle.standardError.write(
                "usage: SwiftWaylandGen --mode <server|client> --module <ModuleName> [--search-dir <dir> ...] <out_dir> <xml...>\n"
                    .data(using: .utf8)!)
            exit(1)
        }
        let outDir = positional[0]
        let selected = try positional[1...].map(parseProtocol)

        // ── Index the search dirs (interface name → defining XML) and compute the closure ──
        let closure = try resolveClosure(
            selected: selected,
            searchDirectories: searchDirs)
        try validate(protocols: closure)

        let enumerationsByName: [String: (interface: Iface, enumeration: WaylandEnumeration)] =
            Dictionary(
                uniqueKeysWithValues: closure.flatMap { proto in
                    proto.interfaces.flatMap { interface in
                        interface.enumerations.map {
                            ("\(interface.name).\($0.name)", (interface, $0))
                        }
                    }
                })

        let base = mode == .server ? "wayland-server.h" : "wayland-client.h"
        let protoSuffix = mode == .server ? "server-protocol.h" : "client-protocol.h"
        let guardMacro =
            module.uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }
            .reduce(into: "") { $0.append($1) } + "_H"

        var out = """
            /* Generated by SwiftWaylandGen (swiftpm/tools/SwiftWaylandGen). Do not edit.
             *
             * Façades over libwayland's own \(mode.rawValue) headers for decls the Swift clang importer
             * cannot express directly. libwayland's structs and \(mode == .server ? "event senders" : "proxy inlines")
             * are consumed from Swift unchanged; this header adds only the interface-descriptor accessors,
             * the wl_fixed helpers\(mode == .server ? ", and the request-vtable typedefs" : "").
             *
             * The included protocols are the selected set plus their transitive interface-dependency
             * closure (e.g. cursor-shape pulls in tablet, whose interface it references).
             */
            #ifndef \(guardMacro)
            #define \(guardMacro)

            #include <\(base)>


            """

        // Extension protocol glue (wayland-scanner output). Some protocols name a request, event or
        // argument with a C++ keyword — wlr-layer-shell's `namespace` param, xdg-foreign v1's `export` /
        // `import` requests — which the Swift clang importer (parsing under C++ interop) rejects. Neutralize
        // every C++-only keyword across these includes with scoped macros: the headers are valid C, so any
        // such token is an identifier, safe to rename here and #undef'd immediately after (a consumer of one
        // of those exact members uses the renamed `swift_wayland_wl_kw_<kw>` form).
        let cxxKeywordIdentifiers = [
            "namespace", "export", "import", "class", "new", "delete", "template",
            "operator", "this", "private", "public", "protected", "virtual",
            "friend", "typename", "register",
        ]
        var emittedGuard = false
        for proto in closure where proto.name != "wayland" {
            if !emittedGuard {
                for kw in cxxKeywordIdentifiers {
                    out += "#define \(kw) swift_wayland_wl_kw_\(kw)\n"
                }
                out += "\n"
                emittedGuard = true
            }
            out += "#include \"\(proto.name)-\(protoSuffix)\"\n"
        }
        if emittedGuard {
            out += "\n"
            for kw in cxxKeywordIdentifiers { out += "#undef \(kw)\n" }
            out += "\n"
        }

        out += "\n/* Variadic/macro façades: non-variadic signatures Swift can import. */\n"
        if mode == .server {
            out += """
                #include <stdlib.h>

                /* wl_resource_post_error is variadic; expose a plain message form. The message is passed
                 * through "%s" so caller text is never a format string. */
                static inline void swift_wayland_resource_post_error(struct wl_resource *resource,
                                                               uint32_t code, const char *msg) {
                    wl_resource_post_error(resource, code, "%s", msg);
                }

                /* A destroy listener with one opaque owner slot, used by Swift to turn a
                 * cross-request wl_resource borrow into a checked live reference. */
                struct swift_wayland_resource_lifetime_listener {
                    struct wl_listener listener;
                    void *owner;
                };

                static inline struct swift_wayland_resource_lifetime_listener *
                swift_wayland_resource_lifetime_listener_create(
                    void *owner, void (*notify)(struct wl_listener *, void *)) {
                    struct swift_wayland_resource_lifetime_listener *box =
                        (struct swift_wayland_resource_lifetime_listener *)calloc(1, sizeof(*box));
                    if (!box) return NULL;
                    box->listener.notify = notify;
                    box->owner = owner;
                    return box;
                }

                static inline void swift_wayland_resource_lifetime_listener_attach(
                    struct swift_wayland_resource_lifetime_listener *box,
                    struct wl_resource *resource) {
                    wl_resource_add_destroy_listener(resource, &box->listener);
                }

                static inline void swift_wayland_client_lifetime_listener_attach(
                    struct swift_wayland_resource_lifetime_listener *box,
                    struct wl_client *client) {
                    wl_client_add_destroy_listener(client, &box->listener);
                }

                static inline void *swift_wayland_resource_lifetime_listener_owner(
                    struct wl_listener *listener) {
                    struct swift_wayland_resource_lifetime_listener *box =
                        wl_container_of(listener, box, listener);
                    return box->owner;
                }

                static inline struct swift_wayland_resource_lifetime_listener *
                swift_wayland_resource_lifetime_listener_box(struct wl_listener *listener) {
                    struct swift_wayland_resource_lifetime_listener *box =
                        wl_container_of(listener, box, listener);
                    return box;
                }

                static inline void swift_wayland_resource_lifetime_listener_destroy(
                    struct swift_wayland_resource_lifetime_listener *box) {
                    if (!box) return;
                    wl_list_remove(&box->listener.link);
                    free(box);
                }

                """
        }
        out += """
            /* wl_fixed_t <-> double. The wl_fixed_* inlines use a union type-pun the Swift clang
             * importer may decline to import; these plain wrappers always do. */
            static inline wl_fixed_t swift_wayland_fixed_from_double(double d) { return wl_fixed_from_double(d); }
            static inline double swift_wayland_fixed_to_double(wl_fixed_t f) { return wl_fixed_to_double(f); }


            """
        if mode == .client {
            out += """
                /* Non-variadic request façades generated from the selected XML. These keep
                 * Swift out of wayland-scanner inlines and cover core requests newer than the
                 * distribution's wayland-client-protocol.h. */

                """
            for proto in closure {
                for iface in proto.interfaces {
                    for (opcode, request) in iface.requests.enumerated() {
                        if iface.name == "wl_registry", request.name == "bind" {
                            continue
                        }
                        let typedNewID = request.args.first {
                            $0.type == "new_id" && $0.interface != nil
                        }
                        let returnType =
                            typedNewID == nil
                            ? "void"
                            : "struct wl_proxy *"
                        var parameters = ["struct wl_proxy *swift_wayland_proxy"]
                        for argument in request.args where argument.type != "new_id" {
                            let name = "swift_wayland_arg_\(argument.name)"
                            let type: String
                            switch argument.type {
                            case "int", "fd": type = "int32_t"
                            case "uint": type = "uint32_t"
                            case "fixed": type = "wl_fixed_t"
                            case "string": type = "const char *"
                            case "object": type = "struct wl_proxy *"
                            case "array": type = "struct wl_array *"
                            default:
                                fatalError(
                                    "unsupported client request argument type '\(argument.type)' in \(iface.name).\(request.name)"
                                )
                            }
                            parameters.append("\(type) \(name)")
                        }
                        let childInterface =
                            typedNewID
                            .flatMap(\.interface)
                            .map { "&\($0)_interface" }
                            ?? "NULL"
                        let flags =
                            request.isDestructor
                            ? "WL_MARSHAL_FLAG_DESTROY"
                            : "0"
                        let wireArguments = request.args.map { argument in
                            argument.type == "new_id"
                                ? "NULL"
                                : "swift_wayland_arg_\(argument.name)"
                        }
                        let suffix =
                            wireArguments.isEmpty
                            ? ""
                            : ", " + wireArguments.joined(separator: ", ")
                        let call = """
                            wl_proxy_marshal_flags(
                                    swift_wayland_proxy, \(opcode), \(childInterface),
                                    wl_proxy_get_version(swift_wayland_proxy), \(flags)\(suffix))
                            """
                        out += "static inline \(returnType)\n"
                        out += "swift_wayland_client_request_\(iface.name)_\(request.name)(\n"
                        out += "    \(parameters.joined(separator: ", "))\n) {\n"
                        if typedNewID != nil {
                            out += "    return \(call);\n"
                        } else {
                            out += "    \(call);\n"
                        }
                        out += "}\n\n"
                    }
                }
            }
        }
        out += """
            /* Interface-descriptor accessors — the client binds/creates by &<name>_interface; the server
             * reads them for globals. Expose each as a plain accessor so Swift gets a clean pointer. */

            """
        for proto in closure {
            for iface in proto.interfaces {
                out +=
                    "static inline const struct wl_interface *swift_wayland_iface_\(iface.name)(void) { return &\(iface.name)_interface; }\n"
            }
        }

        if mode == .server {
            out += "\n/* Request-handler vtable typedefs (non-colliding names for Swift). */\n"
            for proto in closure {
                for iface in proto.interfaces where iface.requestCount > 0 {
                    if proto.name == "wayland" {
                        // The vendored core protocol can be newer than the distribution's
                        // wayland-server-protocol.h. Generate the request-table ABI from the
                        // selected XML so tail requests are never silently omitted by an
                        // older system struct.
                        out += "typedef struct swift_wayland_\(iface.name)_requests {\n"
                        for request in iface.requests {
                            var parameters = ["struct wl_client *", "struct wl_resource *"]
                            for argument in request.args {
                                switch argument.type {
                                case "int", "fd":
                                    parameters.append("int32_t")
                                case "uint":
                                    parameters.append("uint32_t")
                                case "fixed":
                                    parameters.append("wl_fixed_t")
                                case "string":
                                    parameters.append("const char *")
                                case "object":
                                    parameters.append("struct wl_resource *")
                                case "array":
                                    parameters.append("struct wl_array *")
                                case "new_id" where argument.interface == nil:
                                    parameters.append(contentsOf: [
                                        "const char *", "uint32_t", "uint32_t",
                                    ])
                                case "new_id":
                                    parameters.append("uint32_t")
                                default:
                                    fatalError(
                                        "unsupported core request argument type '\(argument.type)' in \(iface.name).\(request.name)"
                                    )
                                }
                            }
                            out +=
                                "    void (*\(request.name))(\(parameters.joined(separator: ", ")));\n"
                        }
                        out += "} swift_wayland_\(iface.name)_requests;\n"
                    } else {
                        out +=
                            "typedef struct \(iface.name)_interface swift_wayland_\(iface.name)_requests;\n"
                    }
                }
            }
        }

        out += "\n#endif /* \(guardMacro) */\n"

        try out.write(toFile: "\(outDir)/\(module).h", atomically: true, encoding: .utf8)
        try "module \(module) {\n    header \"\(module).h\"\n    export *\n}\n"
            .write(toFile: "\(outDir)/module.modulemap", atomically: true, encoding: .utf8)

        // The closure manifest: the protocols the plugin must run wayland-scanner over (selected +
        // pulled-in dependencies), excluding core wayland (libwayland provides its marshalling).
        let manifest = closure.filter { $0.name != "wayland" }
            .map { "\($0.name)\t\($0.xmlPath)" }
            .joined(separator: "\n")
        try (manifest + "\n").write(
            toFile: "\(outDir)/generated-protocols.tsv", atomically: true, encoding: .utf8)

        // ── Typed Swift dispatch emission (server mode, opt-in via --dispatch) ─────────────
        // For each dispatchable interface: a handler protocol (one method per non-destructor request), the
        // request vtable + owner recovery + arg marshalling, and typed event senders. Object args pass as
        // raw wl_resource* (their Swift owner type is consumer-defined); new_id args arrive as a typed
        // handle the layer creates; scalars/wl_fixed marshal to Swift types. Consumers conform their model
        // to <Iface>Requests — pure policy — and never write a trampoline.

        func lowerCamel(_ s: String) -> String {
            let parts = s.split(separator: "_").map(String.init)
            guard let first = parts.first else { return s }
            return first
                + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        }
        func upperCamel(_ s: String) -> String {
            s.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        }
        let swiftKeywords: Set<String> = [
            "import", "class", "enum", "struct", "protocol", "func", "var",
            "let", "return", "in", "default", "operator", "private", "public", "internal", "case",
            "switch",
            "for", "while", "repeat", "if", "else", "guard", "defer", "do", "throw", "throws",
            "try", "as",
            "is", "nil", "true", "false", "self", "init", "deinit", "subscript", "extension",
            "where",
        ]
        func esc(_ s: String) -> String { swiftKeywords.contains(s) ? "`\(s)`" : s }
        func memberName(_ s: String) -> String {
            let candidate = lowerCamel(s)
            guard candidate.first?.isNumber == true else { return esc(candidate) }
            return "_" + candidate
        }
        func enumerationName(_ qualifiedName: String) -> String? {
            enumerationsByName[qualifiedName].map {
                upperCamel($0.interface.name) + upperCamel($0.enumeration.name)
            }
        }
        func resolvedEnumerationName(_ argument: WArg, in interface: Iface) -> String? {
            guard let reference = argument.enumName else { return nil }
            let qualified =
                reference.contains(".")
                ? reference
                : "\(interface.name).\(reference)"
            return enumerationName(qualified)
        }

        // Swift type of a request/event arg in the handler protocol / event sender. A new_id differs by
        // direction: a *request* new_id is an object the client is asking the server to create — delivered
        // as a WlNewId the consumer materializes; an *event* new_id is an object the server has ALREADY
        // created and is announcing — passed as its live wl_resource.
        func swiftParamType(_ a: WArg, in interface: Iface, isEvent: Bool = false) -> String {
            if let enumeration = resolvedEnumerationName(a, in: interface) {
                return enumeration
            }
            switch a.type {
            case "int": return "Int32"
            case "fd": return isEvent ? "Int32" : "consuming WaylandOwnedFileDescriptor"
            case "uint": return "UInt32"
            case "fixed": return "Double"
            case "object":
                guard !isEvent, let interface = a.interface else {
                    return "UnsafeMutablePointer<wl_resource>?"
                }
                return "WaylandBorrowedObject<\(upperCamel(interface))Server>"
                    + (a.allowNull ? "?" : "")
            case "string":
                return isEvent ? "UnsafePointer<CChar>?" : "String" + (a.allowNull ? "?" : "")
            case "array": return isEvent ? "UnsafeMutablePointer<wl_array>?" : "WaylandArrayView"
            case "new_id":
                return isEvent
                    ? "UnsafeMutablePointer<wl_resource>?"
                    : "WlNewId<\(upperCamel(a.interface ?? ""))Server>"
            default: return "UInt32"
            }
        }

        func typedEventParamType(_ argument: WArg, in interface: Iface) -> String {
            if let enumeration = resolvedEnumerationName(argument, in: interface) {
                return enumeration
            }
            switch argument.type {
            case "int": return "Int32"
            case "fd": return "Int32"
            case "uint": return "UInt32"
            case "fixed": return "Double"
            case "object", "new_id":
                let referenced = upperCamel(argument.interface ?? "")
                return "WaylandResourceHandle<\(referenced)Server>"
                    + (argument.allowNull ? "?" : "")
            case "string": return "String" + (argument.allowNull ? "?" : "")
            case "array": return "[\(upperCamel(argument.name))Element]"
            default: return "UInt32"
            }
        }

        func requestArgumentExpression(_ argument: WArg, in interface: Iface) -> String {
            let raw =
                ["object", "string", "array"].contains(argument.type)
                ? "_request_\(argument.name)"
                : esc(argument.name)
            let label = esc(argument.name)
            switch argument.type {
            case "int" where argument.enumName != nil:
                return
                    "\(label): \(resolvedEnumerationName(argument, in: interface)!)(rawValue: UInt32(bitPattern: \(esc(argument.name))))"
            case "uint" where argument.enumName != nil:
                return
                    "\(label): \(resolvedEnumerationName(argument, in: interface)!)(rawValue: \(esc(argument.name)))"
            case "fixed":
                return "\(label): swift_wayland_fixed_to_double(\(esc(argument.name)))"
            case "string":
                if argument.allowNull {
                    return "\(label): \(raw).map { unsafe String(cString: $0) }"
                }
                return "\(label): unsafe String(cString: \(raw)!)"
            case "object":
                let type = upperCamel(argument.interface ?? "")
                if argument.allowNull {
                    return
                        "\(label): \(raw) == nil ? nil : .some(WaylandBorrowedObject<\(type)Server>(\(raw)!))"
                }
                return "\(label): WaylandBorrowedObject<\(type)Server>(\(raw)!)"
            case "array":
                return "\(label): WaylandArrayView(\(raw)!)"
            case "fd":
                return "\(label): WaylandOwnedFileDescriptor(\(esc(argument.name)))"
            default:
                return "\(label): \(raw)"
            }
        }
        // C type in the @convention(c) trampoline signature (matches the wl_scanner vtable field).
        func cParamType(_ a: WArg) -> String {
            switch a.type {
            case "int", "fd": return "Int32"
            case "uint", "new_id": return "UInt32"
            case "fixed": return "wl_fixed_t"
            case "object": return "UnsafeMutablePointer<wl_resource>?"
            case "string": return "UnsafePointer<CChar>?"
            case "array": return "UnsafeMutablePointer<wl_array>?"
            default: return "UInt32"
            }
        }

        if let typesDir {
            let fm = FileManager.default
            try? fm.createDirectory(atPath: typesDir, withIntermediateDirectories: true)
            var source = SwiftSourceFileBuilder()
            for proto in closure {
                for interface in proto.interfaces {
                    let interfaceName = upperCamel(interface.name)
                    for (direction, protocolName, messages) in [
                        ("Request", "WaylandRequestOpcode", interface.requests),
                        ("Event", "WaylandEventOpcode", interface.events),
                    ] where !messages.isEmpty {
                        let opcodeName = "\(interfaceName)\(direction)Opcode"
                        let declaration = EnumDeclSyntax(
                            attributes: [
                                .attribute(
                                    AttributeSyntax(
                                        attributeName: IdentifierTypeSyntax(
                                            name: .identifier("frozen"))))
                            ],
                            modifiers: [
                                DeclModifierSyntax(name: .keyword(.public))
                            ],
                            name: .identifier(opcodeName),
                            inheritanceClause: InheritanceClauseSyntax {
                                InheritedTypeSyntax(
                                    type: TypeSyntax(stringLiteral: "UInt16"))
                                InheritedTypeSyntax(
                                    type: TypeSyntax(stringLiteral: protocolName))
                            }
                        ) {
                            for (opcode, message) in messages.enumerated() {
                                DeclSyntax(
                                    """
                                    case \(raw: memberName(message.name)) = \(raw: opcode)
                                    """)
                            }
                        }
                        source.add(DeclSyntax(declaration))
                    }
                    for enumeration in interface.enumerations {
                        let name = interfaceName + upperCamel(enumeration.name)
                        let primaryConformance =
                            enumeration.isBitfield
                            ? "OptionSet"
                            : enumeration.name == "error"
                                ? "WaylandProtocolErrorValue"
                                : "RawRepresentable"
                        let declaration = StructDeclSyntax(
                            attributes: [
                                .attribute(
                                    AttributeSyntax(
                                        attributeName: IdentifierTypeSyntax(
                                            name: .identifier("frozen"))))
                            ],
                            modifiers: [
                                DeclModifierSyntax(name: .keyword(.public))
                            ],
                            name: .identifier(name),
                            inheritanceClause: InheritanceClauseSyntax {
                                InheritedTypeSyntax(
                                    type: TypeSyntax(
                                        stringLiteral: primaryConformance))
                                InheritedTypeSyntax(
                                    type: TypeSyntax(stringLiteral: "Hashable"))
                                InheritedTypeSyntax(
                                    type: TypeSyntax(stringLiteral: "Sendable"))
                            }
                        ) {
                            DeclSyntax("public let rawValue: UInt32")
                            DeclSyntax(
                                """
                                public init(rawValue: UInt32) {
                                    self.rawValue = rawValue
                                }
                                """)
                            for entry in enumeration.entries {
                                let numericValue =
                                    entry.value.hasPrefix("0x")
                                    ? UInt32(entry.value.dropFirst(2), radix: 16)
                                    : UInt32(entry.value)
                                let value =
                                    enumeration.isBitfield && numericValue == 0
                                    ? "[]"
                                    : "Self(rawValue: \(entry.value))"
                                let annotation = value == "[]" ? ": Self" : ""
                                DeclSyntax(
                                    """
                                    public static let \(raw: memberName(entry.name))\(raw: annotation) = \(raw: value)
                                    """)
                            }
                            if !enumeration.isBitfield {
                                let cases = enumeration.entries.map { entry in
                                    "case .\(memberName(entry.name)): \"\(entry.name)\""
                                }.joined(separator: "\n")
                                DeclSyntax(
                                    """
                                    public var knownName: String? {
                                        switch self {
                                        \(raw: cases)
                                        default: nil
                                        }
                                    }
                                    """)
                            }
                        }
                        source.add(DeclSyntax(declaration))
                    }
                }
            }
            try source.write(
                to: "\(typesDir)/WaylandProtocolTypes.swift",
                header: [
                    "Generated by SwiftWaylandGen. Do not edit.",
                    "Open protocol values preserve unknown future values and option bits.",
                ])
        }

        if mode == .server, let dispatchDir {
            let fm = FileManager.default
            try? fm.createDirectory(atPath: dispatchDir, withIntermediateDirectories: true)
            var ifaceVersion: [String: Int] = [:]
            for p in closure { for i in p.interfaces { ifaceVersion[i.name] = i.version } }

            var emittedFileCount = 0

            // A *pure* destructor (no new_id arg) becomes the fixed wl_resource_destroy trampoline and is
            // excluded from the handler protocol. A destructor that ALSO creates an object (the
            // builder-finalize pattern — wp_drm_lease_request_v1.submit, the color-management creators) is a
            // real typed request: the consumer needs the new handle, so it stays in the protocol and its
            // trampoline destroys `res` after the handler runs.
            func isPureDestructor(_ m: WMsg) -> Bool {
                m.isDestructor && !m.args.contains { $0.type == "new_id" }
            }
            func actorArgumentName(_ argument: WArg) -> String {
                ["object", "string", "array"].contains(argument.type)
                    ? "_request_\(argument.name)"
                    : esc(argument.name)
            }
            func actorBoundaryBindingLines(
                for request: WMsg,
                includeClient: Bool
            ) -> [String] {
                var bindings = [
                    "nonisolated(unsafe) let requestHandler = h",
                    "nonisolated(unsafe) let requestResource = unsafe res",
                ]
                if includeClient {
                    bindings.append(
                        "nonisolated(unsafe) let requestClient = unsafe client")
                }
                for argument in request.args
                where ["object", "string", "array"].contains(argument.type) {
                    let name = esc(argument.name)
                    bindings.append(
                        "nonisolated(unsafe) let \(actorArgumentName(argument)) = unsafe \(name)")
                }
                return bindings
            }
            func declaration(_ lines: [String]) -> DeclSyntax {
                DeclSyntax(stringLiteral: lines.joined(separator: "\n"))
            }
            func publicAttribute(_ name: String) -> AttributeListSyntax.Element {
                .attribute(
                    AttributeSyntax(
                        attributeName: IdentifierTypeSyntax(name: .identifier(name))))
            }
            for proto in closure {
                for iface in proto.interfaces {
                    if let only = dispatchOnly, !only.contains(iface.name) { continue }
                    // wl_display and wl_registry are the bootstrap objects libwayland implements itself: it
                    // omits their event senders + request vtables from the public headers (wayland-scanner
                    // special-cases them the same way). Their generated descriptor remains useful, but a
                    // compositor never provides their vtable or sends their events directly.
                    let isLibwaylandBootstrap =
                        iface.name == "wl_display" || iface.name == "wl_registry"
                    // Untyped new_id (bind-style, no interface) needs the (interface,version,id) triple — not
                    // handled by typed request dispatch. The interface still receives a descriptor.
                    let hasUntypedNewID = iface.requests.contains {
                        $0.args.contains { $0.type == "new_id" && $0.interface == nil }
                    }
                    let dispatchesRequests =
                        !isLibwaylandBootstrap && !hasUntypedNewID && !iface.requests.isEmpty
                    let emitsEvents = !isLibwaylandBootstrap && !iface.events.isEmpty
                    let P = upperCamel(iface.name)
                    var source = SwiftSourceFileBuilder()
                    source.addImport("WaylandServerC")
                    source.addImport("WaylandServer", public: true)
                    let usesProtocolValues =
                        iface.enumerations.contains { $0.name == "error" }
                        || (iface.requests + iface.events).contains {
                            $0.args.contains { $0.enumName != nil }
                        }
                    if usesProtocolValues {
                        source.addImport("WaylandProtocolTypes", public: true)
                    }
                    // The protocol carries EVERY request, including destructors — a destructor can have
                    // consumer semantics (ext_session_lock_v1.unlock_and_destroy unlocks the session; a
                    // `destroy` may need a protocol-error guard). Pure destructors get a default auto-destroy
                    // impl below, so a consumer that has nothing to add simply doesn't implement them.
                    func methodParams(_ r: WMsg) -> String {
                        // The request's own wl_resource is always the first handler arg (mirrors libwayland's
                        // request-handler ABI): a per-resource owner may ignore it, a shared manager owner uses
                        // it to post protocol errors / read the client & version off the resource it arrived on.
                        (["_ request: WaylandRequest<\(P)Server>"]
                            + r.args.map { "\(esc($0.name)): \(swiftParamType($0, in: iface))" })
                            .joined(separator: ", ")
                    }
                    if dispatchesRequests {
                        let requestMembers = iface.requests.map { request in
                            declaration([
                                "func \(esc(lowerCamel(request.name)))(\(methodParams(request)))"
                            ])
                        }
                        let requests = ProtocolDeclSyntax(
                            attributes: [publicAttribute("MainActor")],
                            modifiers: [DeclModifierSyntax(name: .keyword(.public))],
                            name: .identifier("\(P)Requests"),
                            inheritanceClause: InheritanceClauseSyntax {
                                InheritedTypeSyntax(
                                    type: TypeSyntax(stringLiteral: "AnyObject"))
                            }
                        ) {
                            for member in requestMembers {
                                member
                            }
                        }
                        source.add(DeclSyntax(requests))
                    }
                    // Default auto-destroy for the pure destructors (destructor requests with no new_id): the
                    // trampoline routes through the handler so an override wins, but the common case needs no code.
                    let pureDtors = iface.requests.filter { isPureDestructor($0) }
                    if dispatchesRequests && !pureDtors.isEmpty {
                        let members = pureDtors.map { request in
                            declaration([
                                "func \(esc(lowerCamel(request.name)))(\(methodParams(request))) {",
                                "    unsafe wl_resource_destroy(request.resource)",
                                "}",
                            ])
                        }
                        let defaults = try ExtensionDeclSyntax(
                            "public extension \(raw: P)Requests"
                        ) {
                            for member in members {
                                member
                            }
                        }
                        source.add(DeclSyntax(defaults))
                    }

                    var serverMembers: [DeclSyntax] = [
                        declaration([
                            "public nonisolated static let maximumVersion: Int32 = \(iface.version)"
                        ])
                    ]
                    if dispatchesRequests {
                        var vtableLines = [
                            "nonisolated(unsafe) package static let nativeRequestVtable: UnsafeRawPointer = {",
                            "    let size = MemoryLayout<swift_wayland_\(iface.name)_requests>.stride",
                            "    let raw = UnsafeMutableRawPointer.allocate(",
                            "        byteCount: size, alignment: MemoryLayout<swift_wayland_\(iface.name)_requests>.alignment)",
                            "    unsafe raw.initializeMemory(as: UInt8.self, repeating: 0, count: size)",
                            "    let vt = unsafe raw.bindMemory(to: swift_wayland_\(iface.name)_requests.self, capacity: 1)",
                        ]
                        for r in iface.requests {
                            let field =
                                cxxKeywordIdentifiers.contains(r.name)
                                ? "swift_wayland_wl_kw_\(r.name)" : r.name
                            // Escape the COMPOSED impl name (`import_impl`, not `` `import` ``+`_impl`) so a
                            // request whose name is a Swift keyword yields a valid identifier.
                            vtableLines.append(
                                "    unsafe vt.pointee.\(field) = \(esc(lowerCamel(r.name) + "_impl"))"
                            )
                        }
                        vtableLines.append(contentsOf: [
                            "    return UnsafeRawPointer(raw)",
                            "}()",
                        ])
                        serverMembers.append(declaration(vtableLines))
                    }
                    serverMembers.append(
                        declaration([
                            "public nonisolated static let descriptor = unsafe WaylandServerInterfaceDescriptor(",
                            "    nativeInterface: swift_wayland_iface_\(iface.name)(),",
                            "    nativeRequestVtable: \(dispatchesRequests ? "nativeRequestVtable" : "nil"))",
                        ]))

                    for e in emitsEvents ? iface.events : [] {
                        var sp = ["_ target: UnsafeMutablePointer<wl_resource>"]
                        var ca = ["target"]
                        for a in e.args {
                            sp.append(
                                "\(esc(a.name)): \(swiftParamType(a, in: iface, isEvent: true))")
                            switch a.type {
                            case "fixed":
                                ca.append("swift_wayland_fixed_from_double(\(esc(a.name)))")
                            case "int" where a.enumName != nil:
                                ca.append("Int32(bitPattern: \(esc(a.name)).rawValue)")
                            case "uint" where a.enumName != nil:
                                ca.append("\(esc(a.name)).rawValue")
                            // An event new_id is the server-created object's own resource — pass it straight.
                            default: ca.append(esc(a.name))
                            }
                        }
                        serverMembers.append(
                            declaration([
                                "public static func send\(upperCamel(e.name))(\(sp.joined(separator: ", "))) {",
                                "    unsafe \(iface.name)_send_\(e.name)(\(ca.joined(separator: ", ")))",
                                "}",
                            ]))
                    }

                    if dispatchesRequests {
                        serverMembers.append(
                            declaration([
                                "private static func handler(_ res: UnsafeMutablePointer<wl_resource>) -> any \(P)Requests? {",
                                "    guard let ud = unsafe wl_resource_get_user_data(res) else { return nil }",
                                "    return unsafe Unmanaged<AnyObject>.fromOpaque(ud).takeUnretainedValue() as? any \(P)Requests",
                                "}",
                            ]))
                    }

                    for r in dispatchesRequests ? iface.requests : [] {
                        let vname = esc(lowerCamel(r.name) + "_impl")
                        let cparams =
                            (["OpaquePointer?", "UnsafeMutablePointer<wl_resource>?"]
                            + r.args.map { cParamType($0) })
                            .joined(separator: ", ")
                        if isPureDestructor(r) {
                            // Route through the handler so a consumer override runs; if no owner conforms, fall
                            // back to a plain destroy (the request must always tear the resource down).
                            let extra = r.args.map {
                                ", \(requestArgumentExpression($0, in: iface))"
                            }.joined()
                            let dcp = (["_", "res"] + r.args.map { esc($0.name) }).joined(
                                separator: ", ")
                            var lines = [
                                "private static let \(vname): @convention(c) (\(cparams)) -> Void = { \(dcp) in",
                                "    guard let res = unsafe res else { return }",
                                "    if let h = unsafe handler(res) {",
                            ]
                            lines.append(
                                contentsOf: actorBoundaryBindingLines(
                                    for: r, includeClient: false
                                ).map { "        \($0)" })
                            lines.append(contentsOf: [
                                "        MainActor.assumeIsolated { unsafe requestHandler.\(esc(lowerCamel(r.name)))(WaylandRequest<\(P)Server>(requestResource)\(extra)) }",
                                "    } else {",
                                "        unsafe wl_resource_destroy(res)",
                                "    }",
                                "}",
                            ])
                            serverMembers.append(declaration(lines))
                            continue
                        }
                        let hasNewId = r.args.contains { $0.type == "new_id" }
                        let cp = ([hasNewId ? "client" : "_", "res"] + r.args.map { esc($0.name) })
                            .joined(separator: ", ")
                        var lines = [
                            "private static let \(vname): @convention(c) (\(cparams)) -> Void = { \(cp) in"
                        ]
                        if hasNewId {
                            // A new_id request arg becomes a WlNewId (client + wire id + resolved version +
                            // child interface) the handler materializes with its own owner/vtable. `client`
                            // is required to build it, so guard it non-nil.
                            var call: [String] = []
                            for a in r.args {
                                switch a.type {
                                case "new_id":
                                    let t = a.interface ?? ""
                                    call.append(
                                        "\(esc(a.name)): WlNewId<\(upperCamel(t))Server>(client: requestClient, id: \(esc(a.name)), version: Swift::min(wl_resource_get_version(requestResource), Int32(\(ifaceVersion[t] ?? 1))))"
                                    )
                                default:
                                    call.append(requestArgumentExpression(a, in: iface))
                                }
                            }
                            let args = (["WaylandRequest<\(P)Server>(requestResource)"] + call)
                                .joined(separator: ", ")
                            lines.append(
                                "    guard let res = unsafe res, let client = unsafe client, let h = unsafe handler(res) else { return }"
                            )
                            lines.append(
                                contentsOf: actorBoundaryBindingLines(
                                    for: r, includeClient: true
                                ).map { "    \($0)" })
                            lines.append(contentsOf: [
                                "    MainActor.assumeIsolated {",
                                "        unsafe requestHandler.\(esc(lowerCamel(r.name)))(\(args))",
                            ])
                            // A destructor that creates an object: tear the request resource down after the
                            // handler has taken the new id (mirrors the client-side destructor semantics).
                            if r.isDestructor {
                                lines.append(
                                    "        unsafe wl_resource_destroy(requestResource)")
                            }
                            lines.append("    }")
                        } else {
                            let call = r.args.map { requestArgumentExpression($0, in: iface) }
                            let args = (["WaylandRequest<\(P)Server>(requestResource)"] + call)
                                .joined(separator: ", ")
                            lines.append(
                                "    guard let res = unsafe res, let h = unsafe handler(res) else { return }"
                            )
                            lines.append(
                                contentsOf: actorBoundaryBindingLines(
                                    for: r, includeClient: false
                                ).map { "    \($0)" })
                            lines.append(contentsOf: [
                                "    MainActor.assumeIsolated {",
                                "        unsafe requestHandler.\(esc(lowerCamel(r.name)))(\(args))",
                                "    }",
                            ])
                        }
                        lines.append("}")
                        serverMembers.append(declaration(lines))
                    }

                    let server = EnumDeclSyntax(
                        modifiers: [DeclModifierSyntax(name: .keyword(.public))],
                        name: .identifier("\(P)Server"),
                        inheritanceClause: InheritanceClauseSyntax {
                            InheritedTypeSyntax(
                                type: TypeSyntax(
                                    stringLiteral: "WaylandServerInterface"))
                        }
                    ) {
                        for member in serverMembers {
                            member
                        }
                    }
                    source.add(DeclSyntax(server))

                    if emitsEvents {
                        var eventMembers: [DeclSyntax] = []
                        for event in iface.events where event.since > 1 {
                            let capability = "supports" + upperCamel(event.name)
                            eventMembers.append(
                                declaration([
                                    "var \(capability): Bool {",
                                    "    guard let version else { return false }",
                                    "    return version >= \(event.since)",
                                    "}",
                                ]))
                        }
                        for event in iface.events {
                            let arrayArguments = event.args.filter { $0.type == "array" }
                            let genericParameters =
                                arrayArguments.isEmpty
                                ? ""
                                : "<"
                                    + arrayArguments.map {
                                        upperCamel($0.name) + "Element"
                                    }.joined(separator: ", ") + ">"
                            let parameters = event.args.map {
                                "\(esc($0.name)): \(typedEventParamType($0, in: iface))"
                            }.joined(separator: ", ")
                            let parameterClause = parameters.isEmpty ? "" : parameters
                            var lines = [
                                "@discardableResult",
                                "func send\(upperCamel(event.name))\(genericParameters)(\(parameterClause)) -> Bool {",
                                "    guard let target = unsafe resource else { return false }",
                            ]
                            if event.since > 1 {
                                lines.append(
                                    "    precondition(supports\(upperCamel(event.name)), \"\(iface.name).\(event.name) requires version \(event.since)\")"
                                )
                            }
                            for argument in event.args
                            where ["object", "new_id"].contains(argument.type) {
                                let name = esc(argument.name)
                                let binding = "_event_\(argument.name)Resource"
                                if argument.allowNull {
                                    lines.append(contentsOf: [
                                        "    let \(binding): UnsafeMutablePointer<wl_resource>?",
                                        "    if let \(name) {",
                                        "        guard let live = unsafe \(name).resource else { return false }",
                                        "        unsafe \(binding) = live",
                                        "    } else {",
                                        "        unsafe \(binding) = nil",
                                        "    }",
                                    ])
                                } else {
                                    lines.append(
                                        "    guard let \(binding) = unsafe \(name).resource else { return false }"
                                    )
                                }
                            }

                            var callArguments = ["target"]
                            for argument in event.args {
                                let name = esc(argument.name)
                                switch argument.type {
                                case "fixed":
                                    callArguments.append("swift_wayland_fixed_from_double(\(name))")
                                case "int" where argument.enumName != nil:
                                    callArguments.append("Int32(bitPattern: \(name).rawValue)")
                                case "uint" where argument.enumName != nil:
                                    callArguments.append("\(name).rawValue")
                                case "object", "new_id":
                                    callArguments.append("_event_\(argument.name)Resource")
                                case "string":
                                    callArguments.append("_event_\(argument.name)CString")
                                case "array":
                                    callArguments.append("_event_\(argument.name)Array")
                                default:
                                    callArguments.append(name)
                                }
                            }
                            var body =
                                "unsafe \(iface.name)_send_\(event.name)(\(callArguments.joined(separator: ", ")))\n"
                                + "return true"
                            for argument in event.args.reversed() {
                                let name = esc(argument.name)
                                let indented =
                                    body
                                    .split(separator: "\n", omittingEmptySubsequences: false)
                                    .map { "    " + $0 }
                                    .joined(separator: "\n")
                                switch argument.type {
                                case "string":
                                    body =
                                        "return unsafe withWaylandEventCString(\(name)) { _event_\(argument.name)CString in\n"
                                        + indented + "\n}"
                                case "array":
                                    body =
                                        "return unsafe withWaylandEventArray(\(name)) { _event_\(argument.name)Array in\n"
                                        + indented + "\n}"
                                default:
                                    continue
                                }
                            }
                            lines.append(
                                contentsOf:
                                    body
                                    .split(separator: "\n", omittingEmptySubsequences: false)
                                    .map { "    " + $0 })
                            lines.append("}")
                            eventMembers.append(declaration(lines))

                            let createdArguments = event.args.filter {
                                $0.type == "new_id"
                                    && $0.interface != nil
                            }
                            if createdArguments.count == 1,
                                event.args.count == 1,
                                let createdInterfaceName =
                                    createdArguments[0].interface,
                                let createdInterface = closure
                                    .lazy
                                    .flatMap(\.interfaces)
                                    .first(where: {
                                        $0.name == createdInterfaceName
                                    })
                            {
                                let child = upperCamel(createdInterfaceName)
                                let childRequiresPolicyOwner =
                                    createdInterface.requests.contains {
                                        !isPureDestructor($0)
                                    }
                                let childOwnerConstraint =
                                    childRequiresPolicyOwner
                                    ? "\(child)Requests"
                                    : "AnyObject"
                                let argumentName =
                                    esc(createdArguments[0].name)
                                eventMembers.append(
                                    declaration([
                                        "@discardableResult",
                                        "func create\(upperCamel(event.name))<Owner: \(childOwnerConstraint)>(",
                                        "    owner: (WaylandResourceHandle<\(child)Server>) -> Owner?,",
                                        "    installed: (Owner) -> Void = { _ in }",
                                        ") -> Owner? {",
                                        "    WaylandResource.createChild(",
                                        "        parent: self,",
                                        "        interface: \(child)Server.self,",
                                        "        version: Swift.min(",
                                        "            version ?? 1,",
                                        "            \(child)Server.maximumVersion),",
                                        "        owner: owner,",
                                        "        installed: installed,",
                                        "        publish: {",
                                        "            send\(upperCamel(event.name))(\(argumentName): $0)",
                                        "        })",
                                        "}",
                                    ]))
                            }
                        }
                        let events = try ExtensionDeclSyntax(
                            "public extension WaylandResourceHandle where Interface == \(raw: P)Server"
                        ) {
                            for member in eventMembers {
                                member
                            }
                        }
                        source.add(DeclSyntax(events))
                    }

                    if let errorEnumeration = iface.enumerations.first(where: { $0.name == "error" }
                    ) {
                        let errorType = upperCamel(iface.name) + upperCamel(errorEnumeration.name)
                        let errors = try ExtensionDeclSyntax(
                            "public extension WaylandRequest where Interface == \(raw: P)Server"
                        ) {
                            declaration([
                                "func postError(_ code: \(errorType), message: String) {",
                                "    postError(code: code.rawValue, message: message)",
                                "}",
                            ])
                        }
                        source.add(DeclSyntax(errors))

                        let handleErrors = try ExtensionDeclSyntax(
                            "public extension WaylandResourceHandle where Interface == \(raw: P)Server"
                        ) {
                            declaration([
                                "@discardableResult",
                                "func postError(_ code: \(errorType), message: String) -> Bool {",
                                "    postError(code: code.rawValue, message: message)",
                                "}",
                            ])
                        }
                        source.add(DeclSyntax(handleErrors))
                    }

                    // Each child descriptor owns its creation API. Request-bearing resources require
                    // their owner to implement the generated request protocol. Destroy-only resources
                    // deliberately accept any owner so the generated fallback destroy path remains valid.
                    let requiresPolicyOwner =
                        dispatchesRequests
                        && iface.requests.contains { !isPureDestructor($0) }
                    let ownerConstraint =
                        requiresPolicyOwner
                        ? "\(P)Requests"
                        : "AnyObject"
                    var newIDMembers = [
                        declaration([
                            "@discardableResult",
                            "@MainActor",
                            "func create<Owner: \(ownerConstraint)>(",
                            "    owner: (WaylandResourceHandle<\(P)Server>) -> Owner?,",
                            "    installed: (Owner) -> Void = { _ in }",
                            ") -> Owner? {",
                            "    unsafe _create(vtable: \(P)Server.descriptor.nativeRequestVtable, owner: owner, installed: installed)",
                            "}",
                        ])
                    ]
                    if iface.name == "wl_callback"
                        || iface.name == "wp_presentation_feedback"
                    {
                        newIDMembers.append(
                            declaration([
                                "@discardableResult",
                                "@MainActor",
                                "func createBare() -> WaylandResourceReference<\(P)Server>? {",
                                "    _createBare()",
                                "}",
                            ]))
                    }
                    let newID = try ExtensionDeclSyntax(
                        "public extension WlNewId where Interface == \(raw: P)Server"
                    ) {
                        for member in newIDMembers {
                            member
                        }
                    }
                    source.add(DeclSyntax(newID))

                    let serverFactories = try ExtensionDeclSyntax(
                        "public extension \(raw: P)Server"
                    ) {
                        declaration([
                            "@MainActor",
                            "static func global<Implementation: AnyObject & \(ownerConstraint)>(",
                            "    implementation: Implementation,",
                            "    advertisedVersion: Int32 = maximumVersion,",
                            "    installed: @escaping (Implementation, WaylandResourceHandle<\(P)Server>) -> Void = { _, _ in }",
                            ") -> WaylandGlobalSpecification<\(P)Server> {",
                            "    unsafe WaylandGlobalSpecification(",
                            "        implementation: implementation,",
                            "        advertisedVersion: advertisedVersion,",
                            "        vtable: descriptor.nativeRequestVtable,",
                            "        owner: { implementation, _ in implementation },",
                            "        installed: { implementation, _, handle in",
                            "            installed(implementation, handle)",
                            "        })",
                            "}",
                        ])
                        declaration([
                            "@MainActor",
                            "static func global<Implementation: AnyObject, Owner: \(ownerConstraint)>(",
                            "    implementation: Implementation,",
                            "    advertisedVersion: Int32 = maximumVersion,",
                            "    owner: @escaping (Implementation, WaylandResourceHandle<\(P)Server>) -> Owner?,",
                            "    installed: @escaping (Implementation, Owner, WaylandResourceHandle<\(P)Server>) -> Void = { _, _, _ in }",
                            ") -> WaylandGlobalSpecification<\(P)Server> {",
                            "    unsafe WaylandGlobalSpecification(",
                            "        implementation: implementation,",
                            "        advertisedVersion: advertisedVersion,",
                            "        vtable: descriptor.nativeRequestVtable, owner: owner,",
                            "        installed: installed)",
                            "}",
                        ])
                    }
                    source.add(DeclSyntax(serverFactories))
                    try source.write(
                        to: "\(dispatchDir)/\(P).swift",
                        header: [
                            "Generated by SwiftWaylandGen. Do not edit.",
                            "Typed server descriptor and dispatch for \(iface.name).",
                        ])
                    emittedFileCount += 1
                }
            }

            // new_id args no longer need per-interface handle structs: request new_ids are WlNewId (from
            // WaylandServer) and event new_ids are the raw wl_resource. So there is no Handles.swift.
            FileHandle.standardError.write(
                "emitted dispatch for \(emittedFileCount) interface(s)\n"
                    .data(using: .utf8)!)
        }

        // ── Typed Swift event dispatch (client mode, opt-in via --dispatch) ─────────────────
        // The mirror of the server layer: for each interface with events, a handler protocol (one method
        // per event), the libwayland `<iface>_listener` filled with @convention(c) trampolines, retained
        // owner recovery from proxy-scoped userdata, and an installListener(_:) operation on the owned
        // proxy. Requests are sent through libwayland's own `<iface>_<request>` proxy inlines until the
        // generated request surface lands. Ordinary object event arguments remain borrowed; event new_id
        // arguments transfer an owned proxy carrying the parent's connection lifetime.
        func clientEventSwiftType(_ a: WArg, in interface: Iface) -> String {
            if let enumeration = resolvedEnumerationName(a, in: interface) {
                return enumeration
            }
            switch a.type {
            case "int": return "Int32"
            case "fd": return "consuming WaylandClientOwnedFileDescriptor"
            case "uint": return "UInt32"
            case "fixed": return "Double"
            case "string": return "String" + (a.allowNull ? "?" : "")
            case "array": return "WaylandClientArrayView" + (a.allowNull ? "?" : "")
            case "object":
                return "WaylandBorrowedProxy<\(upperCamel(a.interface ?? ""))Client>"
                    + (a.allowNull ? "?" : "")
            case "new_id":
                return "WaylandProxy<\(upperCamel(a.interface ?? ""))Client>"
                    + (a.allowNull ? "?" : "")
            default: return "UInt32"
            }
        }
        func clientEventCType(_ a: WArg) -> String {
            switch a.type {
            case "int", "fd": return "Int32"
            case "uint": return "UInt32"
            case "fixed": return "wl_fixed_t"
            case "string": return "UnsafePointer<CChar>?"
            case "array": return "UnsafeMutablePointer<wl_array>?"
            case "object", "new_id": return "OpaquePointer?"
            default: return "UInt32"
            }
        }

        func clientRequestSwiftType(_ argument: WArg, in interface: Iface) -> String {
            if let enumeration = resolvedEnumerationName(argument, in: interface) {
                return enumeration
            }
            switch argument.type {
            case "int": return "Int32"
            case "uint": return "UInt32"
            case "fixed": return "Double"
            case "string": return "String" + (argument.allowNull ? "?" : "")
            case "array":
                return "WaylandClientArrayArgument"
                    + (argument.allowNull ? "?" : "")
            case "object":
                return "WaylandProxy<\(upperCamel(argument.interface ?? ""))Client>"
                    + (argument.allowNull ? "?" : "")
            case "fd": return "consuming WaylandClientOwnedFileDescriptor"
            default: return "UInt32"
            }
        }

        func clientRequestCFunction(
            interface: Iface,
            request: WMsg
        ) -> String {
            "swift_wayland_client_request_\(interface.name)_\(request.name)"
        }

        func clientRequestCArgument(
            _ argument: WArg,
            in interface: Iface
        ) -> String {
            let name = esc(argument.name)
            if resolvedEnumerationName(argument, in: interface) != nil {
                return argument.type == "int"
                    ? "Int32(bitPattern: \(name).rawValue)"
                    : "\(name).rawValue"
            }
            switch argument.type {
            case "fixed":
                return "swift_wayland_fixed_from_double(\(name))"
            case "string":
                return "_\(name)CString"
            case "array":
                return "_\(name)Array"
            case "object":
                return "_\(name)Proxy"
            case "fd":
                return "_\(name)Descriptor"
            default:
                return name
            }
        }

        func clientRequestScopedLines(
            scopes: ArraySlice<WArg>,
            base: [String],
            resultType: String,
            indent: String = ""
        ) -> [String] {
            guard let argument = scopes.first else {
                return base.map { indent + $0 }
            }
            let remaining = scopes.dropFirst()
            let name = esc(argument.name)
            let innerIndent = indent + "    "
            let nested = clientRequestScopedLines(
                scopes: remaining,
                base: base,
                resultType: resultType,
                indent: innerIndent)
            switch argument.type {
            case "string" where argument.allowNull:
                return [
                    "\(indent)if let \(name) {",
                    "\(innerIndent)return try \(name).withCString { (_\(name)CString: UnsafePointer<CChar>) throws(WaylandProxyError) -> \(resultType) in",
                ]
                    + clientRequestScopedLines(
                        scopes: remaining,
                        base: base,
                        resultType: resultType,
                        indent: innerIndent + "    ")
                    + [
                        "\(innerIndent)}",
                        "\(indent)}",
                        "\(indent)let _\(name)CString: UnsafePointer<CChar>? = nil",
                    ]
                    + clientRequestScopedLines(
                        scopes: remaining,
                        base: base,
                        resultType: resultType,
                        indent: indent)
            case "string":
                return [
                    "\(indent)return try \(name).withCString { (_\(name)CString: UnsafePointer<CChar>) throws(WaylandProxyError) -> \(resultType) in"
                ] + nested + [
                    "\(indent)}"
                ]
            case "array" where argument.allowNull:
                return [
                    "\(indent)if let \(name) {",
                    "\(innerIndent)return try unsafe \(name).withNativeArray { (_\(name)Array: UnsafeMutablePointer<wl_array>) throws(WaylandProxyError) -> \(resultType) in",
                ]
                    + clientRequestScopedLines(
                        scopes: remaining,
                        base: base,
                        resultType: resultType,
                        indent: innerIndent + "    ")
                    + [
                        "\(innerIndent)}",
                        "\(indent)}",
                        "\(indent)let _\(name)Array: UnsafeMutablePointer<wl_array>? = nil",
                    ]
                    + clientRequestScopedLines(
                        scopes: remaining,
                        base: base,
                        resultType: resultType,
                        indent: indent)
            case "array":
                return [
                    "\(indent)return try unsafe \(name).withNativeArray { (_\(name)Array: UnsafeMutablePointer<wl_array>) throws(WaylandProxyError) -> \(resultType) in"
                ] + nested + [
                    "\(indent)}"
                ]
            default:
                return clientRequestScopedLines(
                    scopes: remaining,
                    base: base,
                    resultType: resultType,
                    indent: indent)
            }
        }

        func clientRequestDeclaration(
            _ request: WMsg,
            in interface: Iface
        ) -> [String] {
            if interface.name == "wl_registry", request.name == "bind" {
                return [
                    "func bind<Bound: WaylandClientInterface>(",
                    "    name: UInt32,",
                    "    version: UInt32,",
                    "    as _: Bound.Type",
                    ") throws(WaylandProxyError) -> WaylandProxy<Bound> {",
                    "    guard version <= Bound.maximumVersion else {",
                    "        throw .unsupportedVersion(",
                    "            required: version,",
                    "            actual: Bound.maximumVersion)",
                    "    }",
                    "    let _proxy = try unsafe requireNativeProxy()",
                    "    guard let created = unsafe wl_registry_bind(",
                    "            _proxy, name, Bound.descriptor.nativeInterface, version)",
                    "    else { throw .proxyCreationFailed }",
                    "    return unsafe makeOwnedProxy(",
                    "        adopting: OpaquePointer(created), Bound.self)",
                    "}",
                ]
            }

            let arguments = request.args.filter { $0.type != "new_id" }
            let parameters = arguments.map {
                "\(esc($0.name)): \(clientRequestSwiftType($0, in: interface))"
            }.joined(separator: ", ")
            let createdArgument = request.args.first { $0.type == "new_id" }
            let returnType =
                createdArgument.map {
                    " -> WaylandProxy<\(upperCamel($0.interface ?? ""))Client>"
                } ?? ""
            var lines = [
                "func \(esc(lowerCamel(request.name)))(\(parameters)) throws(WaylandProxyError)\(returnType) {"
            ]
            if request.since > 1 {
                lines += [
                    "    guard version >= \(request.since) else {",
                    "        throw .unsupportedVersion(",
                    "            required: \(request.since), actual: version)",
                    "    }",
                ]
            }
            lines.append("    let _proxy = try unsafe requireNativeProxy()")
            for argument in arguments where argument.type == "object" {
                let name = esc(argument.name)
                lines.append(
                    "    let _\(name)Proxy = try unsafe \(name)\(argument.allowNull ? "?" : "").requireNativeProxy()"
                )
            }
            for argument in arguments where argument.type == "fd" {
                let name = esc(argument.name)
                lines += [
                    "    let _\(name)Descriptor = \(name).take()",
                    "    defer {",
                    "        WaylandClientOwnedFileDescriptor.closeTransferred(",
                    "            _\(name)Descriptor)",
                    "    }",
                ]
            }

            let callArguments =
                (["_proxy"]
                + arguments.map {
                    clientRequestCArgument($0, in: interface)
                }).joined(separator: ", ")
            let function = clientRequestCFunction(
                interface: interface,
                request: request)
            let base: [String]
            if let createdArgument {
                let child = upperCamel(createdArgument.interface ?? "")
                base = [
                    "guard let _created = unsafe \(function)(\(callArguments)) else {",
                    "    throw WaylandProxyError.proxyCreationFailed",
                    "}",
                    "return unsafe makeOwnedProxy(",
                    "    adopting: _created, \(child)Client.self)",
                ]
            } else {
                base = [
                    "unsafe \(function)(\(callArguments))",
                    "return",
                ]
            }
            let scopes = arguments.filter {
                ["string", "array"].contains($0.type)
            }
            let scoped = clientRequestScopedLines(
                scopes: scopes[...],
                base: base,
                resultType: createdArgument.map {
                    "WaylandProxy<\(upperCamel($0.interface ?? ""))Client>"
                } ?? "Void",
                indent: request.isDestructor ? "        " : "    ")
            if request.isDestructor {
                if let createdArgument {
                    let child = upperCamel(createdArgument.interface ?? "")
                    lines +=
                        [
                            "    let _result = try { () throws(WaylandProxyError) -> WaylandProxy<\(child)Client> in"
                        ] + scoped + [
                            "    }()",
                            "    try unsafe invalidateAfterProtocolDestructor()",
                            "    return _result",
                        ]
                } else {
                    lines +=
                        [
                            "    let _send = { () throws(WaylandProxyError) -> Void in"
                        ] + scoped + [
                            "    }",
                            "    try _send()",
                            "    try unsafe invalidateAfterProtocolDestructor()",
                        ]
                }
            } else {
                lines += scoped
            }
            lines.append("}")
            return lines
        }

        if mode == .client, let dispatchDir {
            let fm = FileManager.default
            try? fm.createDirectory(atPath: dispatchDir, withIntermediateDirectories: true)
            var emittedFileCount = 0

            func clientDeclaration(_ lines: [String]) -> DeclSyntax {
                DeclSyntax(stringLiteral: lines.joined(separator: "\n"))
            }

            for proto in closure {
                for iface in proto.interfaces {
                    if let only = dispatchOnly, !only.contains(iface.name) { continue }
                    // wl_display's events (error/delete_id) are handled by libwayland's own dispatcher; a
                    // client never adds a listener to it. wl_registry IS listened to, so it stays.
                    let P = upperCamel(iface.name)
                    var source = SwiftSourceFileBuilder()
                    source.addImport("WaylandClientC")

                    let descriptor = EnumDeclSyntax(
                        modifiers: [DeclModifierSyntax(name: .keyword(.public))],
                        name: .identifier("\(P)Client"),
                        inheritanceClause: InheritanceClauseSyntax {
                            InheritedTypeSyntax(
                                type: TypeSyntax(
                                    stringLiteral: "WaylandClientInterface"))
                        }
                    ) {
                        clientDeclaration([
                            "public nonisolated static let descriptor = unsafe WaylandClientInterfaceDescriptor(",
                            "    nativeInterface: swift_wayland_iface_\(iface.name)())",
                        ])
                        clientDeclaration([
                            "public nonisolated static let maximumVersion: UInt32 = \(iface.version)"
                        ])
                    }
                    source.add(DeclSyntax(descriptor))

                    if (iface.requests + iface.events).flatMap(\.args).contains(where: {
                        resolvedEnumerationName($0, in: iface) != nil
                    }) {
                        source.addImport("WaylandProtocolTypes", public: true)
                    }
                    if !iface.requests.isEmpty {
                        let requestMembers = iface.requests.map {
                            clientDeclaration(
                                clientRequestDeclaration($0, in: iface))
                        }
                        let requests = try ExtensionDeclSyntax(
                            "public extension WaylandProxy where Interface == \(raw: P)Client"
                        ) {
                            for member in requestMembers {
                                member
                            }
                        }
                        source.add(DeclSyntax(requests))
                    }

                    if iface.events.isEmpty || iface.name == "wl_display" {
                        try source.write(
                            to: "\(dispatchDir)/\(P).swift",
                            header: [
                                "Generated by SwiftWaylandGen. Do not edit.",
                                "Typed client descriptor and event dispatch for \(iface.name).",
                            ])
                        emittedFileCount += 1
                        continue
                    }
                    let eventMembers = iface.events.map { event in
                        let params =
                            (["_ proxy: WaylandBorrowedProxy<\(P)Client>"]
                            + event.args.map {
                                "\(esc($0.name)): \(clientEventSwiftType($0, in: iface))"
                            }).joined(separator: ", ")
                        return "    func \(esc(lowerCamel(event.name)))(\(params))"
                    }
                    source.add(
                        clientDeclaration(
                            [
                                "@MainActor",
                                "public protocol \(P)Events: AnyObject {",
                            ] + eventMembers + ["}"]))

                    var listenerLines = [
                        "nonisolated(unsafe) static let listener: UnsafeMutablePointer<\(iface.name)_listener> = {",
                        "    let p = UnsafeMutablePointer<\(iface.name)_listener>.allocate(capacity: 1)",
                        "    unsafe p.initialize(to: \(iface.name)_listener())",
                    ]
                    for e in iface.events {
                        let field =
                            cxxKeywordIdentifiers.contains(e.name)
                            ? "swift_wayland_wl_kw_\(e.name)" : e.name
                        listenerLines.append(
                            "    unsafe p.pointee.\(field) = \(esc(lowerCamel(e.name) + "_impl"))")
                    }
                    listenerLines.append(contentsOf: [
                        "    return unsafe p",
                        "}()",
                    ])
                    var clientMembers: [DeclSyntax] = [
                        clientDeclaration(listenerLines),
                        clientDeclaration([
                            "private static func handler(_ context: WaylandClientListenerContext) -> any \(P)Events? {",
                            "    context.owner as? any \(P)Events",
                            "}",
                        ]),
                    ]

                    for e in iface.events {
                        let vname = esc(lowerCamel(e.name) + "_impl")
                        let cparams =
                            (["UnsafeMutableRawPointer?", "OpaquePointer?"]
                            + e.args.map { clientEventCType($0) }).joined(separator: ", ")
                        let cp = (["data", "proxy"] + e.args.map { esc($0.name) }).joined(
                            separator: ", ")
                        let call = e.args.map { argument in
                            let label = esc(argument.name)
                            let needsUnsafeAlias = [
                                "string", "array", "object", "new_id",
                            ].contains(argument.type)
                            let name =
                                needsUnsafeAlias
                                ? "_event_\(label)"
                                : label
                            let value: String
                            if let enumeration = resolvedEnumerationName(
                                argument, in: iface)
                            {
                                value =
                                    argument.type == "int"
                                    ? "\(enumeration)(rawValue: UInt32(bitPattern: \(name)))"
                                    : "\(enumeration)(rawValue: \(name))"
                            } else {
                                switch argument.type {
                                case "fixed":
                                    value = "swift_wayland_fixed_to_double(\(name))"
                                case "string":
                                    value =
                                        argument.allowNull
                                        ? "\(name).map { unsafe String(cString: $0) }"
                                        : "unsafe String(cString: \(name)!)"
                                case "array":
                                    value =
                                        argument.allowNull
                                        ? "\(name) == nil ? nil : .some(WaylandClientArrayView(\(name)!))"
                                        : "WaylandClientArrayView(\(name)!)"
                                case "object":
                                    let type = upperCamel(argument.interface ?? "")
                                    value =
                                        argument.allowNull
                                        ? "\(name) == nil ? nil : .some(WaylandBorrowedProxy<\(type)Client>(\(name)!))"
                                        : "WaylandBorrowedProxy<\(type)Client>(\(name)!)"
                                case "new_id":
                                    let type = upperCamel(argument.interface ?? "")
                                    value =
                                        argument.allowNull
                                        ? "\(name) == nil ? nil : .some(WaylandProxy<\(type)Client>(adopting: \(name)!, connectionLifetime: listenerContext.connectionLifetime))"
                                        : "WaylandProxy<\(type)Client>(adopting: \(name)!, connectionLifetime: listenerContext.connectionLifetime)"
                                case "fd":
                                    value = "WaylandClientOwnedFileDescriptor(\(name))"
                                default:
                                    value = name
                                }
                            }
                            return "\(label): \(value)"
                        }
                        let args =
                            ([
                                "WaylandBorrowedProxy<\(P)Client>(eventProxy)"
                            ] + call)
                            .joined(separator: ", ")
                        let isolatedArguments: [String] = e.args.compactMap {
                            guard
                                [
                                    "string", "array", "object", "new_id",
                                ].contains($0.type)
                            else {
                                return nil
                            }
                            return
                                "    nonisolated(unsafe) let _event_\(esc($0.name)) = unsafe \(esc($0.name))"
                        }
                        clientMembers.append(
                            clientDeclaration(
                                [
                                    "private static let \(vname): @convention(c) (\(cparams)) -> Void = { \(cp) in",
                                    "    guard let data = unsafe data, let proxy = unsafe proxy else { return }",
                                    "    let listenerContext = unsafe WaylandClientListenerContext.recover(data)",
                                    "    guard let h = handler(listenerContext) else { return }",
                                    "    nonisolated(unsafe) let eventHandler = h",
                                    "    nonisolated(unsafe) let eventProxy = unsafe proxy",
                                    "    nonisolated(unsafe) let eventContext = listenerContext",
                                ] + isolatedArguments + [
                                    "    MainActor.assumeIsolated {",
                                    "        unsafe eventHandler.\(esc(lowerCamel(e.name)))(\(args.replacingOccurrences(of: "listenerContext", with: "eventContext")))",
                                    "    }",
                                    "}",
                                ]))
                    }

                    let dispatch = try ExtensionDeclSyntax(
                        "public extension \(raw: P)Client"
                    ) {
                        for member in clientMembers {
                            member
                        }
                    }
                    source.add(DeclSyntax(dispatch))
                    source.add(
                        clientDeclaration([
                            "public extension WaylandProxy where Interface == \(P)Client {",
                            "    func installListener(_ owner: any \(P)Events) throws(WaylandProxyError) {",
                            "        try unsafe installListener(owner: owner) { proxy, data in",
                            "            unsafe \(iface.name)_add_listener(proxy, \(P)Client.listener, data)",
                            "        }",
                            "    }",
                            "}",
                        ]))
                    try source.write(
                        to: "\(dispatchDir)/\(P).swift",
                        header: [
                            "Generated by SwiftWaylandGen. Do not edit.",
                            "Typed client descriptor and event dispatch for \(iface.name).",
                        ])
                    emittedFileCount += 1
                }
            }
            FileHandle.standardError.write(
                "emitted client dispatch for \(emittedFileCount) interface(s)\n"
                    .data(using: .utf8)!)
        }
    }

    public static func resolveClosure(
        selected: [WaylandProtocol],
        searchDirectories: [String]
    ) throws -> [WaylandProtocol] {
        var index: [String: String] = [:]
        let fileManager = FileManager.default
        for directory in searchDirectories {
            guard let enumerator = fileManager.enumerator(atPath: directory) else { continue }
            for case let relativePath as String in enumerator where relativePath.hasSuffix(".xml") {
                let path = directory + "/" + relativePath
                let protocolDocument = try parseProtocol(path)
                for interface in protocolDocument.defines where index[interface] == nil {
                    index[interface] = path
                }
            }
        }

        var closure = selected
        var closureNames = Set(selected.map(\.name))
        var allDefined = Set(selected.flatMap(\.defines))
        var worklist = selected
        while let protocolDocument = worklist.popLast() {
            for reference in protocolDocument.references where !allDefined.contains(reference) {
                guard let dependencyPath = index[reference] else {
                    throw WaylandGeneratorDiagnostic(
                        path: protocolDocument.xmlPath,
                        context: reference,
                        problem:
                            "referenced interface is not defined by the selected closure or search directories"
                    )
                }
                let dependency = try parseProtocol(dependencyPath)
                guard !closureNames.contains(dependency.name), !dependency.name.isEmpty else {
                    continue
                }
                closure.append(dependency)
                closureNames.insert(dependency.name)
                allDefined.formUnion(dependency.defines)
                worklist.append(dependency)
            }
        }
        return closure
    }

    public static func validate(protocols: [WaylandProtocol]) throws {
        let supportedArgumentTypes: Set<String> = [
            "int", "uint", "fixed", "string", "object", "new_id", "array", "fd",
        ]
        var interfaces: [String: (protocolDocument: WaylandProtocol, interface: WaylandInterface)] =
            [:]
        var generatedNames: [String: String] = [:]

        for protocolDocument in protocols {
            for interface in protocolDocument.interfaces {
                if interfaces[interface.name] != nil {
                    throw WaylandGeneratorDiagnostic(
                        path: protocolDocument.xmlPath,
                        context: interface.name,
                        problem: "interface is defined more than once")
                }
                interfaces[interface.name] = (protocolDocument, interface)

                let generatedName = swiftTypeName(interface.name)
                if let existing = generatedNames[generatedName] {
                    throw WaylandGeneratorDiagnostic(
                        path: protocolDocument.xmlPath,
                        context: interface.name,
                        problem: "generated Swift name '\(generatedName)' collides with \(existing)"
                    )
                }
                generatedNames[generatedName] = interface.name
            }
        }

        for protocolDocument in protocols {
            for interface in protocolDocument.interfaces {
                let enumerationNames = Set(interface.enumerations.map(\.name))
                for enumeration in interface.enumerations {
                    for entry in enumeration.entries where !isSupportedEnumValue(entry.value) {
                        throw WaylandGeneratorDiagnostic(
                            path: protocolDocument.xmlPath,
                            context: "\(interface.name).\(enumeration.name).\(entry.name)",
                            problem: "unsupported enum value expression '\(entry.value)'")
                    }
                }

                for (messageKind, messages) in [
                    ("request", interface.requests),
                    ("event", interface.events),
                ] {
                    for message in messages {
                        for argument in message.arguments {
                            let context = "\(interface.name).\(message.name).\(argument.name)"
                            guard supportedArgumentTypes.contains(argument.type) else {
                                throw WaylandGeneratorDiagnostic(
                                    path: protocolDocument.xmlPath,
                                    context: context,
                                    problem:
                                        "unsupported \(messageKind) argument type '\(argument.type)'"
                                )
                            }
                            if argument.type == "new_id", argument.interface == nil,
                                !(interface.name == "wl_registry" && message.name == "bind")
                            {
                                throw WaylandGeneratorDiagnostic(
                                    path: protocolDocument.xmlPath,
                                    context: context,
                                    problem: "untyped new_id is supported only for wl_registry.bind"
                                )
                            }
                            guard let enumReference = argument.enumName else { continue }
                            let components = enumReference.split(
                                separator: ".", omittingEmptySubsequences: false)
                            let enumInterface: String
                            let enumName: String
                            switch components.count {
                            case 1:
                                enumInterface = interface.name
                                enumName = String(components[0])
                            case 2:
                                enumInterface = String(components[0])
                                enumName = String(components[1])
                            default:
                                throw WaylandGeneratorDiagnostic(
                                    path: protocolDocument.xmlPath,
                                    context: context,
                                    problem: "invalid enum reference '\(enumReference)'")
                            }

                            guard let targetInterface = interfaces[enumInterface]?.interface,
                                targetInterface.enumerations.contains(where: { $0.name == enumName }
                                )
                            else {
                                let localExists =
                                    enumInterface == interface.name
                                    && enumerationNames.contains(enumName)
                                guard localExists else {
                                    throw WaylandGeneratorDiagnostic(
                                        path: protocolDocument.xmlPath,
                                        context: context,
                                        problem: "unresolved enum reference '\(enumReference)'")
                                }
                                continue
                            }
                            guard argument.type == "int" || argument.type == "uint" else {
                                throw WaylandGeneratorDiagnostic(
                                    path: protocolDocument.xmlPath,
                                    context: context,
                                    problem:
                                        "enum reference is attached to non-integer type '\(argument.type)'"
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private static func swiftTypeName(_ name: String) -> String {
        name.split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined()
    }

    private static func isSupportedEnumValue(_ value: String) -> Bool {
        if value.hasPrefix("0x") {
            return value.count > 2 && value.dropFirst(2).allSatisfy(\.isHexDigit)
        }
        return !value.isEmpty && value.allSatisfy(\.isNumber)
    }
}
