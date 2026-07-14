import Foundation
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

struct WArg {
    let name: String
    let type: String          // int | uint | fixed | string | object | new_id | array | fd
    let interface: String?    // for object / new_id
    let allowNull: Bool
    let enumName: String?
}
struct WMsg {
    let name: String
    let isDestructor: Bool
    var args: [WArg] = []
}
struct Iface {
    let name: String
    let version: Int
    var requestCount: Int = 0
    var requests: [WMsg] = []
    var events: [WMsg] = []
}
struct Proto {
    var name = ""
    var xmlPath = ""
    var interfaces: [Iface] = []
    var defines: Set<String> = []      // interfaces this protocol defines
    var references: Set<String> = []   // interfaces referenced in message args
}

final class ProtoParser: NSObject, XMLParserDelegate {
    var proto = Proto()
    private enum Scope { case none, request, event }
    private var scope: Scope = .none
    private var li: Int { proto.interfaces.count - 1 }
    func parser(_ p: XMLParser, didStartElement el: String, namespaceURI: String?,
                qualifiedName: String?, attributes attrs: [String: String]) {
        switch el {
        case "protocol": proto.name = attrs["name"] ?? ""
        case "interface":
            proto.interfaces.append(Iface(name: attrs["name"] ?? "",
                                          version: Int(attrs["version"] ?? "1") ?? 1))
            proto.defines.insert(attrs["name"] ?? "")
        case "request":
            guard li >= 0 else { break }
            proto.interfaces[li].requestCount += 1
            proto.interfaces[li].requests.append(
                WMsg(name: attrs["name"] ?? "", isDestructor: attrs["type"] == "destructor"))
            scope = .request
        case "event":
            guard li >= 0 else { break }
            proto.interfaces[li].events.append(WMsg(name: attrs["name"] ?? "", isDestructor: false))
            scope = .event
        case "arg":
            if let iface = attrs["interface"] { proto.references.insert(iface) }
            guard li >= 0 else { break }
            let arg = WArg(name: attrs["name"] ?? "", type: attrs["type"] ?? "",
                           interface: attrs["interface"], allowNull: attrs["allow-null"] == "true",
                           enumName: attrs["enum"])
            switch scope {
            case .request:
                let ri = proto.interfaces[li].requests.count - 1
                if ri >= 0 { proto.interfaces[li].requests[ri].args.append(arg) }
            case .event:
                let ei = proto.interfaces[li].events.count - 1
                if ei >= 0 { proto.interfaces[li].events[ei].args.append(arg) }
            case .none: break
            }
        default: break
        }
    }
    func parser(_ p: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName: String?) {
        if el == "request" || el == "event" { scope = .none }
    }
}

func parseProtocol(_ path: String) -> Proto {
    let d = ProtoParser()
    let parser = XMLParser(data: FileManager.default.contents(atPath: path) ?? Data())
    parser.delegate = d
    _ = parser.parse()
    d.proto.xmlPath = path
    return d.proto
}

// ── Parse args: --mode X --module Y [--search-dir D...] <out_dir> <xml...> ───────
var mode: Mode?
var module: String?
var searchDirs: [String] = []
var positional: [String] = []
var dispatchDir: String?          // emit typed Swift dispatch here (server mode)
var dispatchOnly: Set<String>?    // restrict dispatch emission to these interfaces
var it = CommandLine.arguments.dropFirst().makeIterator()
while let a = it.next() {
    switch a {
    case "--mode": mode = it.next().flatMap(Mode.init(rawValue:))
    case "--module": module = it.next()
    case "--search-dir": if let d = it.next() { searchDirs.append(d) }
    case "--dispatch": dispatchDir = it.next()
    case "--dispatch-only": dispatchOnly = it.next().map { Set($0.split(separator: ",").map(String.init)) }
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
let selected = positional[1...].map(parseProtocol)

// ── Index the search dirs (interface name → defining XML) and compute the closure ──
func indexSearchDirs(_ dirs: [String]) -> [String: String] {
    var index: [String: String] = [:]
    let fm = FileManager.default
    for dir in dirs {
        guard let e = fm.enumerator(atPath: dir) else { continue }
        for case let rel as String in e where rel.hasSuffix(".xml") {
            let path = dir + "/" + rel
            for iface in parseProtocol(path).defines where index[iface] == nil {
                index[iface] = path
            }
        }
    }
    return index
}

let index = searchDirs.isEmpty ? [:] : indexSearchDirs(searchDirs)
var closure = selected
var closureNames = Set(selected.map { $0.name })
var allDefined = Set(selected.flatMap { $0.defines })
var worklist = selected
while let proto = worklist.popLast() {
    for ref in proto.references where !allDefined.contains(ref) {
        // A referenced interface not defined by the closure. If a search-dir protocol defines
        // it, pull that protocol in (transitively). Otherwise it's either a core wl_* (defined
        // by wayland.xml/libwayland) or a genuine miss that surfaces as a link error, as before.
        guard let depPath = index[ref] else { continue }
        let dep = parseProtocol(depPath)
        guard !closureNames.contains(dep.name), !dep.name.isEmpty else { continue }
        closure.append(dep)
        closureNames.insert(dep.name)
        allDefined.formUnion(dep.defines)
        worklist.append(dep)
    }
}

let base = mode == .server ? "wayland-server.h" : "wayland-client.h"
let protoSuffix = mode == .server ? "server-protocol.h" : "client-protocol.h"
let guardMacro = module.uppercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }
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
let cxxKeywordIdentifiers = ["namespace", "export", "import", "class", "new", "delete", "template",
                             "operator", "this", "private", "public", "protected", "virtual",
                             "friend", "typename", "register"]
var emittedGuard = false
for proto in closure where proto.name != "wayland" {
    if !emittedGuard {
        for kw in cxxKeywordIdentifiers { out += "#define \(kw) swift_wayland_wl_kw_\(kw)\n" }
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


/* Interface-descriptor accessors — the client binds/creates by &<name>_interface; the server
 * reads them for globals. Expose each as a plain accessor so Swift gets a clean pointer. */

"""
for proto in closure {
    for iface in proto.interfaces {
        out += "static inline const struct wl_interface *swift_wayland_iface_\(iface.name)(void) { return &\(iface.name)_interface; }\n"
    }
}

if mode == .server {
    out += "\n/* Request-handler vtable typedefs (non-colliding names for Swift). */\n"
    for proto in closure {
        for iface in proto.interfaces where iface.requestCount > 0 {
            out += "typedef struct \(iface.name)_interface swift_wayland_\(iface.name)_requests;\n"
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
try (manifest + "\n").write(toFile: "\(outDir)/generated-protocols.tsv", atomically: true, encoding: .utf8)

// ── Typed Swift dispatch emission (server mode, opt-in via --dispatch) ─────────────
// For each dispatchable interface: a handler protocol (one method per non-destructor request), the
// request vtable + owner recovery + arg marshalling, and typed event senders. Object args pass as
// raw wl_resource* (their Swift owner type is consumer-defined); new_id args arrive as a typed
// handle the layer creates; scalars/wl_fixed marshal to Swift types. Consumers conform their model
// to <Iface>Requests — pure policy — and never write a trampoline.

func lowerCamel(_ s: String) -> String {
    let parts = s.split(separator: "_").map(String.init)
    guard let first = parts.first else { return s }
    return first + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
}
func upperCamel(_ s: String) -> String {
    s.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
}
let swiftKeywords: Set<String> = ["import", "class", "enum", "struct", "protocol", "func", "var",
    "let", "return", "in", "default", "operator", "private", "public", "internal", "case", "switch",
    "for", "while", "repeat", "if", "else", "guard", "defer", "do", "throw", "throws", "try", "as",
    "is", "nil", "true", "false", "self", "init", "deinit", "subscript", "extension", "where"]
func esc(_ s: String) -> String { swiftKeywords.contains(s) ? "`\(s)`" : s }

// Swift type of a request/event arg in the handler protocol / event sender. A new_id differs by
// direction: a *request* new_id is an object the client is asking the server to create — delivered
// as a WlNewId the consumer materializes; an *event* new_id is an object the server has ALREADY
// created and is announcing — passed as its live wl_resource.
func swiftParamType(_ a: WArg, isEvent: Bool = false) -> String {
    switch a.type {
    case "int", "fd": return "Int32"
    case "uint": return "UInt32"
    case "fixed": return "Double"
    case "object": return "UnsafeMutablePointer<wl_resource>?"
    case "string": return "UnsafePointer<CChar>?"
    case "array": return "UnsafeMutablePointer<wl_array>?"
    case "new_id": return isEvent ? "UnsafeMutablePointer<wl_resource>?" : "WlNewId"
    default: return "UInt32"
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

if mode == .server, let dispatchDir {
    let fm = FileManager.default
    try? fm.createDirectory(atPath: dispatchDir, withIntermediateDirectories: true)
    var ifaceVersion: [String: Int] = [:]
    for p in closure { for i in p.interfaces { ifaceVersion[i.name] = i.version } }

    var files: [(name: String, body: String)] = []

    // A *pure* destructor (no new_id arg) becomes the fixed wl_resource_destroy trampoline and is
    // excluded from the handler protocol. A destructor that ALSO creates an object (the
    // builder-finalize pattern — wp_drm_lease_request_v1.submit, the color-management creators) is a
    // real typed request: the consumer needs the new handle, so it stays in the protocol and its
    // trampoline destroys `res` after the handler runs.
    func isPureDestructor(_ m: WMsg) -> Bool {
        m.isDestructor && !m.args.contains { $0.type == "new_id" }
    }
    for proto in closure {
        for iface in proto.interfaces {
            let reqs = iface.requests.filter { !isPureDestructor($0) }
            if reqs.isEmpty { continue }
            if let only = dispatchOnly, !only.contains(iface.name) { continue }
            // wl_display and wl_registry are the bootstrap objects libwayland implements itself: it
            // omits their event senders + request vtables from the public headers (wayland-scanner
            // special-cases them the same way). A compositor never provides a vtable for either.
            if iface.name == "wl_display" || iface.name == "wl_registry" { continue }
            // Untyped new_id (bind-style, no interface) needs the (interface,version,id) triple — not
            // yet handled; skip such interfaces (rare, client-side: wl_registry).
            if iface.requests.contains(where: { $0.args.contains { $0.type == "new_id" && $0.interface == nil } }) {
                continue
            }
            let P = upperCamel(iface.name)
            var s = """
            // Generated by SwiftWaylandGen. Do not edit.
            //
            // Typed server dispatch for \(iface.name): a handler protocol (one method per request), the
            // request vtable + owner recovery + arg marshalling, and typed event senders.

            import WaylandServerC
            import WaylandServer

            public protocol \(P)Requests: AnyObject {

            """
            // The protocol carries EVERY request, including destructors — a destructor can have
            // consumer semantics (ext_session_lock_v1.unlock_and_destroy unlocks the session; a
            // `destroy` may need a protocol-error guard). Pure destructors get a default auto-destroy
            // impl below, so a consumer that has nothing to add simply doesn't implement them.
            func methodParams(_ r: WMsg) -> String {
                // The request's own wl_resource is always the first handler arg (mirrors libwayland's
                // request-handler ABI): a per-resource owner may ignore it, a shared manager owner uses
                // it to post protocol errors / read the client & version off the resource it arrived on.
                (["_ resource: UnsafeMutablePointer<wl_resource>"]
                    + r.args.map { "\(esc($0.name)): \(swiftParamType($0))" }).joined(separator: ", ")
            }
            for r in iface.requests {
                s += "    func \(esc(lowerCamel(r.name)))(\(methodParams(r)))\n"
            }
            s += "}\n\n"
            // Default auto-destroy for the pure destructors (destructor requests with no new_id): the
            // trampoline routes through the handler so an override wins, but the common case needs no code.
            let pureDtors = iface.requests.filter { isPureDestructor($0) }
            if !pureDtors.isEmpty {
                s += "public extension \(P)Requests {\n"
                for r in pureDtors {
                    s += "    func \(esc(lowerCamel(r.name)))(\(methodParams(r))) { wl_resource_destroy(resource) }\n"
                }
                s += "}\n\n"
            }
            s += "public enum \(P)Server {\n"
            s += "    public nonisolated(unsafe) static let vtable: UnsafeRawPointer = {\n"
            s += "        let size = MemoryLayout<swift_wayland_\(iface.name)_requests>.stride\n"
            s += "        let raw = UnsafeMutableRawPointer.allocate(\n"
            s += "            byteCount: size, alignment: MemoryLayout<swift_wayland_\(iface.name)_requests>.alignment)\n"
            s += "        raw.initializeMemory(as: UInt8.self, repeating: 0, count: size)\n"
            s += "        let vt = raw.bindMemory(to: swift_wayland_\(iface.name)_requests.self, capacity: 1)\n"
            for r in iface.requests {
                let field = cxxKeywordIdentifiers.contains(r.name) ? "swift_wayland_wl_kw_\(r.name)" : r.name
                // Escape the COMPOSED impl name (`import_impl`, not `` `import` ``+`_impl`) so a
                // request whose name is a Swift keyword yields a valid identifier.
                s += "        vt.pointee.\(field) = \(esc(lowerCamel(r.name) + "_impl"))\n"
            }
            s += "        return UnsafeRawPointer(raw)\n    }()\n\n"

            for e in iface.events {
                var sp = ["_ target: UnsafeMutablePointer<wl_resource>"]
                var ca = ["target"]
                for a in e.args {
                    sp.append("\(esc(a.name)): \(swiftParamType(a, isEvent: true))")
                    switch a.type {
                    case "fixed": ca.append("swift_wayland_fixed_from_double(\(esc(a.name)))")
                    // An event new_id is the server-created object's own resource — pass it straight.
                    default: ca.append(esc(a.name))
                    }
                }
                s += "    public static func send\(upperCamel(e.name))(\(sp.joined(separator: ", "))) {\n"
                s += "        \(iface.name)_send_\(e.name)(\(ca.joined(separator: ", ")))\n    }\n"
            }
            if !iface.events.isEmpty { s += "\n" }

            s += "    private static func handler(_ res: UnsafeMutablePointer<wl_resource>) -> \(P)Requests? {\n"
            s += "        guard let ud = wl_resource_get_user_data(res) else { return nil }\n"
            s += "        return Unmanaged<AnyObject>.fromOpaque(ud).takeUnretainedValue() as? \(P)Requests\n    }\n\n"

            for r in iface.requests {
                let vname = esc(lowerCamel(r.name) + "_impl")
                let cparams = (["OpaquePointer?", "UnsafeMutablePointer<wl_resource>?"] + r.args.map { cParamType($0) })
                    .joined(separator: ", ")
                if isPureDestructor(r) {
                    // Route through the handler so a consumer override runs; if no owner conforms, fall
                    // back to a plain destroy (the request must always tear the resource down).
                    let extra = r.args.map { ", \(esc($0.name)): \(esc($0.name))" }.joined()
                    let dcp = (["_", "res"] + r.args.map { esc($0.name) }).joined(separator: ", ")
                    s += "    private static let \(vname): @convention(c) (\(cparams)) -> Void = { \(dcp) in\n"
                    s += "        guard let res else { return }\n"
                    s += "        if let h = handler(res) { h.\(esc(lowerCamel(r.name)))(res\(extra)) } else { wl_resource_destroy(res) }\n    }\n"
                    continue
                }
                let hasNewId = r.args.contains { $0.type == "new_id" }
                let cp = ([hasNewId ? "client" : "_", "res"] + r.args.map { esc($0.name) }).joined(separator: ", ")
                s += "    private static let \(vname): @convention(c) (\(cparams)) -> Void = { \(cp) in\n"
                if hasNewId {
                    // A new_id request arg becomes a WlNewId (client + wire id + resolved version +
                    // child interface) the handler materializes with its own owner/vtable. `client`
                    // is required to build it, so guard it non-nil.
                    var call: [String] = []
                    for a in r.args {
                        switch a.type {
                        case "new_id":
                            let t = a.interface ?? ""
                            call.append("\(esc(a.name)): WlNewId(client: client, id: \(esc(a.name)), version: Swift.min(wl_resource_get_version(res), Int32(\(ifaceVersion[t] ?? 1))), interface: swift_wayland_iface_\(t)())")
                        case "fixed": call.append("\(esc(a.name)): swift_wayland_fixed_to_double(\(esc(a.name)))")
                        default: call.append("\(esc(a.name)): \(esc(a.name))")
                        }
                    }
                    let args = (["res"] + call).joined(separator: ", ")
                    s += "        guard let res, let client, let h = handler(res) else { return }\n"
                    s += "        h.\(esc(lowerCamel(r.name)))(\(args))\n"
                    // A destructor that creates an object: tear the request resource down after the
                    // handler has taken the new id (mirrors the client-side destructor semantics).
                    if r.isDestructor { s += "        wl_resource_destroy(res)\n" }
                    s += "    }\n"
                } else {
                    let call = r.args.map {
                        $0.type == "fixed" ? "\(esc($0.name)): swift_wayland_fixed_to_double(\(esc($0.name)))"
                                           : "\(esc($0.name)): \(esc($0.name))"
                    }
                    let args = (["res"] + call).joined(separator: ", ")
                    s += "        guard let res, let h = handler(res) else { return }\n"
                    s += "        h.\(esc(lowerCamel(r.name)))(\(args))\n    }\n"
                }
            }
            s += "}\n"
            files.append((name: P, body: s))
        }
    }

    // new_id args no longer need per-interface handle structs: request new_ids are WlNewId (from
    // WaylandServer) and event new_ids are the raw wl_resource. So there is no Handles.swift.
    for f in files { try? f.body.write(toFile: "\(dispatchDir)/\(f.name).swift", atomically: true, encoding: .utf8) }
    FileHandle.standardError.write("emitted dispatch for \(files.count) interface(s)\n".data(using: .utf8)!)
}

// ── Typed Swift event dispatch (client mode, opt-in via --dispatch) ─────────────────
// The mirror of the server layer: for each interface with events, a handler protocol (one method
// per event), the libwayland `<iface>_listener` filled with @convention(c) trampolines, owner
// recovery from the proxy's user_data, and an addListener(_:owner:) that wires it. Requests are sent
// through libwayland's own `<iface>_<request>` proxy inlines, so this emits no senders. Client
// proxies import as OpaquePointer; a proxy/new_id/object event arg is delivered as that pointer.
func clientEventSwiftType(_ a: WArg) -> String {
    switch a.type {
    case "int", "fd": return "Int32"
    case "uint": return "UInt32"
    case "fixed": return "Double"
    case "string": return "UnsafePointer<CChar>?"
    case "array": return "UnsafeMutablePointer<wl_array>?"
    case "object", "new_id": return "OpaquePointer?"   // a wl_proxy
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

if mode == .client, let dispatchDir {
    let fm = FileManager.default
    try? fm.createDirectory(atPath: dispatchDir, withIntermediateDirectories: true)
    var files: [(name: String, body: String)] = []

    for proto in closure {
        for iface in proto.interfaces {
            if iface.events.isEmpty { continue }
            if let only = dispatchOnly, !only.contains(iface.name) { continue }
            // wl_display's events (error/delete_id) are handled by libwayland's own dispatcher; a
            // client never adds a listener to it. wl_registry IS listened to, so it stays.
            if iface.name == "wl_display" { continue }

            let P = upperCamel(iface.name)
            var s = """
            // Generated by SwiftWaylandGen. Do not edit.
            //
            // Typed client dispatch for \(iface.name): a handler protocol (one method per event), the
            // libwayland listener + owner recovery + arg marshalling, and an addListener that wires it.

            import WaylandClientC

            public protocol \(P)Events: AnyObject {

            """
            for e in iface.events {
                let params = (["_ proxy: OpaquePointer"]
                    + e.args.map { "\(esc($0.name)): \(clientEventSwiftType($0))" }).joined(separator: ", ")
                s += "    func \(esc(lowerCamel(e.name)))(\(params))\n"
            }
            s += "}\n\npublic enum \(P)Client {\n"
            s += "    public nonisolated(unsafe) static let listener: UnsafeMutablePointer<\(iface.name)_listener> = {\n"
            s += "        let p = UnsafeMutablePointer<\(iface.name)_listener>.allocate(capacity: 1)\n"
            s += "        p.initialize(to: \(iface.name)_listener())\n"
            for e in iface.events {
                let field = cxxKeywordIdentifiers.contains(e.name) ? "swift_wayland_wl_kw_\(e.name)" : e.name
                s += "        p.pointee.\(field) = \(esc(lowerCamel(e.name) + "_impl"))\n"
            }
            s += "        return p\n    }()\n\n"
            s += "    /// Wire the listener to a proxy. The owner is borrowed (unretained) — the caller must\n"
            s += "    /// keep it alive for the proxy's lifetime, matching libwayland's user_data contract.\n"
            s += "    @discardableResult\n"
            s += "    public static func addListener(_ proxy: OpaquePointer, owner: AnyObject) -> Int32 {\n"
            s += "        \(iface.name)_add_listener(proxy, listener, Unmanaged.passUnretained(owner).toOpaque())\n    }\n\n"

            s += "    private static func handler(_ data: UnsafeMutableRawPointer) -> \(P)Events? {\n"
            s += "        Unmanaged<AnyObject>.fromOpaque(data).takeUnretainedValue() as? \(P)Events\n    }\n\n"

            for e in iface.events {
                let vname = esc(lowerCamel(e.name) + "_impl")
                let cparams = (["UnsafeMutableRawPointer?", "OpaquePointer?"]
                    + e.args.map { clientEventCType($0) }).joined(separator: ", ")
                let cp = (["data", "proxy"] + e.args.map { esc($0.name) }).joined(separator: ", ")
                let call = e.args.map {
                    $0.type == "fixed" ? "\(esc($0.name)): swift_wayland_fixed_to_double(\(esc($0.name)))"
                                       : "\(esc($0.name)): \(esc($0.name))"
                }
                let args = (["proxy"] + call).joined(separator: ", ")
                s += "    private static let \(vname): @convention(c) (\(cparams)) -> Void = { \(cp) in\n"
                s += "        guard let data, let proxy, let h = handler(data) else { return }\n"
                s += "        h.\(esc(lowerCamel(e.name)))(\(args))\n    }\n"
            }
            s += "}\n"
            files.append((name: P, body: s))
        }
    }
    for f in files { try? f.body.write(toFile: "\(dispatchDir)/\(f.name).swift", atomically: true, encoding: .utf8) }
    FileHandle.standardError.write("emitted client dispatch for \(files.count) interface(s)\n".data(using: .utf8)!)
}
