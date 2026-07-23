import Foundation // FileHandle supplies generator diagnostics.
#if canImport(FoundationXML)
import FoundationXML
#endif

// Build-owned vk.xml → Swift binding generator (Vulkan), driven by a
// Foundation XML parse plus the registry model/emitter.
//
// Usage: VulkanGen <vk.xml path> <output Vulkan.swift> <format-version>
// The format-version arg only participates in the build cache key.

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 3 else { fail("usage: VulkanGen <vk.xml path> <output Vulkan.swift> <format-version>") }
let xmlPath = args[1]
let outPath = args[2]

guard let data = FileManager.default.contents(atPath: xmlPath) else { fail("failed to read '\(xmlPath)'") }
let doc: XMLDocument
do {
    doc = try XMLDocument(data: data)
} catch {
    fail("invalid vk.xml: \(error)")
}
guard let root = doc.rootElement() else { fail("invalid vk.xml: no root element") }

var registry = parseRegistry(root)
mergeEnumFields(&registry)
fixupBitFlags(&registry)

// Extensions supported under the `vulkan` API (the registry model drops the
// `supported` attribute from the rendered decls, so collect it here).
var vulkanExts = Set<String>()
for ext in registry.extensions {
    if let supported = ext.supported, supported.split(separator: ",").contains("vulkan") {
        vulkanExts.insert(ext.name)
    }
}

let idr = IdRenderer(tags: registry.tags)
let output = Emitter(idr: idr, vulkanExts: vulkanExts).render(registry)

let outURL = URL(fileURLWithPath: outPath)
try? FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
do {
    try output.write(to: outURL, atomically: true, encoding: .utf8)
} catch {
    fail("failed to write '\(outPath)': \(error)")
}

// --- Registry post-processing -----------------------------------------------

// Fold extension/feature `<enum extends=…>` fields into their base enum's field
// list so the rendered enum is complete.
func mergeEnumFields(_ registry: inout Registry) {
    var map: [String: [EnumField]] = [:]
    func collect(_ requires: [Require]) {
        for req in requires {
            for ext in req.extends {
                map[ext.extends, default: []].append(ext.field)
            }
        }
    }
    for feature in registry.features { collect(feature.requires) }
    for ext in registry.extensions { collect(ext.requires) }

    for i in registry.decls.indices {
        guard case .enumeration(var e) = registry.decls[i].type else { continue }
        guard let extensions = map[registry.decls[i].name] else { continue }

        var seen = Set<String>()
        var newFields: [EnumField] = []
        for field in e.fields where seen.insert(field.name).inserted { newFields.append(field) }
        for field in extensions where seen.insert(field.name).inserted { newFields.append(field) }
        e.fields = newFields
        registry.decls[i].type = .enumeration(e)
    }
}

// Drop the standalone *FlagBits enums not referenced by any Flags bitmask; the
// referenced ones are rendered as OptionSets via their Flags.
func fixupBitFlags(_ registry: inout Registry) {
    var seenBits = Set<String>()
    for decl in registry.decls {
        if case .bitmask(let bitsEnum, _) = decl.type, let b = bitsEnum {
            seenBits.insert(b)
        }
    }
    registry.decls.removeAll { decl in
        if case .enumeration(let e) = decl.type, e.isBitmask, !seenBits.contains(decl.name) {
            return true
        }
        return false
    }
}
