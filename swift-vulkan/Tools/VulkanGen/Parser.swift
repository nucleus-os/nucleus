import Foundation // FoundationXML's XML node overlay depends on the umbrella module.
#if canImport(FoundationXML)
import FoundationXML
#endif

// vk.xml → Registry, limited to the decls
// the Swift backend renders. Uses Foundation's XML DOM; document order is
// preserved (it drives output order).

private let apiConstantsName = "API Constants"

extension XMLElement {
    func attr(_ name: String) -> String? { attribute(forName: name)?.stringValue }
    // Char data of the first child element with the given tag (e.g. <name>X</name>).
    func charData(_ tag: String) -> String? { elements(forName: tag).first?.stringValue }
    func childElements() -> [XMLElement] {
        (children ?? []).compactMap { $0 as? XMLElement }
    }
}

func requiredByApi(_ elem: XMLElement) -> Bool {
    guard let apis = elem.attr("api") else { return true }
    return apis.split(separator: ",").contains("vulkan")
}

// Parse a decimal/hex integer into Int32 with wrapping semantics
// (hex values up to 0xFFFFFFFF map through the bit pattern).
func parseI32(_ s: String) -> Int32 {
    if s.hasPrefix("0x") || s.hasPrefix("0X") {
        let hex = String(s.dropFirst(2))
        if let v = Int32(hex, radix: 16) { return v }
        if let u = UInt32(hex, radix: 16) { return Int32(bitPattern: u) }
        return 0
    }
    if let v = Int32(s) { return v }
    if let u = UInt32(s) { return Int32(bitPattern: u) }
    return 0
}

func parseRegistry(_ root: XMLElement) -> Registry {
    var decls: [Decl] = []
    var tags: [String] = []
    var features: [Feature] = []
    var extensions: [Extension] = []

    parseDeclarations(root, &decls)
    parseTags(root, &tags)
    parseFeatures(root, &features)
    parseExtensions(root, &extensions)

    return Registry(decls: decls, tags: tags, features: features, extensions: extensions)
}

private func parseDeclarations(_ root: XMLElement, _ decls: inout [Decl]) {
    if let typesElem = root.elements(forName: "types").first {
        for ty in typesElem.elements(forName: "type") {
            guard requiredByApi(ty) else { continue }
            if let d = parseTypeDecl(ty) { decls.append(d) }
        }
    }
    parseEnums(root, &decls)
    if let commandsElem = root.elements(forName: "commands").first {
        for cmd in commandsElem.elements(forName: "command") {
            guard requiredByApi(cmd) else { continue }
            if let d = parseCommand(cmd) { decls.append(d) }
        }
    }
}

private func parseTypeDecl(_ ty: XMLElement) -> Decl? {
    guard let category = ty.attr("category") else { return nil } // foreign: not rendered
    switch category {
    case "bitmask": return parseBitmaskType(ty)
    case "handle": return parseHandleType(ty)
    case "enum": return parseEnumAlias(ty)
    default: return nil // basetype/struct/union/funcpointer/define: not rendered
    }
}

private func parseBitmaskType(_ ty: XMLElement) -> Decl? {
    if let name = ty.attr("name") {
        guard let alias = ty.attr("alias") else { return nil }
        return Decl(name: name, type: .aliasType(name: alias))
    }
    guard let flagsType = ty.charData("type"), let name = ty.charData("name") else { return nil }
    let bitwidth: Int = flagsType == "VkFlags64" ? 64 : 32
    return Decl(name: name, type: .bitmask(bitsEnum: ty.attr("requires") ?? ty.attr("bitvalues"), bitwidth: bitwidth))
}

private func parseHandleType(_ ty: XMLElement) -> Decl? {
    if let name = ty.attr("name") {
        guard let alias = ty.attr("alias") else { return nil }
        return Decl(name: name, type: .aliasType(name: alias))
    }
    guard let name = ty.charData("name"), let handleType = ty.charData("type") else { return nil }
    return Decl(name: name, type: .handle(isDispatchable: handleType == "VK_DEFINE_HANDLE"))
}

private func parseEnumAlias(_ elem: XMLElement) -> Decl? {
    guard let alias = elem.attr("alias"), let name = elem.attr("name") else { return nil }
    return Decl(name: name, type: .aliasType(name: alias))
}

private func parseEnums(_ root: XMLElement, _ decls: inout [Decl]) {
    for enums in root.elements(forName: "enums") {
        guard let name = enums.attr("name") else { continue }
        if name == apiConstantsName || !requiredByApi(enums) { continue }
        decls.append(Decl(name: name, type: .enumeration(parseEnumFields(enums))))
    }
}

private func parseEnumFields(_ elem: XMLElement) -> EnumDecl {
    let enumType = elem.attr("type") ?? "enum"
    let isBitmask = enumType == "bitmask"
    let bitwidth = elem.attr("bitwidth").flatMap { Int($0) } ?? 32
    var fields: [EnumField] = []
    for field in elem.elements(forName: "enum") {
        guard requiredByApi(field) else { continue }
        if let f = parseEnumField(field) { fields.append(f) }
    }
    return EnumDecl(fields: fields, bitwidth: bitwidth, isBitmask: isBitmask)
}

func parseEnumField(_ field: XMLElement) -> EnumField? {
    guard let name = field.attr("name") else { return nil }
    let value: EnumValue
    if let v = field.attr("value") {
        if v.hasPrefix("0x") || v.hasPrefix("0X") {
            value = .bitVector(parseI32(v))
        } else {
            value = .int(parseI32(v))
        }
    } else if let bitpos = field.attr("bitpos"), let b = Int(bitpos) {
        value = .bitpos(b)
    } else if let alias = field.attr("alias") {
        value = .alias(name: alias)
    } else {
        return nil
    }
    return EnumField(name: name, value: value)
}

private func parseCommand(_ elem: XMLElement) -> Decl? {
    if let alias = elem.attr("alias") {
        guard let name = elem.attr("name") else { return nil }
        return Decl(name: name, type: .aliasCommand(name: alias))
    }
    guard let proto = elem.elements(forName: "proto").first,
          let name = proto.charData("name") else { return nil }

    var firstParamTypeName: String? = nil
    for param in elem.elements(forName: "param") {
        guard requiredByApi(param) else { continue }
        // A plain (non-pointer) first param is a type name the dispatch
        // classifier keys on; a pointer param classifies as the default level.
        if !(param.stringValue ?? "").contains("*") {
            firstParamTypeName = param.charData("type")
        }
        break
    }
    return Decl(name: name, type: .command(firstParamTypeName: firstParamTypeName))
}

private func parseTags(_ root: XMLElement, _ tags: inout [String]) {
    guard let tagsElem = root.elements(forName: "tags").first else { return }
    for tag in tagsElem.elements(forName: "tag") {
        if let name = tag.attr("name") { tags.append(name) }
    }
}

private func splitFeatureLevel(_ ver: String, _ sep: Character) -> FeatureLevel {
    let parts = ver.split(separator: sep, omittingEmptySubsequences: false)
    let major = parts.count > 0 ? UInt32(parts[0]) ?? 0 : 0
    let minor = parts.count > 1 ? UInt32(parts[1]) ?? 0 : 0
    return FeatureLevel(major: major, minor: minor)
}

private func parseFeatures(_ root: XMLElement, _ features: inout [Feature]) {
    for feature in root.elements(forName: "feature") {
        guard requiredByApi(feature) else { continue }
        guard let name = feature.attr("name"), let number = feature.attr("number") else { continue }
        var requires: [Require] = []
        for require in feature.elements(forName: "require") {
            guard requiredByApi(require) else { continue }
            requires.append(parseRequire(require, parentExtnumber: nil))
        }
        features.append(Feature(name: name, level: splitFeatureLevel(number, "."), requires: requires))
    }
}

private func enumExtOffsetToValue(_ extnumber: Int, _ offset: Int) -> Int {
    1_000_000_000 + (extnumber - 1) * 1000 + offset
}

private func parseEnumExtension(_ elem: XMLElement, _ parentExtnumber: Int?) -> EnumExtension? {
    guard let name = elem.attr("name") else { return nil }
    if name.hasSuffix("_SPEC_VERSION") || name.hasSuffix("_EXTENSION_NAME") { return nil }
    guard let extends = elem.attr("extends") else { return nil } // new-api-constant: not rendered

    if let offsetStr = elem.attr("offset"), let offset = Int(offsetStr) {
        let extnumber = elem.attr("extnumber").flatMap { Int($0) }
        guard let actual = extnumber ?? parentExtnumber else { return nil }
        var value = enumExtOffsetToValue(actual, offset)
        if elem.attr("dir") == "-" { value = -value }
        return EnumExtension(extends: extends, field: EnumField(name: name, value: .int(Int32(truncatingIfNeeded: value))))
    }

    guard let field = parseEnumField(elem) else { return nil }
    return EnumExtension(extends: extends, field: field)
}

private func parseRequire(_ require: XMLElement, parentExtnumber: Int?) -> Require {
    var extends: [EnumExtension] = []
    var commands: [String] = []
    for child in require.childElements() {
        guard requiredByApi(child) else { continue }
        switch child.name {
        case "enum":
            if let ext = parseEnumExtension(child, parentExtnumber) { extends.append(ext) }
        case "command":
            if let name = child.attr("name") { commands.append(name) }
        default:
            break
        }
    }
    return Require(extends: extends, commands: commands)
}

private func parseExtensions(_ root: XMLElement, _ extensions: inout [Extension]) {
    guard let extensionsElem = root.elements(forName: "extensions").first else { return }
    for ext in extensionsElem.elements(forName: "extension") {
        guard requiredByApi(ext) else { continue }
        if ext.attr("supported") == "disabled" { continue }
        if let e = parseExtension(ext) { extensions.append(e) }
    }
}

private func parseExtension(_ ext: XMLElement) -> Extension? {
    guard let name = ext.attr("name") else { return nil }
    let platform = ext.attr("platform")
    let isVideo = name.hasPrefix("vulkan_video_")

    let number: Int
    if isVideo {
        number = 0
    } else {
        guard let n = ext.attr("number").flatMap({ Int($0) }) else { return nil }
        number = n
    }

    let extType: ExtensionType?
    if isVideo {
        extType = .video
    } else if let t = ext.attr("type") {
        extType = t == "instance" ? .instance : (t == "device" ? .device : nil)
    } else {
        extType = nil
    }

    var requires: [Require] = []
    for require in ext.elements(forName: "require") {
        guard requiredByApi(require) else { continue }
        requires.append(parseRequire(require, parentExtnumber: number))
    }

    return Extension(
        name: name, number: number, extensionType: extType,
        platform: platform, supported: ext.attr("supported"), requires: requires
    )
}
